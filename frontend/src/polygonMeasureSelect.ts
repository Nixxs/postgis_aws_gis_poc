import type { Feature, FeatureCollection, LineString, MultiPolygon, Polygon } from 'geojson'
import type { GeoJSONSource, Map, MapMouseEvent } from 'maplibre-gl'
import { measurePolygon, queryFeatureByObjectId, type PolygonalGeometry } from './api'
import { emitPolygonMeasureState, onPolygonSegmentHover, type PolygonSegmentEvent } from './events'

const SOURCE = 'polygon-measurement'
const FILL = 'polygon-measurement-fill'
const LINE = 'polygon-measurement-line'
const SEGMENT_SOURCE = 'polygon-measurement-segment'
const SEGMENT_LINE = 'polygon-measurement-segment-line'

interface Selection {
  layer: string
  objectId: string
}

function polygonGeometry(value: unknown): PolygonalGeometry {
  if (!value || typeof value !== 'object' || !['Polygon', 'MultiPolygon'].includes(String((value as { type?: unknown }).type)) ||
      !Array.isArray((value as { coordinates?: unknown }).coordinates)) {
    const type = value && typeof value === 'object' ? String((value as { type?: unknown }).type ?? 'unknown') : 'unknown'
    throw new Error(`The selected feature has unsupported geometry type '${type}'. Select a polygon feature.`)
  }
  return value as PolygonalGeometry
}

function objectIdOf(value: unknown): string {
  const id = String(value ?? '')
  if (!/^\d+$/.test(id)) throw new Error('The selected feature does not contain a valid OBJECTID.')
  return id
}

export function createPolygonMeasureSelect(map: Map, configuredLayerIds: string[]) {
  let selecting = false
  let pending: AbortController | undefined
  let revision = 0
  let lastSelection: Selection | undefined
  let selectedGeometry: PolygonalGeometry | undefined
  const empty: FeatureCollection = { type: 'FeatureCollection', features: [] }

  map.addSource(SOURCE, { type: 'geojson', data: empty })
  map.addLayer({
    id: FILL,
    type: 'fill',
    source: SOURCE,
    paint: { 'fill-color': '#00acc1', 'fill-opacity': 0.22 },
  })
  map.addLayer({
    id: LINE,
    type: 'line',
    source: SOURCE,
    paint: { 'line-color': '#00838f', 'line-width': 4 },
  })
  map.addSource(SEGMENT_SOURCE, { type: 'geojson', data: empty })
  map.addLayer({
    id: SEGMENT_LINE,
    type: 'line',
    source: SEGMENT_SOURCE,
    paint: { 'line-color': '#ffeb3b', 'line-width': 7 },
  })

  function render(geometry?: PolygonalGeometry) {
    const features: Array<Feature<Polygon | MultiPolygon>> = geometry
      ? [{ type: 'Feature', properties: {}, geometry }]
      : []
    ;(map.getSource(SOURCE) as GeoJSONSource).setData({ type: 'FeatureCollection', features })
  }

  function renderSegment(index?: PolygonSegmentEvent) {
    let feature: Feature<LineString> | undefined
    if (selectedGeometry && index) {
      const polygons = selectedGeometry.type === 'Polygon' ? [selectedGeometry.coordinates] : selectedGeometry.coordinates
      const ring = polygons[index.polygonIndex]?.[index.ringIndex]
      const start = ring?.[index.segmentIndex]
      const end = ring?.[index.segmentIndex + 1]
      if (start && end) {
        feature = { type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: [start, end] } }
      }
    }
    ;(map.getSource(SEGMENT_SOURCE) as GeoJSONSource).setData({ type: 'FeatureCollection', features: feature ? [feature] : [] })
  }

  function stopSelecting() {
    selecting = false
    map.getCanvas().style.cursor = ''
  }

  function clear() {
    revision++
    pending?.abort()
    pending = undefined
    stopSelecting()
    lastSelection = undefined
    selectedGeometry = undefined
    render()
    renderSegment()
    emitPolygonMeasureState({ status: 'idle' })
  }

  function start() {
    clear()
    selecting = true
    map.getCanvas().style.cursor = 'crosshair'
    map.getCanvas().focus()
    emitPolygonMeasureState({ status: 'selecting' })
  }

  async function loadAndMeasure(selection: Selection) {
    pending?.abort()
    const controller = new AbortController()
    pending = controller
    const current = ++revision
    map.getCanvas().style.cursor = 'progress'
    emitPolygonMeasureState({ status: 'loading', ...selection })
    try {
      const collection = await queryFeatureByObjectId(selection.layer, selection.objectId, controller.signal)
      if (current !== revision) return
      if (collection.features.length !== 1) {
        throw new Error(collection.features.length
          ? `OBJECTID ${selection.objectId} matched more than one feature.`
          : `The selected feature no longer exists in ${selection.layer}.`)
      }
      const geometry = polygonGeometry(collection.features[0].geometry)
      selectedGeometry = geometry
      render(geometry)
      const result = await measurePolygon(geometry, controller.signal)
      if (current !== revision) return
      emitPolygonMeasureState({ status: 'complete', ...selection, result })
    } catch (error) {
      if (controller.signal.aborted || current !== revision) return
      emitPolygonMeasureState({
        status: 'error',
        ...selection,
        error: error instanceof Error ? error.message : 'Polygon measurement failed.',
      })
    } finally {
      if (pending === controller) {
        pending = undefined
        map.getCanvas().style.cursor = ''
      }
    }
  }

  function select(event: MapMouseEvent) {
    if (!selecting) return
    const layerIds = configuredLayerIds.map((id) => `${id}-fill`).filter((id) => map.getLayer(id))
    const feature = layerIds.length ? map.queryRenderedFeatures(event.point, { layers: layerIds })[0] : undefined
    if (!feature) {
      stopSelecting()
      emitPolygonMeasureState({ status: 'error', error: 'No selectable polygon was found at that location.' })
      return
    }
    try {
      const selection = { layer: String(feature.source), objectId: objectIdOf(feature.properties?.OBJECTID) }
      lastSelection = selection
      stopSelecting()
      void loadAndMeasure(selection)
    } catch (error) {
      stopSelecting()
      emitPolygonMeasureState({ status: 'error', error: error instanceof Error ? error.message : 'Feature selection failed.' })
    }
  }

  function keydown(event: KeyboardEvent) {
    if (event.key === 'Escape' && (selecting || pending)) clear()
  }

  window.addEventListener('keydown', keydown)
  const offSegmentHover = onPolygonSegmentHover((event) => renderSegment(event ?? undefined))
  emitPolygonMeasureState({ status: 'idle' })

  return {
    start,
    select,
    clear,
    retry: () => { if (lastSelection) void loadAndMeasure(lastSelection) },
    isActive: () => selecting || pending !== undefined,
    isSelecting: () => selecting,
    destroy() {
      clear()
      offSegmentHover()
      window.removeEventListener('keydown', keydown)
      for (const id of [SEGMENT_LINE, LINE, FILL]) if (map.getLayer(id)) map.removeLayer(id)
      for (const id of [SEGMENT_SOURCE, SOURCE]) if (map.getSource(id)) map.removeSource(id)
      emitPolygonMeasureState({ status: 'unavailable' })
    },
  }
}
