import Feature from 'ol/Feature'
import type Map from 'ol/Map'
import type MapBrowserEvent from 'ol/MapBrowserEvent'
import LineString from 'ol/geom/LineString'
import MultiPolygon from 'ol/geom/MultiPolygon'
import Polygon from 'ol/geom/Polygon'
import VectorLayer from 'ol/layer/Vector'
import type BaseLayer from 'ol/layer/Base'
import VectorSource from 'ol/source/Vector'
import { Fill, Stroke, Style } from 'ol/style'
import type { FeatureLike } from 'ol/Feature'
import { queryFeatureByObjectId } from './api'
import {
  emitPolygonMeasureState, onPolygonSegmentHover, type PolygonSegmentEvent,
} from './events'
import { geojson, measurePolygonGeometry, readOptions } from './projections'

interface Selection {
  layer: string
  objectId: string
}

function propertiesOf(feature: FeatureLike): Record<string, unknown> {
  const properties = { ...feature.getProperties() }
  delete properties.geometry
  delete properties.__mvt_layer
  return properties
}

function objectIdOf(value: unknown): string {
  const id = String(value ?? '')
  if (!/^\d+$/.test(id)) throw new Error('The selected feature does not contain a valid OBJECTID.')
  return id
}

export function createPolygonMeasureSelect(map: Map) {
  const polygonSource = new VectorSource()
  const segmentSource = new VectorSource()
  const polygonLayer = new VectorLayer({
    source: polygonSource,
    style: new Style({
      fill: new Fill({ color: 'rgba(0,172,193,0.22)' }),
      stroke: new Stroke({ color: '#00838f', width: 4 }),
    }),
    zIndex: 5500,
  })
  const segmentLayer = new VectorLayer({
    source: segmentSource,
    style: new Style({ stroke: new Stroke({ color: '#ffeb3b', width: 7 }) }),
    zIndex: 5501,
  })
  map.addLayer(polygonLayer)
  map.addLayer(segmentLayer)

  const viewport = map.getViewport()
  const keyboardTarget = viewport.ownerDocument
  let previousCursor: string | undefined
  let selecting = false
  let pending: AbortController | undefined
  let revision = 0
  let lastSelection: Selection | undefined
  let selectedGeometry: Polygon | MultiPolygon | undefined
  let destroyed = false

  function setCursor(cursor: string) {
    if (previousCursor === undefined) previousCursor = viewport.style.cursor
    viewport.style.cursor = cursor
  }

  function restoreCursor() {
    if (previousCursor !== undefined) viewport.style.cursor = previousCursor
    previousCursor = undefined
  }

  function renderSegment(index?: PolygonSegmentEvent) {
    segmentSource.clear()
    if (!selectedGeometry || !index) return
    const polygons = selectedGeometry instanceof Polygon ? [selectedGeometry.getCoordinates()] : selectedGeometry.getCoordinates()
    const ring = polygons[index.polygonIndex]?.[index.ringIndex]
    const start = ring?.[index.segmentIndex]
    const end = ring?.[index.segmentIndex + 1]
    if (start && end) segmentSource.addFeature(new Feature(new LineString([start.slice(), end.slice()])))
  }

  function stopSelecting() {
    selecting = false
    restoreCursor()
  }

  function clear() {
    revision++
    pending?.abort()
    pending = undefined
    stopSelecting()
    lastSelection = undefined
    selectedGeometry = undefined
    polygonSource.clear()
    segmentSource.clear()
    emitPolygonMeasureState({ status: 'idle' })
  }

  function start() {
    clear()
    selecting = true
    setCursor('crosshair')
    viewport.focus()
    emitPolygonMeasureState({ status: 'selecting' })
  }

  async function loadAndMeasure(selection: Selection) {
    pending?.abort()
    const controller = new AbortController()
    pending = controller
    const current = ++revision
    setCursor('progress')
    emitPolygonMeasureState({ status: 'loading', ...selection })
    try {
      const collection = await queryFeatureByObjectId(selection.layer, selection.objectId, controller.signal)
      if (current !== revision) return
      if (collection.features.length !== 1) {
        throw new Error(collection.features.length
          ? `OBJECTID ${selection.objectId} matched more than one feature.`
          : `The selected feature no longer exists in ${selection.layer}.`)
      }
      const geometry = geojson.readGeometry(collection.features[0].geometry, readOptions)
      if (!(geometry instanceof Polygon) && !(geometry instanceof MultiPolygon)) {
        throw new Error(`The selected feature has unsupported geometry type '${geometry.getType()}'. Select a polygon feature.`)
      }
      selectedGeometry = geometry
      polygonSource.clear()
      polygonSource.addFeature(new Feature(geometry))
      const result = measurePolygonGeometry(geometry)
      if (current !== revision) return
      emitPolygonMeasureState({ status: 'complete', ...selection, result })
    } catch (error) {
      if (controller.signal.aborted || current !== revision) return
      emitPolygonMeasureState({
        status: 'error', ...selection,
        error: error instanceof Error ? error.message : 'Polygon measurement failed.',
      })
    } finally {
      if (pending === controller) {
        pending = undefined
        restoreCursor()
      }
    }
  }

  function select(event: MapBrowserEvent<PointerEvent | KeyboardEvent | WheelEvent>) {
    if (!selecting) return
    let selection: Selection | undefined
    try {
      map.forEachFeatureAtPixel(event.pixel, (feature, layer) => {
        const id = layer?.get('configId') as string | undefined
        if (!id) return undefined
        selection = { layer: id, objectId: objectIdOf(propertiesOf(feature).OBJECTID) }
        return true
      }, { layerFilter: (layer: BaseLayer) => !!layer.get('configId'), hitTolerance: 3 })
    } catch (error) {
      stopSelecting()
      emitPolygonMeasureState({ status: 'error', error: error instanceof Error ? error.message : 'Feature selection failed.' })
      return
    }
    if (!selection) {
      stopSelecting()
      emitPolygonMeasureState({ status: 'error', error: 'No selectable polygon was found at that location.' })
      return
    }
    lastSelection = selection
    stopSelecting()
    void loadAndMeasure(selection)
  }

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== 'Escape' || (!selecting && !pending)) return
    event.preventDefault()
    clear()
  }
  keyboardTarget.addEventListener('keydown', onKeyDown)
  const offSegmentHover = onPolygonSegmentHover((event) => renderSegment(event ?? undefined))
  emitPolygonMeasureState({ status: 'idle' })

  return {
    start,
    select,
    clear,
    retry: () => { if (lastSelection) void loadAndMeasure(lastSelection) },
    isActive: () => !destroyed && (selecting || pending !== undefined),
    isSelecting: () => !destroyed && selecting,
    destroy() {
      if (destroyed) return
      clear()
      destroyed = true
      offSegmentHover()
      keyboardTarget.removeEventListener('keydown', onKeyDown)
      map.removeLayer(segmentLayer)
      map.removeLayer(polygonLayer)
      segmentLayer.dispose()
      polygonLayer.dispose()
      segmentSource.dispose()
      polygonSource.dispose()
      emitPolygonMeasureState({ status: 'unavailable' })
    },
  }
}
