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

export function warmUp(layer: string): void {
  if (!layer) return
  fetch(`${API_BASE}/describe-layer/${encodeURIComponent(layer)}?id=${Date.now()}`, {
    keepalive: true,
  }).catch(() => {
    // Best-effort warm-up only.
  })
}
