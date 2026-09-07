import proj4 from 'proj4'
import { register } from 'ol/proj/proj4'
import { transform } from 'ol/proj'
import GeoJSON from 'ol/format/GeoJSON'
import type Geometry from 'ol/geom/Geometry'
import type { MeasurementPosition, MeasurementResult } from './api'
import type { DrawGeometry } from './events'

export const MAP_CRS = 'EPSG:7899'
export const MEASURE_CRS = 'EPSG:7855'
// EPSG definitions: https://epsg.io/7899.proj4 and https://epsg.io/7855.proj4.
// WGS84 boundary conversion uses the standard null datum transform, not an
// epoch-aware survey transformation. Native Vicgrid -> MGA55 stays in GDA2020.
proj4.defs(MAP_CRS, '+proj=lcc +lat_0=-37 +lon_0=145 +lat_1=-36 +lat_2=-38 +x_0=2500000 +y_0=2500000 +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs')
proj4.defs(MEASURE_CRS, '+proj=utm +zone=55 +south +ellps=GRS80 +towgs84=0,0,0,0,0,0,0 +units=m +no_defs')
register(proj4)

export const geojson = new GeoJSON()
export const readOptions = { dataProjection: 'EPSG:4326', featureProjection: MAP_CRS }
export const fromWgs84 = (point: number[]) => transform(point, 'EPSG:4326', MAP_CRS)
export const toWgs84 = (point: number[]) => transform(point, MAP_CRS, 'EPSG:4326') as MeasurementPosition
export function geometryToApi(geometry: Geometry): DrawGeometry {
  return geojson.writeGeometryObject(geometry, readOptions) as DrawGeometry
}
export function measureDistance(start: number[], end: number[]): MeasurementResult {
  if ([start, end].some((p) => p.length !== 2 || !p.every(Number.isFinite))) throw new Error('Select two valid map positions.')
  const a = transform(start, MAP_CRS, MEASURE_CRS)
  const b = transform(end, MAP_CRS, MEASURE_CRS)
  const distance = Math.hypot(b[0] - a[0], b[1] - a[1])
  if (!Number.isFinite(distance)) throw new Error('Unable to measure these positions in MGA zone 55.')
  return { distance, units: 'metres', sourceCrs: MAP_CRS, measurementCrs: MEASURE_CRS }
}

// Keep copied minZoom/maxZoom rules comparable to MapLibre's 512px zoom scale,
// rather than confusing them with Vicmap's 0..13 matrix indices.
export function equivalentZoom(resolution: number, latitude: number): number {
  return Math.log2(78271.51696402048 * Math.cos(latitude * Math.PI / 180) / resolution)
}
export function resolutionForZoom(zoom: number, latitude = -37.8136): number {
  return 78271.51696402048 * Math.cos(latitude * Math.PI / 180) / 2 ** zoom
}