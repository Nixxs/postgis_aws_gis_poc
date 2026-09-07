import { test } from 'node:test'
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url))
const compiled = await build({
  stdin: { contents: "export { createMeasureDraw } from './src/measureDraw'; export { onMeasureState } from './src/events';", resolveDir: root },
  bundle: true, write: false, format: 'esm', platform: 'node',
  define: { 'import.meta.env.VITE_QUERY_API_URL': '"http://api.test"' },
})
const { createMeasureDraw, onMeasureState } = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)
const flush = () => new Promise((resolve) => setImmediate(resolve))

function mockMap() {
  const handlers = new Map(), sources = new Map(), layers = new Map()
  let zoom = true
  const canvas = { style: {}, focus() {} }
  return {
    handlers, sources, layers,
    getCanvas: () => canvas,
    doubleClickZoom: { isEnabled: () => zoom, enable: () => { zoom = true }, disable: () => { zoom = false } },
    addSource(id, source) { sources.set(id, { ...source, setData(data) { this.data = data } }) },
    getSource: (id) => sources.get(id), removeSource: (id) => sources.delete(id),
    addLayer: (layer) => layers.set(layer.id, layer), getLayer: (id) => layers.get(id), removeLayer: (id) => layers.delete(id),
    on(event, fn) { handlers.set(event, fn) }, off(event) { handlers.delete(event) },
    fire(event, lng, lat) { handlers.get(event)?.({ lngLat: { wrap: () => ({ lng, lat }) } }) },
  }
}

test('two clicks call endpoint; preview, retry, abort and cleanup work', async () => {
  const oldWindow = globalThis.window, oldFetch = globalThis.fetch
  const keys = new Map()
  globalThis.window = { addEventListener: (e, f) => keys.set(e, f), removeEventListener: (e) => keys.delete(e) }
  const states = []
  const unsubscribe = onMeasureState((state) => states.push(state))
  const map = mockMap()
  const draw = createMeasureDraw(map)
  const result = { distance: 1110.25, units: 'metres', sourceCrs: 'EPSG:4326', measurementCrs: 'EPSG:7855' }
  const calls = []
  globalThis.fetch = async (url, options) => {
    calls.push({ url, ...options })
    return new Response(JSON.stringify(result), { status: 200 })
  }
  try {
    draw.start()
    assert.equal(map.doubleClickZoom.isEnabled(), false)
    map.fire('click', 144.96, -37.81)
    map.fire('mousemove', 144.97, -37.8)
    assert.equal(calls.length, 0, 'preview must not call backend')
    assert.equal(map.sources.get('measurement').data.features[0].geometry.type, 'LineString')
    map.fire('click', 144.97, -37.8)
    await flush()
    assert.equal(calls[0].url, 'http://api.test/measure')
    assert.deepEqual(JSON.parse(calls[0].body), { start: [144.96, -37.81], end: [144.97, -37.8] })
    assert.equal(states.at(-1).result.distance, 1110.25)
    assert.equal(draw.isActive(), false)
    assert.equal(map.doubleClickZoom.isEnabled(), true)

    globalThis.fetch = async () => new Response('{}', { status: 404 })
    draw.retry()
    await flush()
    assert.equal(states.at(-1).status, 'error')
    assert.match(states.at(-1).error, /Rebuild or deploy/)
    globalThis.fetch = async () => new Response(JSON.stringify(result))
    draw.retry()
    await flush()
    assert.equal(states.at(-1).status, 'complete')

    let resolveRequest, signal
    globalThis.fetch = (_url, options) => { signal = options.signal; return new Promise((resolve) => { resolveRequest = resolve }) }
    draw.retry()
    draw.clear()
    assert.equal(signal.aborted, true)
    resolveRequest(new Response(JSON.stringify(result)))
    await flush()
    assert.equal(states.at(-1).status, 'idle', 'stale response must not restore result')
    assert.equal(map.sources.get('measurement').data.features.length, 0)
    draw.start()
    keys.get('keydown')({ key: 'Escape' })
    assert.equal(draw.isActive(), false)
    draw.destroy()
    assert.equal(map.sources.size, 0)
    assert.equal(map.layers.size, 0)
    assert.equal(map.handlers.size, 0)
    assert.equal(keys.size, 0)
    assert.equal(states.at(-1).status, 'unavailable')
  } finally {
    unsubscribe()
    globalThis.window = oldWindow
    globalThis.fetch = oldFetch
  }
})