import { useEffect, useState } from 'react'

export interface LayerCacheConfig {
  enabled: boolean
  grid?: 'vicgrid'
  minZoom?: number
  maxZoom?: number
  fields?: string
}

export interface ResolvedLayerCache {
  tileUrl: string
  minZoom: number
  maxZoom: number
  bounds: [number, number, number, number]
  version: string
}

export interface LayerConfig {
  id: string
  label: string
  visibleByDefault: boolean
  opacity: number
  color: string
  requiresAuth?: boolean
  minZoom?: number
  maxZoom?: number
  cache?: LayerCacheConfig
  resolvedCache?: ResolvedLayerCache
}

export interface BasemapConfig {
  id: string
  label: string
  url: string
  visibleByDefault: boolean
  attribution?: string
  tileSize?: number
  requiresAuth?: boolean
}

export interface AppConfig {
  projection: 'EPSG:7899'
  tileGridUrl: string
  basemaps?: BasemapConfig[]
  layers: LayerConfig[]
  tileCache?: {
    baseUrl: string
    prefix?: string
    schema?: string
    fallbackToApi?: boolean
  }
}

interface LatestCacheDocument {
  version: string
  baseKey: string
  manifestKey: string
}

interface TileJsonDocument {
  name: string
  grid: string
  minzoom: number
  maxzoom: number
  bounds: [number, number, number, number]
  vector_layers: Array<{ id: string }>
}

function normalizedOrigin(value: string): string {
  const url = new URL(value)
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) {
    throw new Error('tileCache.baseUrl must be a plain HTTPS origin')
  }
  return url.href.replace(/\/$/, '')
}

function validBounds(value: unknown): value is [number, number, number, number] {
  if (!Array.isArray(value) || value.length !== 4 || !value.every(Number.isFinite)) return false
  const [west, south, east, north] = value
  return west >= -180 && east <= 180 && south >= -90 && north <= 90 && west < east && south < north
}

async function responseJson<T>(url: string, cache: RequestCache): Promise<T> {
  const response = await fetch(url, { cache })
  if (!response.ok) throw new Error(`${url} returned ${response.status}`)
  return response.json() as Promise<T>
}

async function resolveLayerCache(config: AppConfig, layer: LayerConfig): Promise<LayerConfig> {
  if (!layer.cache?.enabled) return layer
  if (!config.tileCache) throw new Error(`Layer '${layer.id}' enables caching without tileCache settings`)
  const grid = layer.cache.grid ?? 'vicgrid'
  if (grid !== 'vicgrid') throw new Error(`OpenLayers layer '${layer.id}' requires a Vicgrid cache`)

  const baseUrl = normalizedOrigin(config.tileCache.baseUrl)
  const prefix = (config.tileCache.prefix ?? 'tiles').replace(/^\/+|\/+$/g, '')
  const schema = config.tileCache.schema ?? 'public'
  const expectedRoot = `${prefix}/${schema}/${layer.id}/${grid}/`
  const latestUrl = `${baseUrl}/${expectedRoot}latest.json`
  const latest = await responseJson<LatestCacheDocument>(latestUrl, 'no-cache')
  if (!latest.version || !latest.baseKey?.startsWith(expectedRoot) || latest.baseKey.includes('..')) {
    throw new Error(`Invalid latest.json for layer '${layer.id}'`)
  }
  if (latest.manifestKey !== `${latest.baseKey}/tilejson.json`) {
    throw new Error(`Unexpected TileJSON key for layer '${layer.id}'`)
  }

  const tilejson = await responseJson<TileJsonDocument>(`${baseUrl}/${latest.manifestKey}`, 'force-cache')
  const configuredMinZoom = layer.cache.minZoom ?? 0
  const configuredMaxZoom = layer.cache.maxZoom ?? 8
  if (tilejson.name !== layer.id || tilejson.grid !== grid ||
      tilejson.minzoom !== configuredMinZoom || tilejson.maxzoom !== configuredMaxZoom ||
      !tilejson.vector_layers?.some((item) => item.id === layer.id) || !validBounds(tilejson.bounds)) {
    throw new Error(`TileJSON does not match configured cache for layer '${layer.id}'`)
  }

  return {
    ...layer,
    resolvedCache: {
      tileUrl: `${baseUrl}/${latest.baseKey}/{z}/{x}/{y}.mvt`,
      minZoom: tilejson.minzoom,
      maxZoom: tilejson.maxzoom,
      bounds: tilejson.bounds,
      version: latest.version,
    },
  }
}

async function fetchConfig(): Promise<AppConfig> {
  const url = import.meta.env.VITE_CONFIG_URL || '/config.json'
  const response = await fetch(url)
  if (!response.ok) throw new Error(`Failed to load config.json: ${response.status}`)
  const config = await response.json() as AppConfig
  const layers = await Promise.all(config.layers.map(async (layer) => {
    try {
      return await resolveLayerCache(config, layer)
    } catch (error) {
      if (config.tileCache?.fallbackToApi === false) throw error
      console.warn(`[tile cache] ${layer.id}: ${String(error)}; using dynamic API`)
      return layer
    }
  }))
  return { ...config, layers }
}

let configPromise: Promise<AppConfig> | undefined

export function isLayerInZoomRange(
  layer: { minZoom?: number; maxZoom?: number },
  zoom: number,
): boolean {
  if (layer.minZoom != null && zoom < layer.minZoom) return false
  if (layer.maxZoom != null && zoom >= layer.maxZoom) return false
  return true
}

export async function loadConfig(): Promise<AppConfig> {
  if (!configPromise) {
    configPromise = fetchConfig().catch((error) => {
      configPromise = undefined
      throw error
    })
  }
  return configPromise
}

export function useConfig() {
  const [config, setConfig] = useState<AppConfig | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    loadConfig().then(setConfig).catch((e) => setError(String(e)))
  }, [])

  return { config, error }
}