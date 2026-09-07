import mitt from 'mitt'
import type { FeatureCollection, MeasurementPosition, MeasurementResult } from './api'

export interface MeasureState {
  status: 'unavailable' | 'idle' | 'drawing' | 'loading' | 'complete' | 'error'
  points: MeasurementPosition[]
  result?: MeasurementResult
  error?: string
}

export interface LayerToggleEvent { id: string; visible: boolean }
export interface QueryResultEvent { layer: string; geojson: FeatureCollection }
export interface QueryResultMultiEvent {
  results: Array<{ layer: string; label?: string; geojson: FeatureCollection }>
}
export interface FeatureSelectEvent { layer: string; properties: Record<string, unknown> }
export interface ResultFeatureSelectEvent { feature: FeatureCollection['features'][number] }
export type DrawGeometry = { type: string; coordinates?: unknown; geometries?: unknown[] }
export interface SpatialDrawStartEvent { mode: 'point' | 'polygon' }
export interface SpatialDrawGeometryEvent { geometry: DrawGeometry }
export interface MapZoomEvent { zoom: number }

type Events = {
  measureStart: void
  measureClear: void
  measureRetry: void
  measureState: MeasureState
  layerToggle: LayerToggleEvent
  queryResult: QueryResultEvent
  queryResultMulti: QueryResultMultiEvent
  clearQuery: void
  featureSelect: FeatureSelectEvent
  featureClear: void
  resultFeatureSelect: ResultFeatureSelectEvent
  spatialDrawStart: SpatialDrawStartEvent
  spatialDrawFinish: void
  spatialDrawClear: void
  spatialDrawComplete: SpatialDrawGeometryEvent
  spatialDrawGeometry: SpatialDrawGeometryEvent
  mapZoom: MapZoomEvent
}

const bus = mitt<Events>()

export function emitMeasureStart() { bus.emit('measureStart') }
export function onMeasureStart(fn: () => void): () => void { bus.on('measureStart', fn); return () => bus.off('measureStart', fn) }
export function emitMeasureClear() { bus.emit('measureClear') }
export function onMeasureClear(fn: () => void): () => void { bus.on('measureClear', fn); return () => bus.off('measureClear', fn) }
export function emitMeasureRetry() { bus.emit('measureRetry') }
export function onMeasureRetry(fn: () => void): () => void { bus.on('measureRetry', fn); return () => bus.off('measureRetry', fn) }
let measureState: MeasureState = { status: 'unavailable', points: [] }
export function emitMeasureState(state: MeasureState) { measureState = state; bus.emit('measureState', state) }
export function onMeasureState(fn: (state: MeasureState) => void): () => void { bus.on('measureState', fn); fn(measureState); return () => bus.off('measureState', fn) }

export function emitLayerToggle(event: LayerToggleEvent) { bus.emit('layerToggle', event) }
export function onLayerToggle(fn: (e: LayerToggleEvent) => void): () => void { bus.on('layerToggle', fn); return () => bus.off('layerToggle', fn) }
export function emitQueryResult(event: QueryResultEvent) { bus.emit('queryResult', event) }
export function onQueryResult(fn: (e: QueryResultEvent) => void): () => void { bus.on('queryResult', fn); return () => bus.off('queryResult', fn) }
export function emitQueryResultMulti(event: QueryResultMultiEvent) { bus.emit('queryResultMulti', event) }
export function onQueryResultMulti(fn: (e: QueryResultMultiEvent) => void): () => void { bus.on('queryResultMulti', fn); return () => bus.off('queryResultMulti', fn) }
export function emitClearQuery() { bus.emit('clearQuery') }
export function onClearQuery(fn: () => void): () => void { bus.on('clearQuery', fn); return () => bus.off('clearQuery', fn) }
export function emitFeatureSelect(event: FeatureSelectEvent) { bus.emit('featureSelect', event) }
export function onFeatureSelect(fn: (e: FeatureSelectEvent) => void): () => void { bus.on('featureSelect', fn); return () => bus.off('featureSelect', fn) }
export function emitFeatureClear() { bus.emit('featureClear') }
export function onFeatureClear(fn: () => void): () => void { bus.on('featureClear', fn); return () => bus.off('featureClear', fn) }
export function emitResultFeatureSelect(event: ResultFeatureSelectEvent) { bus.emit('resultFeatureSelect', event) }
export function onResultFeatureSelect(fn: (e: ResultFeatureSelectEvent) => void): () => void { bus.on('resultFeatureSelect', fn); return () => bus.off('resultFeatureSelect', fn) }
export function emitSpatialDrawStart(event: SpatialDrawStartEvent) { bus.emit('spatialDrawStart', event) }
export function onSpatialDrawStart(fn: (e: SpatialDrawStartEvent) => void): () => void { bus.on('spatialDrawStart', fn); return () => bus.off('spatialDrawStart', fn) }
export function emitSpatialDrawFinish() { bus.emit('spatialDrawFinish') }
export function onSpatialDrawFinish(fn: () => void): () => void { bus.on('spatialDrawFinish', fn); return () => bus.off('spatialDrawFinish', fn) }
export function emitSpatialDrawClear() { bus.emit('spatialDrawClear') }
export function onSpatialDrawClear(fn: () => void): () => void { bus.on('spatialDrawClear', fn); return () => bus.off('spatialDrawClear', fn) }
export function emitSpatialDrawComplete(event: SpatialDrawGeometryEvent) { bus.emit('spatialDrawComplete', event) }
export function onSpatialDrawComplete(fn: (e: SpatialDrawGeometryEvent) => void): () => void { bus.on('spatialDrawComplete', fn); return () => bus.off('spatialDrawComplete', fn) }
export function emitSpatialDrawGeometry(event: SpatialDrawGeometryEvent) { bus.emit('spatialDrawGeometry', event) }
export function onSpatialDrawGeometry(fn: (e: SpatialDrawGeometryEvent) => void): () => void { bus.on('spatialDrawGeometry', fn); return () => bus.off('spatialDrawGeometry', fn) }
export function emitMapZoom(event: MapZoomEvent) { bus.emit('mapZoom', event) }
export function onMapZoom(fn: (e: MapZoomEvent) => void): () => void { bus.on('mapZoom', fn); return () => bus.off('mapZoom', fn) }
