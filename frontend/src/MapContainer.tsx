import { useEffect, useRef } from 'react'
import maplibregl from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import type { AppConfig, LayerConfig, BasemapConfig } from './config'
import { useAuth } from './auth'
import { onLayerToggle, onQueryResult, onQueryResultMulti, onClearQuery, onSpatialDrawStart, onSpatialDrawFinish, onSpatialDrawClear, onSpatialDrawGeometry, emitSpatialDrawComplete, emitFeatureSelect, onFeatureClear, onResultFeatureSelect, emitMapZoom } from './events'
import { createSpatialDraw, type SpatialDraw } from './spatialDraw'
import { GoToLatLngControl } from './GoToLatLngControl'
import { createMeasureDraw } from './measureDraw'
import { createPolygonMeasureSelect } from './polygonMeasureSelect'
import { onMeasureStart, onMeasureClear, onMeasureRetry, emitSpatialDrawClear, emitFeatureClear, onPolygonMeasureStart, onPolygonMeasureClear, onPolygonMeasureRetry, emitPolygonMeasureClear } from './events'

const CONFIGURED_TILE_API_BASE = (import.meta.env.VITE_TILE_API_URL || '').replace(/\/$/, '')
const TILE_API_BASE = /^https?:\/\//i.test(CONFIGURED_TILE_API_BASE)
  ? CONFIGURED_TILE_API_BASE
  : `${window.location.origin}${CONFIGURED_TILE_API_BASE.startsWith('/') ? '' : '/'}${CONFIGURED_TILE_API_BASE}`

function addVectorLayer(map: maplibregl.Map, layer: LayerConfig, layers: LayerConfig[], visible = layer.visibleByDefault) {
  if (map.getSource(layer.id)) return
  const visibility = visible ? 'visible' : 'none'
  const index = layers.findIndex((l) => l.id === layer.id)
  let beforeId: string | undefined
  for (let i = index - 1; i >= 0; i--) { if (map.getLayer(`${layers[i].id}-fill`)) { beforeId = `${layers[i].id}-fill`; break } }
  if (!beforeId && map.getLayer('query-result-fill')) beforeId = 'query-result-fill'
  map.addSource(layer.id, {
    type: 'vector',
    tiles: [layer.resolvedCache?.tileUrl ?? `${TILE_API_BASE}/tiles/${encodeURIComponent(layer.id)}/{z}/{x}/{y}.mvt`],
    minzoom: layer.resolvedCache?.minZoom ?? layer.minZoom ?? 0,
    maxzoom: layer.resolvedCache?.maxZoom ?? layer.maxZoom ?? 22,
    ...(layer.resolvedCache ? { bounds: layer.resolvedCache.bounds } : {}),
  })
  map.addLayer({ id: `${layer.id}-fill`, type: 'fill', source: layer.id, 'source-layer': layer.id, ...(layer.minZoom != null ? { minzoom: layer.minZoom } : {}), ...(layer.maxZoom != null ? { maxzoom: layer.maxZoom } : {}), paint: { 'fill-color': layer.color, 'fill-opacity': layer.opacity }, layout: { visibility } }, beforeId)
  map.addLayer({ id: `${layer.id}-line`, type: 'line', source: layer.id, 'source-layer': layer.id, ...(layer.minZoom != null ? { minzoom: layer.minZoom } : {}), ...(layer.maxZoom != null ? { maxzoom: layer.maxZoom } : {}), paint: { 'line-color': layer.color, 'line-width': 1 }, layout: { visibility } }, beforeId)
}

function removeVectorLayer(map: maplibregl.Map, layer: LayerConfig) {
  for (const id of [`${layer.id}-fill`, `${layer.id}-line`]) if (map.getLayer(id)) map.removeLayer(id)
  if (map.getSource(layer.id)) map.removeSource(layer.id)
}

function addRasterBasemap(map: maplibregl.Map, bm: BasemapConfig, basemaps: BasemapConfig[], visible = bm.visibleByDefault) {
  if (map.getSource(bm.id)) return
  map.addSource(bm.id, { type: 'raster', tiles: [bm.url], tileSize: bm.tileSize ?? 256, ...(bm.attribution ? { attribution: bm.attribution } : {}) })
  const index = basemaps.findIndex((b) => b.id === bm.id)
  let beforeId: string | undefined
  for (let i = index - 1; i >= 0; i--) { if (map.getLayer(basemaps[i].id)) { beforeId = basemaps[i].id; break } }
  if (!beforeId) beforeId = (map.getStyle().layers ?? []).find((l) => l.id.endsWith('-fill') || l.id.endsWith('-line') || l.id.startsWith('query-result'))?.id
  map.addLayer({ id: bm.id, type: 'raster', source: bm.id, layout: { visibility: visible ? 'visible' : 'none' } }, beforeId)
}

function removeRasterBasemap(map: maplibregl.Map, bm: BasemapConfig) { if (map.getLayer(bm.id)) map.removeLayer(bm.id); if (map.getSource(bm.id)) map.removeSource(bm.id) }
function extendBounds(bounds: maplibregl.LngLatBounds, coords: any) { if (typeof coords[0] === 'number') bounds.extend(coords as [number, number]); else for (const c of coords) extendBounds(bounds, c) }

export default function MapContainer({ config }: { config: AppConfig }) {
  const containerRef = useRef<HTMLDivElement>(null); const mapRef = useRef<maplibregl.Map | null>(null); const { user } = useAuth()
  useEffect(() => {
    if (!containerRef.current) return
    const map = new maplibregl.Map({ container: containerRef.current, style: { version: 8, sources: { osm: { type: 'raster', tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'], tileSize: 256, attribution: '© OpenStreetMap contributors' } }, layers: [{ id: 'osm', type: 'raster', source: 'osm' }] }, center: [144.9631, -37.8136], zoom: 8 })
    map.addControl(new maplibregl.NavigationControl(), 'top-right')
    map.addControl(new maplibregl.GeolocateControl({ positionOptions: { enableHighAccuracy: true }, trackUserLocation: true, showAccuracyCircle: true, showUserLocation: true }), 'top-left')
    map.addControl(new GoToLatLngControl(), 'top-left'); map.addControl(new maplibregl.ScaleControl({ unit: 'metric' }), 'bottom-left'); mapRef.current = map
    const subs: Array<() => void> = []
    subs.push(onLayerToggle((e) => {
      const layer = config.layers.find((item) => item.id === e.id)
      const basemap = (config.basemaps ?? []).find((item) => item.id === e.id)
      const apply = () => {
        if (layer) e.visible ? addVectorLayer(map, layer, config.layers, true) : removeVectorLayer(map, layer)
        if (basemap) e.visible ? addRasterBasemap(map, basemap, config.basemaps ?? [], true) : removeRasterBasemap(map, basemap)
      }
      if (map.isStyleLoaded()) apply(); else map.once('load', apply)
    }))
    const publishZoom = () => emitMapZoom({ zoom: map.getZoom() }); map.on('zoom', publishZoom); subs.push(() => map.off('zoom', publishZoom)); publishZoom()
    map.on('error', (e) => console.error('[map error]', e.error ?? e))

    map.on('load', () => {
      let draw: SpatialDraw | null = null
      let measurement: ReturnType<typeof createMeasureDraw> | null = null
      let polygonMeasurement: ReturnType<typeof createPolygonMeasureSelect> | null = null
      for (const bm of config.basemaps ?? []) if (!bm.requiresAuth && bm.visibleByDefault) addRasterBasemap(map, bm, config.basemaps ?? [])
      for (const layer of config.layers) if (!layer.requiresAuth && layer.visibleByDefault) addVectorLayer(map, layer, config.layers)
      polygonMeasurement = createPolygonMeasureSelect(map, config.layers.map((layer) => layer.id))
      map.on('click', (e) => {
        if (polygonMeasurement?.isActive()) { polygonMeasurement.select(e); return }
        if (draw?.isActive() || measurement?.isActive()) return
        const fillLayerIds = config.layers.map((layer) => `${layer.id}-fill`).filter((id) => map.getLayer(id))
        const feature = fillLayerIds.length ? map.queryRenderedFeatures(e.point, { layers: fillLayerIds })[0] : undefined
        if (!feature) return
        if (map.getLayer('highlight')) map.removeLayer('highlight')
        const filter: any = ['all']; for (const [name, value] of Object.entries(feature.properties ?? {})) filter.push(['==', ['get', name], value])
        map.addLayer({ id: 'highlight', type: 'line', source: feature.source, 'source-layer': feature.sourceLayer!, paint: { 'line-color': '#ffeb3b', 'line-width': 3 }, filter })
        emitFeatureSelect({ layer: String(feature.source), properties: feature.properties ?? {} })
      })
      map.on('mousemove', (e) => {
        if (polygonMeasurement?.isActive()) return
        if (draw?.isActive() || measurement?.isActive()) return
        const fillLayerIds = config.layers.map((layer) => `${layer.id}-fill`).filter((id) => map.getLayer(id))
        map.getCanvas().style.cursor = fillLayerIds.length && map.queryRenderedFeatures(e.point, { layers: fillLayerIds }).length ? 'pointer' : ''
      })
      subs.push(onFeatureClear(() => { if (map.getLayer('highlight')) map.removeLayer('highlight') }))
      const EMPTY = { type: 'FeatureCollection' as const, features: [] }
      map.addSource('query-result', { type: 'geojson', data: EMPTY }); map.addLayer({ id: 'query-result-fill', type: 'fill', source: 'query-result', paint: { 'fill-color': '#e91e63', 'fill-opacity': 0.35 } }); map.addLayer({ id: 'query-result-line', type: 'line', source: 'query-result', paint: { 'line-color': '#e91e63', 'line-width': 2 } })
      map.addSource('result-highlight', { type: 'geojson', data: EMPTY }); map.addLayer({ id: 'result-highlight-fill', type: 'fill', source: 'result-highlight', paint: { 'fill-color': '#ffeb3b', 'fill-opacity': 0.4 } }); map.addLayer({ id: 'result-highlight-line', type: 'line', source: 'result-highlight', paint: { 'line-color': '#ffeb3b', 'line-width': 3 } })
      const clearHighlight = () => (map.getSource('result-highlight') as maplibregl.GeoJSONSource)?.setData(EMPTY as any)
      subs.push(onQueryResult((e) => { (map.getSource('query-result') as maplibregl.GeoJSONSource).setData(e.geojson as any); clearHighlight(); const bounds = new maplibregl.LngLatBounds(); for (const f of e.geojson.features) if (f.geometry) extendBounds(bounds, (f.geometry as any).coordinates); if (!bounds.isEmpty()) map.fitBounds(bounds, { padding: 40, maxZoom: 14 }) }))
      subs.push(onQueryResultMulti((e) => { const features = e.results.flatMap((r) => r.geojson.features ?? []); (map.getSource('query-result') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features } as any); clearHighlight(); const bounds = new maplibregl.LngLatBounds(); for (const f of features) if (f.geometry) extendBounds(bounds, (f.geometry as any).coordinates); if (!bounds.isEmpty()) map.fitBounds(bounds, { padding: 40, maxZoom: 16 }) }))
      subs.push(onClearQuery(() => { (map.getSource('query-result') as maplibregl.GeoJSONSource).setData(EMPTY as any); clearHighlight() }))
      subs.push(onResultFeatureSelect((e) => { const geometry = e.feature?.geometry as any; if (!geometry) return; (map.getSource('result-highlight') as maplibregl.GeoJSONSource).setData({ type: 'FeatureCollection', features: [e.feature as any] } as any); const bounds = new maplibregl.LngLatBounds(); extendBounds(bounds, geometry.coordinates); if (geometry.type === 'Point') map.easeTo({ center: bounds.getCenter(), zoom: Math.max(map.getZoom(), 15) }); else map.fitBounds(bounds, { padding: 60, maxZoom: 16 }) }))
      draw = createSpatialDraw(map, (geometry) => emitSpatialDrawComplete({ geometry }))
      measurement = createMeasureDraw(map)
      subs.push(onSpatialDrawStart((e) => { measurement?.clear(); polygonMeasurement?.clear(); draw?.start(e.mode) }))
      subs.push(onSpatialDrawFinish(() => draw?.finish()))
      subs.push(onSpatialDrawClear(() => { if (!measurement?.isActive()) draw?.clear() }))
      subs.push(onSpatialDrawGeometry((e) => draw?.showGeometry(e.geometry)))
      subs.push(onMeasureStart(() => { emitSpatialDrawClear(); emitFeatureClear(); polygonMeasurement?.clear(); measurement?.start() }))
      subs.push(onMeasureClear(() => measurement?.clear()))
      subs.push(onMeasureRetry(() => measurement?.retry()))
      subs.push(onPolygonMeasureStart(() => { emitSpatialDrawClear(); emitFeatureClear(); measurement?.clear(); polygonMeasurement?.start() }))
      subs.push(onPolygonMeasureClear(() => polygonMeasurement?.clear()))
      subs.push(onPolygonMeasureRetry(() => polygonMeasurement?.retry()))
      subs.push(() => { emitPolygonMeasureClear(); polygonMeasurement?.destroy(); measurement?.destroy(); draw?.destroy() })
    })
    return () => { subs.forEach((off) => off()); map.remove(); mapRef.current = null }
  }, [config])

  useEffect(() => {
    const map = mapRef.current; if (!map) return
    const apply = () => { for (const layer of config.layers) if (layer.requiresAuth) user && layer.visibleByDefault ? addVectorLayer(map, layer, config.layers) : removeVectorLayer(map, layer); for (const bm of config.basemaps ?? []) if (bm.requiresAuth) user && bm.visibleByDefault ? addRasterBasemap(map, bm, config.basemaps ?? []) : removeRasterBasemap(map, bm) }
    if (map.isStyleLoaded()) apply(); else map.once('load', apply)
  }, [user, config])
  return <div ref={containerRef} style={{ width: '100%', height: '100%' }} />
}
