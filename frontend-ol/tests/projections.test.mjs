import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'

// Exercise the real projections, GeoJSON reader/writer, grids and API client.
// Like drawing.test.mjs, bundle in memory: no generated modules or browser needed.
const root = fileURLToPath(new URL('../', import.meta.url))
const compiled = await build({
  stdin: {
    contents: `
      export * from './src/projections';
      export * from './src/tileGrid';
      export * from './src/api';
      export { isLayerInZoomRange } from './src/config';
      export { default as View } from 'ol/View';
      export { default as Point } from 'ol/geom/Point';
      export { default as Polygon } from 'ol/geom/Polygon';
      export { default as WMTS } from 'ol/source/WMTS';
      export { get as getProjection } from 'ol/proj';
    `,
    resolveDir: root,
  },
  define: { 'import.meta.env.VITE_QUERY_API_URL': JSON.stringify('https://api.example.test/') },
  bundle: true, write: false, format: 'esm', platform: 'node',
})
const api = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)
const config = JSON.parse(await readFile(new URL('../public/config.json', import.meta.url), 'utf8'))

// Authoritative snapshot: api/app/tile_grids.py, verified 2026-09-07.
// Keep all 14 advertised scales/sizes, including the NON-power-of-two steps.
// This is a local fixture, not a request to PostGIS or the live WMTS service.
const scales = [
  7559538.928601667, 3779769.4643008336, 1889884.7321504168,
  944942.3660752084, 472471.1830376042, 236235.5915188021,
  94494.2366075208, 47247.1183037604, 23623.5591518802,
  9449.4236607521, 4724.711830376, 2362.355915188,
  1181.177957594, 755.9538928602,
]
const metadata = {
  id: 'vicgrid', crs: 'EPSG:7899', name: 'GDA2020 / Vicgrid', units: 'metres',
  axisOrder: 'east,north', tileMatrixSet: 'EPSG:7899',
  origin: [1786000, 3081000], tileSize: 512,
  resolutions: scales.map((scale) => scale * 0.00028),
  matrixIds: ['00', '01', '02', '03', '04', '05', '06', '07', '08', '09', '10', '11', '12', '13'],
  sizes: [
    [2, 1], [4, 2], [8, 4], [16, 8], [32, 16], [64, 32],
    [160, 80], [320, 160], [640, 320], [1600, 800],
    [3200, 1600], [6400, 3200], [12800, 6400], [20000, 10000],
  ],
  minZoom: 0, maxZoom: 13, rowDirection: 'down', wrapX: false,
  tileUrlTemplate: '/tiles/vicgrid/{layer}/{z}/{x}/{y}.mvt',
  wmtsCapabilitiesUrl: 'https://base.maps.vic.gov.au/service?SERVICE=WMTS&REQUEST=GetCapabilities&VERSION=1.0.0',
}
const knownWgs84 = [144.3, -37.75]
const knownNative = [2438313.807060187, 2416544.9675707226]
const ring = [[144.96, -37.81], [144.98, -37.81], [144.98, -37.79], [144.96, -37.81]]

function close(actual, expected, tolerance = 1e-8) {
  if (Array.isArray(expected)) {
    assert.equal(actual.length, expected.length)
    actual.forEach((value, index) => close(value, expected[index], tolerance))
  } else {
    assert.ok(Number.isFinite(actual), `Expected finite value, got ${actual}`)
    assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected} (tolerance ${tolerance})`)
  }
}
function noNetwork(t) {
  const fetch = t.mock.method(globalThis, 'fetch', () => { throw new Error('Projection and measurement must never fetch') })
  t.after(() => assert.equal(fetch.mock.callCount(), 0))
}

test('WGS84 -> native Vicgrid matches independently recorded PostGIS coordinates within 1 mm', (t) => {
  noNetwork(t)
  assert.equal(api.MAP_CRS, 'EPSG:7899')
  assert.equal(api.MEASURE_CRS, 'EPSG:7855')
  close(api.fromWgs84(knownWgs84), knownNative, 0.001)
  close(api.toWgs84(knownNative), knownWgs84)
})

test('WGS84 points round-trip across Victoria without mutating input coordinates', (t) => {
  noNetwork(t)
  for (const point of [knownWgs84, [144.9631, -37.8136], [141, -34.2], [149.7, -37.5]]) {
    const original = point.slice()
    const native = api.fromWgs84(point)
    assert.ok(native.every(Number.isFinite))
    close(api.toWgs84(native), original)
    assert.deepEqual(point, original)
  }
})

test('native drawn points and polygons serialize to the EPSG:4326 query boundary', (t) => {
  noNetwork(t)
  assert.deepEqual(api.readOptions, { dataProjection: 'EPSG:4326', featureProjection: 'EPSG:7899' })
  const point = new api.Point(knownNative)
  const pointJson = api.geometryToApi(point)
  assert.equal(pointJson.type, 'Point')
  close(pointJson.coordinates, knownWgs84)
  assert.equal(pointJson.crs, undefined)
  close(point.getCoordinates(), knownNative)

  const nativeRing = ring.map(api.fromWgs84)
  const polygon = new api.Polygon([nativeRing])
  const polygonJson = api.geometryToApi(polygon)
  assert.equal(polygonJson.type, 'Polygon')
  close(polygonJson.coordinates, [ring])
  assert.deepEqual(polygonJson.coordinates[0][0], polygonJson.coordinates[0].at(-1))
  close(polygon.getCoordinates(), [nativeRing])
  close(api.geojson.readGeometry(polygonJson, api.readOptions).getCoordinates(), [nativeRing], 0.001)
})

test('query FeatureCollection and returned queryGeometry become native map geometry, not degree coordinates', (t) => {
  noNetwork(t)
  const collection = {
    type: 'FeatureCollection',
    features: [
      { type: 'Feature', id: 17, properties: { name: 'point' }, geometry: { type: 'Point', coordinates: knownWgs84 } },
      { type: 'Feature', id: 18, properties: { name: 'parcel' }, geometry: { type: 'Polygon', coordinates: [ring] } },
    ],
    queryGeometry: { type: 'Polygon', coordinates: [ring] },
  }
  const original = structuredClone(collection)
  const features = api.geojson.readFeatures(collection, api.readOptions)
  assert.equal(features.length, 2)
  assert.equal(features[0].getId(), 17)
  assert.equal(features[1].get('name'), 'parcel')
  close(features[0].getGeometry().getCoordinates(), knownNative, 0.001)
  close(features[1].getGeometry().getCoordinates(), [ring.map(api.fromWgs84)], 0.001)
  for (const [index, feature] of features.entries()) {
    close(api.geometryToApi(feature.getGeometry()).coordinates, collection.features[index].geometry.coordinates)
  }
  const queryGeometry = api.geojson.readGeometry(collection.queryGeometry, api.readOptions)
  close(queryGeometry.getCoordinates(), [ring.map(api.fromWgs84)], 0.001)
  close(api.geometryToApi(queryGeometry).coordinates, [ring])
  assert.deepEqual(collection, original)
})

test('client MGA55 distance agrees with the original 1109.9241542897053 m PostGIS scenario within 1 cm', (t) => {
  noNetwork(t)
  const start = api.fromWgs84([144.9631, -37.8136])
  const end = api.fromWgs84([144.9631, -37.8036])
  const result = api.measureDistance(start, end)
  close(result.distance, 1109.9241542897053, 0.01)
  assert.deepEqual({ ...result, distance: 0 }, {
    distance: 0, units: 'metres', sourceCrs: 'EPSG:7899', measurementCrs: 'EPSG:7855',
  })
})

test('local measurement is finite, nonnegative, symmetric and zero for identical endpoints', (t) => {
  noNetwork(t)
  const points = [knownWgs84, [144.9631, -37.8136], [145.2, -38.1]].map(api.fromWgs84)
  for (const start of points) {
    assert.equal(api.measureDistance(start, start).distance, 0)
    for (const end of points) {
      const original = [start.slice(), end.slice()]
      const distance = api.measureDistance(start, end).distance
      assert.ok(Number.isFinite(distance) && distance >= 0)
      close(distance, api.measureDistance(end, start).distance, 1e-9)
      assert.deepEqual([start, end], original)
    }
  }
})

test('measurement rejects malformed and nonfinite native endpoints without fetching', (t) => {
  noNetwork(t)
  for (const invalid of [[], [1], [1, 2, 3], [NaN, 1], [1, Infinity], [-Infinity, 1], ['1', 2], [null, 2]]) {
    assert.throws(() => api.measureDistance(invalid, knownNative), /valid map positions/)
    assert.throws(() => api.measureDistance(knownNative, invalid), /valid map positions/)
  }
})

test('both real OL grids retain all 14 authoritative resolutions, origin and matrix sizes', () => {
  assert.equal(api.validateGrid(metadata), metadata)
  const { vector, raster } = api.createGrids(metadata)
  for (const grid of [vector, raster]) {
    assert.deepEqual(grid.getResolutions(), metadata.resolutions)
    assert.equal(grid.getMinZoom(), 0)
    assert.equal(grid.getMaxZoom(), 13)
    for (let z = 0; z <= 13; z++) {
      assert.deepEqual(grid.getOrigin(z), [1786000, 3081000])
      assert.equal(grid.getTileSize(z), 512)
      const range = grid.getFullTileRange(z)
      assert.deepEqual([range.minX, range.minY, range.getWidth(), range.getHeight()], [0, 0, ...metadata.sizes[z]])
    }
    assert.equal(grid.getFullTileRange(6).getWidth(), 160)
    assert.equal(grid.getFullTileRange(6).getHeight(), 80)
    assert.equal(grid.getFullTileRange(13).getWidth(), 20000)
    assert.equal(grid.getFullTileRange(13).getHeight(), 10000)
  }
  close(vector.getResolution(0), 2116.6709000084666, 1e-10)
  close(vector.getResolution(5) / vector.getResolution(6), 2.5)
  close(vector.getResolution(8) / vector.getResolution(9), 2.5)
  close(vector.getResolution(12) / vector.getResolution(13), 1.5625)
  assert.deepEqual(raster.getMatrixIds(), metadata.matrixIds)
})

test('native tile extents share adjacent edges and rows increase southward at every matrix level', () => {
  const { vector, raster } = api.createGrids(metadata)
  for (let z = 0; z <= 13; z++) {
    const span = metadata.resolutions[z] * 512
    const first = vector.getTileCoordExtent([z, 0, 0])
    close(first, [1786000, 3081000 - span, 1786000 + span, 3081000], 1e-8)
    const right = vector.getTileCoordExtent([z, 1, 0])
    close(first[2], right[0])
    close([first[1], first[3]], [right[1], right[3]])
    if (metadata.sizes[z][1] > 1) {
      const below = vector.getTileCoordExtent([z, 0, 1])
      close(first[1], below[3])
      close([first[0], first[2]], [below[0], below[2]])
      assert.ok(below[1] < first[1])
    }
    const [width, height] = metadata.sizes[z]
    const last = [z, width - 1, height - 1]
    close(vector.getTileCoordExtent(last), raster.getTileCoordExtent(last))
    const extent = vector.getTileCoordExtent(last)
    assert.deepEqual(vector.getTileCoordForCoordAndZ([(extent[0] + extent[2]) / 2, (extent[1] + extent[3]) / 2], z), last)
  }
})

test('raster requests use WMTS matrix IDs 00..13 while vector requests use integer z', (t) => {
  noNetwork(t)
  const { raster } = api.createGrids(metadata)
  const source = new api.WMTS({
    url: 'https://wmts.example.test/service', layer: 'CARTO_VG2020',
    matrixSet: 'EPSG:7899', format: 'image/png', style: 'default',
    projection: api.MAP_CRS, tileGrid: raster, wrapX: false,
  })
  t.after(() => source.dispose())
  for (let z = 0; z <= 13; z++) {
    const rasterUrl = new URL(source.getTileUrlFunction()([z, 1, 0], 1, api.getProjection(api.MAP_CRS)))
    // OGC KVP names are case-insensitive; URLSearchParams itself is not.
    const params = Object.fromEntries([...rasterUrl.searchParams].map(([key, value]) => [key.toUpperCase(), value]))
    assert.equal(params.TILEMATRIX, metadata.matrixIds[z])
    assert.equal(params.TILEMATRIXSET, 'EPSG:7899')
    assert.equal(params.TILECOL, '1')
    assert.equal(params.TILEROW, '0')
    assert.equal(api.tileUrl('https://api.example.test/', 'parcel / name', metadata, [z, 1, 0]),
      `https://api.example.test/tiles/vicgrid/parcel%20%2F%20name/${z}/1/0.mvt`)
  }
})

test('cached vector grids overzoom their final native tile and use immutable URLs', () => {
  const grid = api.createVectorGrid(metadata, 0, 10)
  assert.equal(grid.getMinZoom(), 0)
  assert.equal(grid.getMaxZoom(), 10)
  assert.equal(grid.getZForResolution(metadata.resolutions[13]), 10)
  assert.equal(
    api.tileUrl('', 'planning', metadata, [10, 123, 456], 'https://tiles.example.test/cache/{z}/{x}/{y}.mvt'),
    'https://tiles.example.test/cache/10/123/456.mvt',
  )
  assert.equal(api.tileUrl('', 'planning', metadata, [10, -1, 0], 'https://tiles.example.test/cache/{z}/{x}/{y}.mvt'), undefined)
  assert.throws(() => api.createVectorGrid(metadata, 0, 14), /Cache zooms/)
})

test('tile URL range checks use advertised sizes rather than 2 ** z and reject out-of-matrix positions', () => {
  for (let z = 0; z <= 13; z++) {
    const [width, height] = metadata.sizes[z]
    assert.equal(api.tileUrl('/api/', 'parcel', metadata, [z, width - 1, height - 1]),
      `/api/tiles/vicgrid/parcel/${z}/${width - 1}/${height - 1}.mvt`)
    for (const coord of [[z, -1, 0], [z, 0, -1], [z, width, 0], [z, 0, height]]) {
      assert.equal(api.tileUrl('/api', 'parcel', metadata, coord), undefined)
    }
  }
  for (const z of [-1, 14]) assert.equal(api.tileUrl('/api', 'parcel', metadata, [z, 0, 0]), undefined)
  // tileUrl currently checks ranges only; integer/type validation is the backend's contract.
})

test('grid validation rejects incompatible CRS, origin, resolution, size and level metadata', () => {
  for (const patch of [
    { crs: 'EPSG:3857' }, { tileSize: 256 }, { origin: [0] }, { origin: [NaN, 0] },
    { resolutions: [] }, { resolutions: [1, 2] }, { resolutions: [1, 1] },
    { resolutions: [0] }, { resolutions: [Infinity] },
    { sizes: [] }, { sizes: metadata.sizes.map((size, z) => z === 6 ? [0, 80] : size) },
    { sizes: metadata.sizes.map((size, z) => z === 6 ? [160.5, 80] : size) },
    { matrixIds: ['00'] }, { maxZoom: 14 },
  ]) {
    assert.throws(() => api.validateGrid({ ...metadata, ...patch }), /valid EPSG:7899 tile grid/)
  }
})

test('legacy parcel zoom 14 means a ground resolution between native levels 8 and 9, never native 14', (t) => {
  noNetwork(t)
  const latitude = -37.8136
  const parcel = config.layers.find((layer) => layer.id === 'au_vic_dtp_parcel')
  assert.ok(parcel)
  assert.equal(parcel.minZoom, 14)
  const resolution = api.resolutionForZoom(parcel.minZoom, latitude)
  close(resolution, 78271.51696402048 * Math.cos(latitude * Math.PI / 180) / 2 ** 14)
  assert.ok(resolution < metadata.resolutions[8] && resolution > metadata.resolutions[9])
  const view = new api.View({
    projection: api.MAP_CRS, center: api.fromWgs84([144.9631, latitude]),
    resolution, resolutions: metadata.resolutions, constrainResolution: false,
  })
  t.after(() => view.dispose())
  assert.ok(view.getZoom() > 8 && view.getZoom() < 9)
  close(api.equivalentZoom(view.getResolution(), latitude), 14)
  assert.equal(api.isLayerInZoomRange(parcel, api.equivalentZoom(metadata.resolutions[8], latitude)), false)
  assert.equal(api.isLayerInZoomRange(parcel, api.equivalentZoom(metadata.resolutions[9], latitude)), true)
  assert.equal(api.isLayerInZoomRange(parcel, 14), true)
  assert.equal(api.isLayerInZoomRange({ minZoom: 14, maxZoom: 16 }, 16), false)
  for (const lat of [-34, latitude, -39]) {
    for (const zoom of [0, 8, 14, 16, 22]) close(api.equivalentZoom(api.resolutionForZoom(zoom, lat), lat), zoom)
  }
})

test('API query/spatial requests preserve existing JSON contracts and WGS84 geometry; measurement makes no request', async (t) => {
  const collection = { type: 'FeatureCollection', features: [] }
  const fetch = t.mock.method(globalThis, 'fetch', async (url) => {
    assert.ok(['/query', '/spatial-query'].some((path) => url === `https://api.example.test${path}`), `Unexpected network request: ${url}`)
    return { ok: true, json: async () => collection }
  })
  assert.deepEqual(await api.queryLayer('parcel', '1=1'), collection)
  await api.queryLayer('parcel', 'id = 17', 25)
  const geometry = api.geometryToApi(new api.Point(knownNative))
  await api.spatialQuery('parcel', geometry)
  const polygon = api.geometryToApi(new api.Polygon([ring.map(api.fromWgs84)]))
  await api.spatialQuery('parcel', polygon, 100)
  api.measureDistance(knownNative, api.fromWgs84([144.9631, -37.8136]))
  assert.equal(fetch.mock.callCount(), 4)
  const requests = fetch.mock.calls.map(({ arguments: [url, init] }) => {
    assert.equal(init.method, 'POST')
    assert.deepEqual(init.headers, { 'Content-Type': 'application/json' })
    return { url, body: JSON.parse(init.body) }
  })
  assert.deepEqual(requests.slice(0, 2), [
    { url: 'https://api.example.test/query', body: { layer: 'parcel', where: '1=1', f: 'geojson', resultRecordCount: 1000 } },
    { url: 'https://api.example.test/query', body: { layer: 'parcel', where: 'id = 17', f: 'geojson', resultRecordCount: 25 } },
  ])
  assert.deepEqual(requests[2], { url: 'https://api.example.test/spatial-query', body: { layer: 'parcel', geometry, buffer: 0 } })
  assert.deepEqual(requests[3], { url: 'https://api.example.test/spatial-query', body: { layer: 'parcel', geometry: polygon, buffer: 100 } })
  close(requests[2].body.geometry.coordinates, knownWgs84)
  close(requests[3].body.geometry.coordinates, [ring])
})