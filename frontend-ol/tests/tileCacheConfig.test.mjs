import { test } from 'node:test'
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('../', import.meta.url))
const compiled = await build({
  stdin: { contents: "export { loadConfig } from './src/config';", resolveDir: root },
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'node',
  define: { 'import.meta.env.VITE_CONFIG_URL': '"/config.json"' },
})
const moduleSource = Buffer.from(compiled.outputFiles[0].text).toString('base64')
const importFresh = () => import(`data:text/javascript;base64,${moduleSource}#${crypto.randomUUID()}`)

const baseConfig = {
  projection: 'EPSG:7899',
  tileGridUrl: '/tiles/grids/vicgrid',
  tileCache: {
    baseUrl: 'https://tiles.example.test',
    prefix: 'tiles',
    schema: 'public',
    fallbackToApi: true,
  },
  layers: [{
    id: 'planning',
    label: 'Planning',
    visibleByDefault: true,
    opacity: 0.4,
    color: '#1976d2',
    cache: { enabled: true, grid: 'vicgrid', minZoom: 0, maxZoom: 10, fields: '*' },
  }, {
    id: 'uncached',
    label: 'Uncached',
    visibleByDefault: false,
    opacity: 0.4,
    color: '#000000',
    cache: { enabled: false },
  }],
}

function jsonResponse(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } })
}

test('cache-enabled native layers resolve immutable CloudFront URLs once', async () => {
  const oldFetch = globalThis.fetch
  const calls = []
  globalThis.fetch = async (url, options) => {
    calls.push({ url: String(url), cache: options?.cache })
    if (url === '/config.json') return jsonResponse(baseConfig)
    if (String(url).endsWith('/latest.json')) return jsonResponse({
      version: 'release-1',
      baseKey: 'tiles/public/planning/vicgrid/release-1',
      manifestKey: 'tiles/public/planning/vicgrid/release-1/tilejson.json',
    })
    if (String(url).endsWith('/tilejson.json')) return jsonResponse({
      name: 'planning',
      grid: 'vicgrid',
      minzoom: 0,
      maxzoom: 10,
      bounds: [140, -39, 150, -34],
      vector_layers: [{ id: 'planning' }],
    })
    throw new Error(`Unexpected URL ${url}`)
  }
  try {
    const { loadConfig } = await importFresh()
    const first = await loadConfig()
    const second = await loadConfig()
    assert.strictEqual(first, second, 'configuration should be fetched and resolved once')
    assert.equal(calls.length, 3)
    assert.equal(calls[1].cache, 'no-cache')
    assert.equal(calls[2].cache, 'force-cache')
    assert.equal(first.layers[0].resolvedCache.tileUrl, 'https://tiles.example.test/tiles/public/planning/vicgrid/release-1/{z}/{x}/{y}.mvt')
    assert.equal(first.layers[0].resolvedCache.maxZoom, 10)
    assert.deepEqual(first.layers[0].resolvedCache.bounds, [140, -39, 150, -34])
    assert.equal(first.layers[1].resolvedCache, undefined)
  } finally {
    globalThis.fetch = oldFetch
  }
})

test('cache discovery failure falls back to the native dynamic API when configured', async () => {
  const oldFetch = globalThis.fetch
  const oldWarn = console.warn
  console.warn = () => {}
  globalThis.fetch = async (url) => url === '/config.json' ? jsonResponse(baseConfig) : jsonResponse({}, 404)
  try {
    const { loadConfig } = await importFresh()
    const config = await loadConfig()
    assert.equal(config.layers[0].resolvedCache, undefined)
  } finally {
    globalThis.fetch = oldFetch
    console.warn = oldWarn
  }
})

test('cache metadata mismatch is fatal when API fallback is disabled', async () => {
  const oldFetch = globalThis.fetch
  const strictConfig = { ...baseConfig, tileCache: { ...baseConfig.tileCache, fallbackToApi: false } }
  globalThis.fetch = async (url) => {
    if (url === '/config.json') return jsonResponse(strictConfig)
    return jsonResponse({}, 404)
  }
  try {
    const { loadConfig } = await importFresh()
    await assert.rejects(loadConfig(), /returned 404/)
  } finally {
    globalThis.fetch = oldFetch
  }
})

test('OpenLayers rejects non-Vicgrid cache metadata', async () => {
  const oldFetch = globalThis.fetch
  const wrongGrid = structuredClone(baseConfig)
  wrongGrid.tileCache.fallbackToApi = false
  wrongGrid.layers[0].cache.grid = 'webmercator'
  globalThis.fetch = async (url) => url === '/config.json' ? jsonResponse(wrongGrid) : jsonResponse({}, 500)
  try {
    const { loadConfig } = await importFresh()
    await assert.rejects(loadConfig(), /requires a Vicgrid cache/)
  } finally {
    globalThis.fetch = oldFetch
  }
})