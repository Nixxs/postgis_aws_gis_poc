import type { Map, MapMouseEvent, GeoJSONSource } from 'maplibre-gl'
import type { FeatureCollection, Feature, Point, LineString } from 'geojson'
import { measureDistance, type MeasurementPosition } from './api'
import { emitMeasureState } from './events'

const SOURCE = 'measurement'
const LINE = 'measurement-line'
const POINTS = 'measurement-points'

export function createMeasureDraw(map: Map) {
  let points: MeasurementPosition[] = []
  let active = false
  let doubleClickWasEnabled = false
  let pending: AbortController | undefined
  let revision = 0
  const empty: FeatureCollection = { type: 'FeatureCollection', features: [] }
  map.addSource(SOURCE, { type: 'geojson', data: empty })
  map.addLayer({ id: LINE, type: 'line', source: SOURCE, filter: ['==', ['geometry-type'], 'LineString'], paint: { 'line-color': '#9c27b0', 'line-width': 3, 'line-dasharray': [2, 1] } })
  map.addLayer({ id: POINTS, type: 'circle', source: SOURCE, filter: ['==', ['geometry-type'], 'Point'], paint: { 'circle-color': '#9c27b0', 'circle-radius': 6, 'circle-stroke-color': '#fff', 'circle-stroke-width': 2 } })

  function render(preview?: MeasurementPosition) {
    const features: Feature<Point | LineString>[] = points.map((point) => ({ type: 'Feature', properties: {}, geometry: { type: 'Point', coordinates: point } }))
    const line = preview && points.length === 1 ? [points[0], preview] : points
    if (line.length === 2) features.unshift({ type: 'Feature', properties: {}, geometry: { type: 'LineString', coordinates: line } })
    ;(map.getSource(SOURCE) as GeoJSONSource).setData({ type: 'FeatureCollection', features })
  }

  function stopDrawing() {
    if (!active) return
    active = false
    map.getCanvas().style.cursor = ''
    if (doubleClickWasEnabled) map.doubleClickZoom.enable()
  }

  function clear() {
    revision++
    pending?.abort()
    pending = undefined
    stopDrawing()
    points = []
    render()
    emitMeasureState({ status: 'idle', points: [] })
  }

  function start() {
    clear()
    active = true
    doubleClickWasEnabled = map.doubleClickZoom.isEnabled()
    map.doubleClickZoom.disable()
    map.getCanvas().style.cursor = 'crosshair'
    map.getCanvas().focus()
    emitMeasureState({ status: 'drawing', points: [] })
  }

  async function calculate() {
    if (points.length !== 2) return
    pending?.abort()
    const controller = new AbortController()
    pending = controller
    const current = ++revision
    const selected = [...points]
    emitMeasureState({ status: 'loading', points: selected })
    try {
      const result = await measureDistance(selected[0], selected[1], controller.signal)
      if (current !== revision) return
      emitMeasureState({ status: 'complete', points: selected, result })
    } catch (error) {
      if (controller.signal.aborted || current !== revision) return
      emitMeasureState({ status: 'error', points: selected, error: error instanceof Error ? error.message : 'Measurement failed.' })
    } finally {
      if (pending === controller) pending = undefined
    }
  }

  function position(event: MapMouseEvent): MeasurementPosition {
    const wrapped = event.lngLat.wrap()
    return [wrapped.lng, wrapped.lat]
  }
  function click(event: MapMouseEvent) {
    if (!active) return
    points.push(position(event))
    render()
    if (points.length === 2) {
      stopDrawing()
      void calculate()
    } else emitMeasureState({ status: 'drawing', points: [...points] })
  }
  function move(event: MapMouseEvent) { if (active && points.length === 1) render(position(event)) }
  function keydown(event: KeyboardEvent) { if (event.key === 'Escape' && (active || pending)) clear() }
  map.on('click', click)
  map.on('mousemove', move)
  window.addEventListener('keydown', keydown)
  emitMeasureState({ status: 'idle', points: [] })

  return {
    start, clear, retry: () => { void calculate() }, isActive: () => active,
    destroy() {
      clear()
      map.off('click', click)
      map.off('mousemove', move)
      window.removeEventListener('keydown', keydown)
      for (const id of [POINTS, LINE]) if (map.getLayer(id)) map.removeLayer(id)
      if (map.getSource(SOURCE)) map.removeSource(SOURCE)
      emitMeasureState({ status: 'unavailable', points: [] })
    },
  }
}