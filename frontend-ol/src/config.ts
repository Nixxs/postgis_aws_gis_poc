import { useEffect, useState } from 'react'

export interface LayerConfig {
  id: string
  label: string
  visibleByDefault: boolean
  opacity: number
  color: string
  requiresAuth?: boolean
  minZoom?: number
  maxZoom?: number
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
}

export function isLayerInZoomRange(
  layer: { minZoom?: number; maxZoom?: number },
  zoom: number,
): boolean {
  if (layer.minZoom != null && zoom < layer.minZoom) return false
  if (layer.maxZoom != null && zoom >= layer.maxZoom) return false
  return true
}

export async function loadConfig(): Promise<AppConfig> {
  const url = import.meta.env.VITE_CONFIG_URL || '/config.json'
  const res = await fetch(url)
  if (!res.ok) throw new Error(`Failed to load config.json: ${res.status}`)
  return res.json() as Promise<AppConfig>
}

export function useConfig() {
  const [config, setConfig] = useState<AppConfig | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    loadConfig().then(setConfig).catch((e) => setError(String(e)))
  }, [])

  return { config, error }
}