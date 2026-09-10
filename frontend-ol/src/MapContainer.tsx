import { useEffect, useRef, useState } from 'react'
import { Alert, Box, Button, CircularProgress, IconButton, Paper, Stack, TextField, Tooltip } from '@mui/material'
import MyLocationIcon from '@mui/icons-material/MyLocation'
import GpsFixedIcon from '@mui/icons-material/GpsFixed'
import Map from 'ol/Map'
import View from 'ol/View'
import Feature from 'ol/Feature'
import MVT from 'ol/format/MVT'
import Point from 'ol/geom/Point'
import CircleGeometry from 'ol/geom/Circle'
import VectorLayer from 'ol/layer/Vector'
import VectorTileLayer from 'ol/layer/VectorTile'
import TileLayer from 'ol/layer/Tile'
import type BaseLayer from 'ol/layer/Base'
import VectorSource from 'ol/source/Vector'
import VectorTileSource from 'ol/source/VectorTile'
import WMTS from 'ol/source/WMTS'
import { defaults as defaultControls } from 'ol/control/defaults'
import ScaleLine from 'ol/control/ScaleLine'
import { Circle as CircleStyle, Fill, Stroke, Style } from 'ol/style'
import { asArray } from 'ol/color'
import { unByKey } from 'ol/Observable'
import type { EventsKey } from 'ol/events'
import { isEmpty } from 'ol/extent'
import { transformExtent } from 'ol/proj'
import type { FeatureLike } from 'ol/Feature'
import type { AppConfig } from './config'
import { isLayerInZoomRange } from './config'
import type { FeatureCollection } from './api'
import { useAuth } from './auth'
import { createDrawingTools } from './drawingTools'
import { createPolygonMeasureSelect } from './polygonMeasureSelect'
import { createGrids, createVectorGrid, tileUrl, validateGrid } from './tileGrid'
import { MAP_CRS, fromWgs84, toWgs84, geojson, readOptions, equivalentZoom, resolutionForZoom } from './projections'
import { onLayerToggle, onQueryResult, onQueryResultMulti, onClearQuery, onResultFeatureSelect, onFeatureClear, emitFeatureSelect, emitFeatureClear, emitMapZoom, emitMeasureClear, emitSpatialDrawClear, onMeasureStart, onSpatialDrawStart, onPolygonMeasureStart, onPolygonMeasureClear, onPolygonMeasureRetry } from './events'
import 'ol/ol.css'
import './map.css'

function style(color: string, opacity: number, width = 1) {
  const fill = asArray(color).slice(); fill[3] = opacity
  return new Style({
    fill: new Fill({ color: fill }),
    stroke: new Stroke({ color, width }),
    image: new CircleStyle({ radius: 5, fill: new Fill({ color }), stroke: new Stroke({ color: '#fff', width: 1 }) }),
  })
}
function propertiesOf(feature: FeatureLike): Record<string, unknown> {
  const properties = { ...feature.getProperties() }
  delete properties.geometry
  delete properties.__mvt_layer
  return properties
}

export default function MapContainer({ config }: { config: AppConfig }) {
  const containerRef = useRef<HTMLDivElement>(null)
  const mapRef = useRef<Map | null>(null)
  const markerRef = useRef<VectorSource | null>(null)
  const gpsRef = useRef<VectorSource | null>(null)
  const authChangedRef = useRef<() => void>(() => {})
  const { user } = useAuth()
  const userRef = useRef(user); userRef.current = user
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [retry, setRetry] = useState(0)
  const [gotoOpen, setGotoOpen] = useState(false)
  const [latitude, setLatitude] = useState('')
  const [longitude, setLongitude] = useState('')
  const [tracking, setTracking] = useState(false)

  useEffect(() => { authChangedRef.current() }, [user])
  useEffect(() => {
    if (!containerRef.current) return
    const target = containerRef.current
    const abort = new AbortController()
    const subscriptions: Array<() => void> = []
    const keys: EventsKey[] = []
    let map: Map | undefined
    let resize: ResizeObserver | undefined
    let drawing: ReturnType<typeof createDrawingTools> | undefined
    let polygonMeasure: ReturnType<typeof createPolygonMeasureSelect> | undefined
    const sources: Array<VectorSource | VectorTileSource | WMTS> = []
    const configuredLayers = new globalThis.Map<string, BaseLayer>()
    const requested = new globalThis.Map([...config.layers, ...(config.basemaps ?? [])].map((l) => [l.id, l.visibleByDefault]))
    let applyVisibility = () => {}
    // Preserve toggle intent even while metadata is still loading.
    subscriptions.push(onLayerToggle(({ id, visible }) => { requested.set(id, visible); applyVisibility() }))
    authChangedRef.current = () => applyVisibility()
    setError(null); setLoading(true)
    const base = (import.meta.env.VITE_TILE_API_URL || '').replace(/\/$/, '')
    const metadataUrl = /^https?:\/\//i.test(config.tileGridUrl) ? config.tileGridUrl : `${base}/${config.tileGridUrl.replace(/^\//, '')}`
    async function initialize() {
      if (config.projection !== MAP_CRS) throw new Error('This frontend requires an EPSG:7899 configuration.')
      const response = await fetch(metadataUrl, { signal: abort.signal })
      if (!response.ok) throw new Error(`Native tile grid unavailable (HTTP ${response.status}). Deploy the Vicgrid backend endpoints first.`)
      const definition = validateGrid(await response.json())
      if (abort.signal.aborted) return
      const grids = createGrids(definition)
      const view = new View({ projection: MAP_CRS, center: fromWgs84([144.9631, -37.8136]), resolution: resolutionForZoom(8), resolutions: definition.resolutions, constrainResolution: false })
      const currentMap = new Map({ target, view, controls: defaultControls({ rotateOptions: { autoHide: false } }).extend([new ScaleLine({ units: 'metric' })]) })
      map = currentMap; mapRef.current = currentMap
      const tileError = () => { if (!abort.signal.aborted) setError('Some map tiles could not load. Check the backend, network connection, and configured native basemap URLs.') }
      for (const [index, bm] of (config.basemaps ?? []).entries()) {
        const url = new URL(bm.url)
        if (url.searchParams.get('TILEMATRIXSET') !== MAP_CRS) throw new Error(`Basemap ${bm.label} must use the EPSG:7899 WMTS matrix set.`)
        const source = new WMTS({ url: `${url.origin}${url.pathname}`, layer: url.searchParams.get('LAYER') || '', matrixSet: MAP_CRS, format: url.searchParams.get('FORMAT') || 'image/png', style: url.searchParams.get('STYLE') || 'default', projection: MAP_CRS, tileGrid: grids.raster, wrapX: false, crossOrigin: 'anonymous', attributions: bm.attribution })
        keys.push(source.on('tileloaderror', tileError)); sources.push(source)
        const layer = new TileLayer({ source, visible: false, zIndex: 10 + (config.basemaps?.length ?? 0) - index })
        configuredLayers.set(bm.id, layer); currentMap.addLayer(layer)
      }
      for (const [index, item] of config.layers.entries()) {
        const cache = item.resolvedCache
        const sourceGrid = cache ? createVectorGrid(definition, cache.minZoom, cache.maxZoom) : grids.vector
        const extent = cache ? transformExtent(cache.bounds, 'EPSG:4326', MAP_CRS, 8) : undefined
        const source = new VectorTileSource({ projection: MAP_CRS, extent, tileGrid: sourceGrid, format: new MVT({ layers: [item.id], layerName: '__mvt_layer' }), wrapX: false, tileUrlFunction: (coord) => tileUrl(base, item.id, definition, coord, cache?.tileUrl) })
        keys.push(source.on('tileloaderror', tileError)); sources.push(source)
        const layer = new VectorTileLayer({ source, extent, visible: false, style: style(item.color, item.opacity), zIndex: 100 + config.layers.length - index, properties: { configId: item.id } })
        configuredLayers.set(item.id, layer); currentMap.addLayer(layer)
      }
      const results = new VectorSource(), resultHighlight = new VectorSource(), marker = new VectorSource(), gps = new VectorSource()
      sources.push(results, resultHighlight, marker, gps)
      markerRef.current = marker; gpsRef.current = gps
      currentMap.addLayer(new VectorLayer({ source: results, style: style('#e91e63', 0.35, 2), zIndex: 3000 }))
      currentMap.addLayer(new VectorLayer({ source: resultHighlight, style: style('#ffeb3b', 0.4, 3), zIndex: 3001 }))
      currentMap.addLayer(new VectorLayer({ source: marker, style: style('#e91e63', 0.2, 2), zIndex: 6000 }))
      currentMap.addLayer(new VectorLayer({ source: gps, style: style('#1976d2', 0.1, 2), zIndex: 6001 }))
      let selectedLayer: VectorTileLayer | undefined
      let selectedId: string | undefined
      const clearSelection = () => { if (selectedLayer) { currentMap.removeLayer(selectedLayer); selectedLayer.dispose() }; selectedLayer = undefined; selectedId = undefined }
      subscriptions.push(onFeatureClear(clearSelection))
      applyVisibility = () => {
        const center = view.getCenter()!
        const zoom = equivalentZoom(view.getResolution()!, toWgs84(center)[1])
        for (const item of [...config.layers, ...(config.basemaps ?? [])]) {
          const rule = config.layers.find((layer) => layer.id === item.id) ?? {}
          const visible = !!requested.get(item.id) && (!item.requiresAuth || !!userRef.current) && isLayerInZoomRange(rule, zoom)
          configuredLayers.get(item.id)?.setVisible(visible)
          if (!visible && selectedId === item.id) emitFeatureClear()
        }
        emitMapZoom({ zoom })
      }
      keys.push(view.on('change:resolution', applyVisibility), view.on('change:center', applyVisibility))
      applyVisibility()
      function fit(source: VectorSource, zoom: number, padding = 40) {
        const extent = source.getExtent()
        if (extent && !isEmpty(extent) && extent.every(Number.isFinite)) view.fit(extent, { padding: [padding, padding, padding, padding], duration: 400, minResolution: resolutionForZoom(zoom, toWgs84(view.getCenter()!)[1]) })
      }
      function showResults(collection: FeatureCollection, zoom: number) {
        results.clear(); resultHighlight.clear()
        results.addFeatures(geojson.readFeatures(collection, readOptions))
        fit(results, zoom)
      }
      subscriptions.push(onQueryResult(({ geojson: data }) => showResults(data, 14)))
      subscriptions.push(onQueryResultMulti(({ results: data }) => showResults({ type: 'FeatureCollection', features: data.flatMap((r) => r.geojson.features) }, 16)))
      subscriptions.push(onClearQuery(() => { results.clear(); resultHighlight.clear() }))
      subscriptions.push(onResultFeatureSelect(({ feature }) => {
        resultHighlight.clear()
        if (!feature.geometry) return
        const nativeFeature = geojson.readFeatures(feature, readOptions)[0]
        if (!nativeFeature) return
        resultHighlight.addFeature(nativeFeature)
        fit(resultHighlight, nativeFeature.getGeometry() instanceof Point ? Math.max(15, equivalentZoom(view.getResolution()!, toWgs84(view.getCenter()!)[1])) : 16, 60)
      }))
      drawing = createDrawingTools(currentMap)
      polygonMeasure = createPolygonMeasureSelect(currentMap)
      subscriptions.push(onPolygonMeasureStart(() => {
        emitSpatialDrawClear()
        emitMeasureClear()
        emitFeatureClear()
        polygonMeasure?.start()
      }))
      subscriptions.push(onPolygonMeasureClear(() => polygonMeasure?.clear()))
      subscriptions.push(onPolygonMeasureRetry(() => polygonMeasure?.retry()))
      subscriptions.push(onSpatialDrawStart(() => polygonMeasure?.clear()))
      subscriptions.push(onMeasureStart(() => polygonMeasure?.clear()))
      keys.push(currentMap.on('singleclick', (event) => {
        if (polygonMeasure?.isSelecting()) { polygonMeasure.select(event); return }
        if (drawing?.isActive() || polygonMeasure?.isActive()) return
        currentMap.forEachFeatureAtPixel(event.pixel, (feature, layer) => {
          const id = layer.get('configId') as string
          const properties = propertiesOf(feature)
          clearSelection(); selectedId = id
          const source = (layer as VectorTileLayer).getSource()!
          const highlight = style('#ffeb3b', 0, 3)
          selectedLayer = new VectorTileLayer({ source, zIndex: 3002, style: (candidate) => {
            const p = propertiesOf(candidate)
            return Object.keys(properties).length > 0 && Object.entries(properties).every(([k, v]) => p[k] === v) ? highlight : undefined
          } })
          currentMap.addLayer(selectedLayer)
          emitFeatureSelect({ layer: id, properties })
          return true
        }, { layerFilter: (layer) => !!layer.get('configId'), hitTolerance: 3 })
      }))
      keys.push(currentMap.on('pointermove', (event) => {
        if (drawing?.isActive() || polygonMeasure?.isActive() || event.dragging) return
        currentMap.getViewport().style.cursor = currentMap.hasFeatureAtPixel(event.pixel, { layerFilter: (layer) => !!layer.get('configId'), hitTolerance: 3 }) ? 'pointer' : ''
      }))
      resize = new ResizeObserver(() => currentMap.updateSize()); resize.observe(target)
      setLoading(false)
    }
    initialize().catch((e: unknown) => {
      if (!abort.signal.aborted) { setError(e instanceof Error ? e.message : String(e)); setLoading(false) }
    })
    return () => {
      abort.abort(); subscriptions.forEach((off) => off()); unByKey(keys); resize?.disconnect(); polygonMeasure?.destroy(); drawing?.destroy()
      authChangedRef.current = () => {}; markerRef.current = null; gpsRef.current = null; mapRef.current = null
      map?.getLayers().forEach((layer) => layer.dispose()); map?.dispose(); sources.forEach((source) => source.dispose())
    }
  }, [config, retry])

  useEffect(() => {
    if (!tracking) { gpsRef.current?.clear(); return }
    if (!navigator.geolocation) { setError('Geolocation is not supported by this browser.'); setTracking(false); return }
    let centered = false
    const watch = navigator.geolocation.watchPosition(({ coords }) => {
      const map = mapRef.current, source = gpsRef.current
      if (!map || !source) return
      const coordinate = fromWgs84([coords.longitude, coords.latitude])
      source.clear(); source.addFeatures([new Feature(new CircleGeometry(coordinate, coords.accuracy)), new Feature(new Point(coordinate))])
      if (!centered) { map.getView().animate({ center: coordinate, resolution: resolutionForZoom(14, coords.latitude), duration: 500 }); centered = true }
    }, (e) => { setError(`Geolocation: ${e.message}`); setTracking(false) }, { enableHighAccuracy: true })
    return () => navigator.geolocation.clearWatch(watch)
  }, [tracking, retry])
  function goToLocation() {
    const lat = Number(latitude), lon = Number(longitude)
    if (!latitude.trim() || !longitude.trim() || !Number.isFinite(lat) || !Number.isFinite(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180) { setError('Enter a valid latitude (-90 to 90) and longitude (-180 to 180).'); return }
    const coordinate = fromWgs84([lon, lat]), view = mapRef.current?.getView()
    if (!coordinate.every(Number.isFinite) || !view) return
    markerRef.current?.clear(); markerRef.current?.addFeature(new Feature(new Point(coordinate)))
    view.animate({ center: coordinate, resolution: Math.min(view.getResolution()!, resolutionForZoom(14, lat)), duration: 500 }); setGotoOpen(false)
  }
  return <Box sx={{ width: '100%', height: '100%', position: 'relative', bgcolor: '#eef0f2' }}>
    <div ref={containerRef} className="vicgrid-map" tabIndex={0} aria-label="GDA2020 Vicgrid map" style={{ width: '100%', height: '100%' }} />
    <Stack spacing={1} sx={{ position: 'absolute', left: 8, top: 8 }}>
      <Paper><Tooltip title={tracking ? 'Stop tracking location' : 'Find my location'}><span><IconButton aria-label="Find my location" color={tracking ? 'primary' : 'default'} disabled={loading} onClick={() => setTracking((v) => !v)}><MyLocationIcon fontSize="small" /></IconButton></span></Tooltip></Paper>
      <Paper><Tooltip title="Go to latitude / longitude"><span><IconButton aria-label="Go to latitude / longitude" disabled={loading} onClick={() => setGotoOpen((v) => !v)}><GpsFixedIcon fontSize="small" /></IconButton></span></Tooltip></Paper>
    </Stack>
    {gotoOpen && <Paper sx={{ position: 'absolute', top: 52, left: 56, p: 1, width: 200 }}><Stack spacing={1} onKeyDown={(e) => { if (e.key === 'Enter') goToLocation() }}>
      <TextField label="Latitude" size="small" type="number" value={latitude} onChange={(e) => setLatitude(e.target.value)} />
      <TextField label="Longitude" size="small" type="number" value={longitude} onChange={(e) => setLongitude(e.target.value)} />
      <Stack direction="row"><Button onClick={goToLocation}>Go</Button><Button onClick={() => { markerRef.current?.clear(); setLatitude(''); setLongitude('') }}>Clear</Button></Stack>
    </Stack></Paper>}
    {loading && <Paper sx={{ position: 'absolute', top: 12, left: '50%', transform: 'translateX(-50%)', p: 1 }}><Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}><CircularProgress size={18} /><span>Loading native Vicgrid map…</span></Stack></Paper>}
    {error && <Alert severity="warning" onClose={() => setError(null)} sx={{ position: 'absolute', top: 8, left: 60, right: 60 }} action={<Button color="inherit" onClick={() => setRetry((v) => v + 1)}>Retry</Button>}>{error}</Alert>}
  </Box>
}