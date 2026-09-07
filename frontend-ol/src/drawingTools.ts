import type Map from 'ol/Map'
import Feature from 'ol/Feature'
import Draw from 'ol/interaction/Draw'
import DoubleClickZoom from 'ol/interaction/DoubleClickZoom'
import VectorLayer from 'ol/layer/Vector'
import VectorSource from 'ol/source/Vector'
import LineString from 'ol/geom/LineString'
import MultiPoint from 'ol/geom/MultiPoint'
import Polygon from 'ol/geom/Polygon'
import { Circle as CircleStyle, Fill, Stroke, Style } from 'ol/style'
import { unByKey } from 'ol/Observable'
import type { EventsKey } from 'ol/events'
import type { Coordinate } from 'ol/coordinate'
import type { MeasurementPosition } from './api'
import {
  emitFeatureClear, emitMeasureState, emitSpatialDrawClear, emitSpatialDrawComplete,
  onMeasureStart, onMeasureClear, onMeasureRetry, onSpatialDrawStart,
  onSpatialDrawFinish, onSpatialDrawClear, onSpatialDrawGeometry,
} from './events'
import { geojson, readOptions, geometryToApi, measureDistance, toWgs84 } from './projections'

type Mode = 'point' | 'polygon' | 'measure'
interface Session {
  mode: Mode
  draw: Draw
  keys: EventsKey[]
  fixedPolygon: Coordinate[]
  ending: boolean
  completion?: ReturnType<typeof setTimeout>
}

/** One event-bus controller per map. All sketch coordinates stay in native Vicgrid. */
export function createDrawingTools(map: Map): { isActive: () => boolean; destroy: () => void } {
  const spatialSource = new VectorSource()
  const measureSource = new VectorSource()
  const dot = (color: string) => new CircleStyle({
    radius: 5, fill: new Fill({ color }), stroke: new Stroke({ color: '#fff', width: 2 }),
  })
  const spatialStyle = new Style({
    stroke: new Stroke({ color: '#1976d2', width: 2, lineDash: [6, 4] }),
    fill: new Fill({ color: 'rgba(25,118,210,0.15)' }), image: dot('#1976d2'),
  })
  const measureStyle = [
    new Style({ stroke: new Stroke({ color: '#7b1fa2', width: 3, lineDash: [6, 4] }), image: dot('#7b1fa2') }),
    new Style({
      image: dot('#7b1fa2'),
      geometry: (feature) => {
        const geometry = feature.getGeometry()
        if (!(geometry instanceof LineString)) return undefined
        const coordinates = geometry.getCoordinates()
        return new MultiPoint([coordinates[0], coordinates[coordinates.length - 1]])
      },
    }),
  ]
  const spatialLayer = new VectorLayer({ source: spatialSource, style: spatialStyle, zIndex: 4000 })
  const measureLayer = new VectorLayer({ source: measureSource, style: measureStyle, zIndex: 5000 })
  map.addLayer(spatialLayer)
  map.addLayer(measureLayer)

  const viewport = map.getViewport()
  const keyboardTarget = viewport.ownerDocument
  const zoomStates = new globalThis.Map<DoubleClickZoom, boolean>()
  let previousCursor: string | undefined
  let session: Session | undefined
  let releaseTimer: ReturnType<typeof setTimeout> | undefined
  let endpoints: [Coordinate, Coordinate] | undefined
  let points: MeasurementPosition[] = []
  let destroyed = false
  const isActive = () => !destroyed && (session !== undefined || releaseTimer !== undefined)

  function suspendZoom(interaction: unknown) {
    if (interaction instanceof DoubleClickZoom && !zoomStates.has(interaction)) {
      zoomStates.set(interaction, interaction.getActive())
      interaction.setActive(false)
    }
  }
  function restoreNavigation() {
    if (releaseTimer !== undefined) clearTimeout(releaseTimer)
    releaseTimer = undefined
    zoomStates.forEach((active, interaction) => interaction.setActive(active))
    zoomStates.clear()
    if (previousCursor !== undefined) viewport.style.cursor = previousCursor
    previousCursor = undefined
  }
  function holdNavigation() {
    if (releaseTimer !== undefined) clearTimeout(releaseTimer)
    releaseTimer = undefined
    if (previousCursor === undefined) previousCursor = viewport.style.cursor
    viewport.style.cursor = 'crosshair'
    map.getInteractions().forEach(suspendZoom)
  }
  function releaseAfterGesture() {
    // OL synthesizes click/dblclick/singleclick after pointerup (250ms window).
    // Keep selection and DoubleClickZoom suppressed through that final gesture.
    if (releaseTimer !== undefined) clearTimeout(releaseTimer)
    releaseTimer = setTimeout(restoreNavigation, 300)
  }
  function detach(current: Session) {
    if (current.completion !== undefined) clearTimeout(current.completion)
    unByKey(current.keys)
    if (session === current) session = undefined
    current.draw.abortDrawing()
    map.removeInteraction(current.draw)
    current.draw.getOverlay().dispose()
    current.draw.dispose()
  }
  function cancelDrawing() {
    const ending = session?.ending
    if (session) detach(session)
    if (ending || releaseTimer !== undefined) releaseAfterGesture()
    else restoreNavigation()
  }
  function clearMeasure() {
    if (session?.mode === 'measure') cancelDrawing()
    endpoints = undefined
    points = []
    measureSource.clear()
    emitMeasureState({ status: 'idle', points: [] })
  }
  function clearSpatial() {
    if (session && session.mode !== 'measure') cancelDrawing()
    spatialSource.clear()
  }
  function calculate() {
    if (!endpoints) return
    try {
      // Only final, fixed endpoints are measured. Never calculate from the preview.
      const result = measureDistance(endpoints[0], endpoints[1])
      points = endpoints.map(toWgs84)
      emitMeasureState({ status: 'complete', points, result })
    } catch (error) {
      emitMeasureState({ status: 'error', points, error: error instanceof Error ? error.message : String(error) })
    }
  }
  function begin(mode: Mode) {
    cancelDrawing()
    holdNavigation()
    const current: Session = {
      mode, keys: [], fixedPolygon: [], ending: false,
      draw: new Draw({
        type: mode === 'measure' ? 'LineString' : mode === 'point' ? 'Point' : 'Polygon',
        maxPoints: mode === 'measure' ? 2 : undefined,
        minPoints: mode === 'measure' ? 2 : 3,
        stopClick: true,
        // Shift-drag must not turn a two-click measurement into freehand drawing.
        freehandCondition: () => false,
        style: mode === 'measure' ? measureStyle : spatialStyle,
        ...(mode === 'polygon' ? {
          geometryFunction: (coordinates, geometry) => {
            const ring = (coordinates as Coordinate[][])[0]
            // Draw retains a moving cursor coordinate; it is not a fixed vertex.
            current.fixedPolygon = ring.slice(0, -1).map((point) => point.slice())
            const polygon = geometry as Polygon | undefined
            const closed = ring.length ? [ring.concat([ring[0]])] : []
            if (polygon) { polygon.setCoordinates(closed); return polygon }
            return new Polygon(closed)
          },
        } : {}),
        // Intentionally no source: OL inserts AFTER drawend. Commit ourselves in
        // the deferred callback so Clear/Destroy cannot resurrect a stale feature.
      }),
    }
    session = current
    current.draw.getOverlay().setZIndex(mode === 'measure' ? 5000 : 4000)
    current.keys.push(current.draw.on('drawstart', (event) => {
      if (mode !== 'measure') return
      const geometry = event.feature.getGeometry()
      if (geometry instanceof LineString) {
        points = [toWgs84(geometry.getFirstCoordinate())]
        emitMeasureState({ status: 'drawing', points })
      }
    }))
    current.keys.push(current.draw.on('drawend', (event) => {
      if (session !== current || current.ending) return
      current.ending = true
      // Removing Draw synchronously here breaks OL's pointerup/finishDrawing stack.
      current.completion = setTimeout(() => {
        if (destroyed || session !== current) return
        detach(current)
        releaseAfterGesture()
        const geometry = event.feature.getGeometry()
        if (!geometry) return
        if (mode === 'measure' && geometry instanceof LineString) {
          const coordinates = geometry.getCoordinates()
          if (coordinates.length !== 2) {
            emitMeasureState({ status: 'error', points, error: 'Select exactly two map positions.' })
            return
          }
          endpoints = [coordinates[0].slice(), coordinates[1].slice()]
          measureSource.addFeature(event.feature)
          calculate()
        } else {
          spatialSource.addFeature(event.feature)
          emitSpatialDrawComplete({ geometry: geometryToApi(geometry) })
        }
      }, 0)
    }))
    map.addInteraction(current.draw)
    if (mode === 'measure') emitMeasureState({ status: 'drawing', points: [] })
  }
  function finishSpatial() {
    if (session?.mode !== 'polygon' || session.ending) return
    // finishDrawing() does not enforce minPoints. Ignore Finish before three
    // distinct FIXED vertices, even when the mouse preview would form a triangle.
    const unique = new Set(session.fixedPolygon.map(([x, y]) => `${x},${y}`))
    if (unique.size >= 3) session.draw.finishDrawing()
  }
  function startMeasure() {
    emitSpatialDrawClear()
    emitFeatureClear()
    clearMeasure()
    begin('measure')
  }
  const subscriptions = [
    onSpatialDrawStart(({ mode }) => { clearMeasure(); clearSpatial(); begin(mode) }),
    onSpatialDrawFinish(finishSpatial),
    onSpatialDrawClear(clearSpatial),
    onSpatialDrawGeometry(({ geometry }) => {
      // A late query response must not interrupt a new measurement.
      if (session?.mode === 'measure') return
      const nativeGeometry = geojson.readGeometry(geometry, readOptions)
      clearSpatial()
      spatialSource.addFeature(new Feature(nativeGeometry))
    }),
    onMeasureStart(startMeasure),
    onMeasureClear(clearMeasure),
    onMeasureRetry(() => { if (endpoints) calculate() }),
  ]
  const keys = [
    map.getInteractions().on('add', ({ element }) => { if (isActive()) suspendZoom(element) }),
    map.on('dblclick', (event) => {
      if (isActive()) { event.preventDefault(); return false }
    }),
  ]
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== 'Escape' || !isActive()) return
    event.preventDefault()
    // Notify panel subscribers as well as clearing the map sketch.
    emitSpatialDrawClear()
    clearMeasure()
  }
  keyboardTarget.addEventListener('keydown', onKeyDown)
  emitMeasureState({ status: 'idle', points: [] })

  return {
    isActive,
    destroy() {
      if (destroyed) return
      destroyed = true
      subscriptions.forEach((unsubscribe) => unsubscribe())
      unByKey(keys)
      keyboardTarget.removeEventListener('keydown', onKeyDown)
      if (session) detach(session)
      restoreNavigation()
      spatialSource.clear()
      measureSource.clear()
      map.removeLayer(spatialLayer)
      map.removeLayer(measureLayer)
      spatialLayer.dispose()
      measureLayer.dispose()
      spatialSource.dispose()
      measureSource.dispose()
      endpoints = undefined
      points = []
      emitMeasureState({ status: 'unavailable', points: [] })
    },
  }
}