const API_BASE = (import.meta.env.VITE_QUERY_API_URL as string).replace(/\/$/, '')

export interface ColumnInfo {
  name: string
  type: string
  nullable: boolean
  is_geometry: boolean
}

export interface DescribeLayerResult {
  layer: string
  feature_count: number
  columns: ColumnInfo[]
}

export interface UniqueValuesResult {
  layer: string
  field: string
  values: (string | number | null)[]
  truncated: boolean
}

export type FeatureCollection = {
  type: 'FeatureCollection'
  features: Array<{
    type: 'Feature'
    geometry: unknown
    properties: Record<string, unknown>
  }>
}

export interface PolygonGeometry {
  type: 'Polygon'
  coordinates: number[][][]
}

export interface MultiPolygonGeometry {
  type: 'MultiPolygon'
  coordinates: number[][][][]
}

export type PolygonalGeometry = PolygonGeometry | MultiPolygonGeometry

export interface PolygonSegmentMeasurement {
  polygonIndex: number
  ringIndex: number
  segmentIndex: number
  length: number
}

export interface PolygonMeasurementResult {
  area: number
  perimeter: number
  segments: PolygonSegmentMeasurement[]
  lengthUnits: 'metres'
  areaUnits: 'square_metres'
  sourceCrs: 'EPSG:4326'
  measurementCrs: 'EPSG:7855'
}

export type SpatialQueryResult = FeatureCollection & {
  layer: string
  count: number
  bufferMeters: number
  queryGeometry: unknown | null
}

async function json<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, init)
  const data = await response.json()
  if (!response.ok) {
    throw new Error(data?.detail ?? data?.error ?? `request failed: ${response.status}`)
  }
  return data as T
}

export function describeLayer(layer: string) {
  return json<DescribeLayerResult>(`/describe-layer/${encodeURIComponent(layer)}`)
}

export function getUniqueValues(layer: string, field: string, search = '', limit = 50) {
  return json<UniqueValuesResult>('/unique-values', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ table: layer, field, search, limit }),
  })
}

export function queryLayer(layer: string, where: string, recordCount = 1000) {
  return json<FeatureCollection>('/query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      layer,
      where,
      f: 'geojson',
      resultRecordCount: recordCount,
    }),
  })
}

export function queryFeatureByObjectId(layer: string, objectId: string | number, signal?: AbortSignal) {
  const id = String(objectId)
  if (!/^\d+$/.test(id)) throw new Error('The selected feature has an invalid OBJECTID.')
  return json<FeatureCollection>('/query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      layer,
      where: `"OBJECTID" = ${id}`,
      f: 'geojson',
      resultRecordCount: 2,
    }),
    signal,
  })
}

export function spatialQuery(layer: string, geometry: unknown, bufferMeters = 0) {
  return json<SpatialQueryResult>('/spatial-query', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ layer, geometry, buffer: bufferMeters }),
  })
}

export type MeasurementPosition = [number, number]
export interface MeasurementResult {
  distance: number
  units: 'metres'
  sourceCrs: 'EPSG:4326'
  measurementCrs: 'EPSG:7855'
}

export async function measureDistance(start: MeasurementPosition, end: MeasurementPosition, signal?: AbortSignal) {
  const response = await fetch(`${API_BASE}/measure`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ start, end }),
    signal,
  })
  if (!response.ok) {
    if (response.status === 404) throw new Error('Measurement endpoint unavailable. Rebuild or deploy the API with the /measure route.')
    const data = await response.json().catch(() => null)
    const detail = data?.detail
    throw new Error(typeof detail === 'string' ? detail : `Measurement failed (${response.status}). Check the selected coordinates and retry.`)
  }
  const result = await response.json() as MeasurementResult
  if (!Number.isFinite(result.distance) || result.distance < 0 || result.units !== 'metres' || result.measurementCrs !== 'EPSG:7855') {
    throw new Error('Unexpected measurement response. The API must return metres in EPSG:7855.')
  }
  return result
}

export async function measurePolygon(geometry: PolygonalGeometry, signal?: AbortSignal) {
  const response = await fetch(`${API_BASE}/measure/polygon`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ geometry }),
    signal,
  })
  if (!response.ok) {
    if (response.status === 404) throw new Error('Polygon measurement endpoint unavailable. Deploy the API with the /measure/polygon route.')
    const data = await response.json().catch(() => null)
    const detail = data?.detail
    throw new Error(typeof detail === 'string' ? detail : `Polygon measurement failed (${response.status}).`)
  }
  const result = await response.json() as PolygonMeasurementResult
  const validSegments = Array.isArray(result.segments) && result.segments.every((segment) =>
    Number.isInteger(segment.polygonIndex) && segment.polygonIndex >= 0 &&
    Number.isInteger(segment.ringIndex) && segment.ringIndex >= 0 &&
    Number.isInteger(segment.segmentIndex) && segment.segmentIndex >= 0 &&
    Number.isFinite(segment.length) && segment.length >= 0)
  if (!Number.isFinite(result.area) || result.area < 0 || !Number.isFinite(result.perimeter) || result.perimeter < 0 ||
      !validSegments || result.lengthUnits !== 'metres' || result.areaUnits !== 'square_metres' || result.measurementCrs !== 'EPSG:7855') {
    throw new Error('Unexpected polygon measurement response. The API must return area and segment lengths in EPSG:7855.')
  }
  return result
}

export function warmUp(layer: string): void {
  if (!layer) return
  fetch(`${API_BASE}/describe-layer/${encodeURIComponent(layer)}?id=${Date.now()}`, {
    keepalive: true,
  }).catch(() => {
    // Best-effort warm-up only.
  })
}
