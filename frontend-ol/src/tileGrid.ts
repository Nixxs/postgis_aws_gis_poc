import TileGrid from 'ol/tilegrid/TileGrid'
import WMTSTileGrid from 'ol/tilegrid/WMTS'
import { MAP_CRS } from './projections'

export interface GridDefinition {
  crs: string
  origin: [number, number]
  tileSize: number
  resolutions: number[]
  sizes: [number, number][]
  matrixIds: string[]
  maxZoom: number
  tileUrlTemplate: string
}
export function validateGrid(data: GridDefinition): GridDefinition {
  if (data.crs !== MAP_CRS || data.tileSize !== 512 || !Array.isArray(data.origin) || data.origin.length !== 2 || !data.origin.every(Number.isFinite)
    || !Array.isArray(data.resolutions) || !data.resolutions.length || data.resolutions.some((r, i) => !Number.isFinite(r) || r <= 0 || (i > 0 && r >= data.resolutions[i - 1]))
    || !Array.isArray(data.sizes) || data.sizes.length !== data.resolutions.length || data.sizes.some((s) => !Array.isArray(s) || s.length !== 2 || s.some((n) => !Number.isInteger(n) || n <= 0))
    || !Array.isArray(data.matrixIds) || data.matrixIds.length !== data.resolutions.length
    || data.maxZoom !== data.resolutions.length - 1) throw new Error('The backend did not return a valid EPSG:7899 tile grid.')
  return data
}
export function createGrids(data: GridDefinition) {
  validateGrid(data)
  const options = { origin: data.origin, resolutions: data.resolutions, tileSize: data.tileSize, sizes: data.sizes }
  return { vector: new TileGrid(options), raster: new WMTSTileGrid({ ...options, matrixIds: data.matrixIds }) }
}
export function tileUrl(base: string, layer: string, grid: GridDefinition, coord: number[]): string | undefined {
  if (coord.length !== 3 || coord.some((value) => !Number.isInteger(value))) return undefined
  const [z, x, y] = coord
  const size = grid.sizes[z]
  if (!size || x < 0 || y < 0 || x >= size[0] || y >= size[1]) return undefined
  return `${base.replace(/\/$/, '')}/tiles/vicgrid/${encodeURIComponent(layer)}/${z}/${x}/${y}.mvt`
}