import { test } from 'node:test'
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url))
const compiled = await build({
  stdin: { contents: "export { createPolygonMeasureSelect } from './src/polygonMeasureSelect'; export { onPolygonMeasureState, emitPolygonSegmentHover } from './src/events';", resolveDir: root },
  bundle: true, write: false, format: 'esm', platform: 'node',
  define: { 'import.meta.env.VITE_QUERY_API_URL': '"http://api.test"' },
})
const { createPolygonMeasureSelect, onPolygonMeasureState, emitPolygonSegmentHover } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)
const flush = () => new Promise((resolve) => setImmediate(resolve))

function mockMap(feature) {
  const sources = new Map(), layers = new Map()
  const canvas = { style: {}, focused: false, focus() { this.focused = true } }
  return {
    sources, layers, canvas,
    getCanvas: () => canvas,
    addSource(id, source) { sources.set(id, { ...source, setData(data) { this.data = data } }) },
    getSource: (id) => sources.get(id), removeSource: (id) => sources.delete(id),
    addLayer: (layer) => layers.set(layer.id, layer), getLayer: (id) => layers.get(id), removeLayer: (id) => layers.delete(id),
    queryRenderedFeatures: () => feature ? [feature] : [],
  }
}

const polygon = {
  type: 'Polygon',
  coordinates: [[[144.95, -37.82], [144.951, -37.82], [144.951, -37.819], [144.95, -37.82]]],
}
const result = {
  area: 5000,
  perimeter: 300,
  segments: [
    { polygonIndex: 0, ringIndex: 0, segmentIndex: 0, length: 100 },
    { polygonIndex: 0, ringIndex: 0, segmentIndex: 1, length: 100 },
    { polygonIndex: 0, ringIndex: 0, segmentIndex: 2, length: 100 },
  ],
  lengthUnits: 'metres', areaUnits: 'square_metres', sourceCrs: 'EPSG:4326', measurementCrs: 'EPSG:7855',
}

test('click fetches authoritative geometry, measures it, highlights it and supports cleanup', async () => {
  const oldWindow = globalThis.window, oldFetch = globalThis.fetch
  const keys = new Map(), calls = []
  globalThis.window = { addEventListener: (e, f) => keys.set(e, f), removeEventListener: (e) => keys.delete(e) }
  globalThis.fetch = async (url, options) => {
    calls.push({ url, ...options })
    if (url.endsWith('/query')) return new Response(JSON.stringify({ type: 'FeatureCollection', features: [{ type: 'Feature', geometry: polygon, properties: { OBJECTID: 42 } }] }))
    return new Response(JSON.stringify(result))
  }
  const states = []
  const unsubscribe = onPolygonMeasureState((state) => states.push(state))
  const map = mockMap({ source: 'parcels', properties: { OBJECTID: 42 } })
  map.layers.set('parcels-fill', { id: 'parcels-fill' })
  const select = createPolygonMeasureSelect(map, ['parcels'])
  try {
    select.start()
    assert.equal(select.isSelecting(), true)
    assert.equal(map.canvas.style.cursor, 'crosshair')
    select.select({ point: { x: 10, y: 20 } })
    assert.equal(select.isActive(), true, 'pending request must continue blocking ordinary map clicks')
    await flush(); await flush()

    assert.equal(calls[0].url, 'http://api.test/query')
    assert.deepEqual(JSON.parse(calls[0].body), { layer: 'parcels', where: '"OBJECTID" = 42', f: 'geojson', resultRecordCount: 2 })
    assert.equal(calls[1].url, 'http://api.test/measure/polygon')
    assert.deepEqual(JSON.parse(calls[1].body), { geometry: polygon })
    assert.equal(states.at(-1).status, 'complete')
    assert.equal(states.at(-1).result.area, 5000)
    assert.deepEqual(map.sources.get('polygon-measurement').data.features[0].geometry, polygon)
    assert.equal(select.isActive(), false)

    emitPolygonSegmentHover({ polygonIndex: 0, ringIndex: 0, segmentIndex: 1 })
    assert.deepEqual(
      map.sources.get('polygon-measurement-segment').data.features[0].geometry,
      { type: 'LineString', coordinates: [[144.951, -37.82], [144.951, -37.819]] },
    )
    emitPolygonSegmentHover(null)
    assert.equal(map.sources.get('polygon-measurement-segment').data.features.length, 0)

    select.clear()
    assert.equal(map.sources.get('polygon-measurement').data.features.length, 0)
    select.start()
    keys.get('keydown')({ key: 'Escape' })
    assert.equal(states.at(-1).status, 'idle')
    select.destroy()
    assert.equal(map.sources.size, 0)
    assert.equal(map.layers.has('polygon-measurement-fill'), false)
    assert.equal(map.layers.has('polygon-measurement-line'), false)
    assert.equal(map.layers.has('polygon-measurement-segment-line'), false)
    assert.equal(keys.size, 0)
    assert.equal(states.at(-1).status, 'unavailable')
  } finally {
    unsubscribe()
    globalThis.window = oldWindow
    globalThis.fetch = oldFetch
  }
})

test('missing IDs fail locally and multipart geometry is measured', async () => {
  const oldWindow = globalThis.window, oldFetch = globalThis.fetch
  globalThis.window = { addEventListener() {}, removeEventListener() {} }
  const states = []
  const unsubscribe = onPolygonMeasureState((state) => states.push(state))
  let fetchCount = 0
  globalThis.fetch = async () => {
    fetchCount++
    if (fetchCount === 1) return new Response(JSON.stringify({ type: 'FeatureCollection', features: [{ type: 'Feature', geometry: { type: 'MultiPolygon', coordinates: [polygon.coordinates] }, properties: {} }] }))
    return new Response(JSON.stringify(result))
  }
  try {
    const missingIdMap = mockMap({ source: 'parcels', properties: {} })
    missingIdMap.layers.set('parcels-fill', {})
    const missingId = createPolygonMeasureSelect(missingIdMap, ['parcels'])
    missingId.start(); missingId.select({ point: {} })
    assert.match(states.at(-1).error, /OBJECTID/)
    assert.equal(fetchCount, 0)
    missingId.destroy()

    const multipartMap = mockMap({ source: 'parcels', properties: { OBJECTID: 7 } })
    multipartMap.layers.set('parcels-fill', {})
    const multipart = createPolygonMeasureSelect(multipartMap, ['parcels'])
    multipart.start(); multipart.select({ point: {} })
    await flush(); await flush()
    assert.equal(states.at(-1).status, 'complete')
    assert.equal(fetchCount, 2)
    multipart.destroy()
  } finally {
    unsubscribe()
    globalThis.window = oldWindow
    globalThis.fetch = oldFetch
  }
})
