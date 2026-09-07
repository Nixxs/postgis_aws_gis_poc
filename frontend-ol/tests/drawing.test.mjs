import { test } from 'node:test'
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { fileURLToPath } from 'node:url'

// Bundle the real controller, event bus, projections AND OL implementation in
// memory. Only the map host/DOM target and clock are mocked; Draw is not mocked.
const root = fileURLToPath(new URL('../', import.meta.url))
const compiled = await build({
  stdin: {
    contents: `
      export { createDrawingTools } from './src/drawingTools';
      export * from './src/events';
      export * from './src/projections';
      export { default as Observable } from 'ol/Observable';
      export { default as Collection } from 'ol/Collection';
      export { default as View } from 'ol/View';
      export { default as Draw } from 'ol/interaction/Draw';
      export { default as DoubleClickZoom } from 'ol/interaction/DoubleClickZoom';
      export { default as MapBrowserEvent } from 'ol/MapBrowserEvent';
    `,
    resolveDir: root,
  },
  bundle: true, write: false, format: 'esm', platform: 'node',
})
const api = await import(`data:text/javascript;base64,${Buffer.from(compiled.outputFiles[0].text).toString('base64')}`)

class KeyboardTarget extends EventTarget {
  listeners = new Set()
  addEventListener(type, fn, options) { this.listeners.add(fn); super.addEventListener(type, fn, options) }
  removeEventListener(type, fn, options) { this.listeners.delete(fn); super.removeEventListener(type, fn, options) }
  escape() {
    const event = new Event('keydown', { cancelable: true })
    Object.defineProperty(event, 'key', { value: 'Escape' })
    this.dispatchEvent(event)
    return event
  }
}

class MapHost extends api.Observable {
  interactions = new api.Collection()
  layers = []
  keyboard = new KeyboardTarget()
  viewport = { ownerDocument: this.keyboard, style: { cursor: 'grab' } }
  view = new api.View({ projection: api.MAP_CRS, center: [2500000, 2500000], resolution: 1 })
  getViewport() { return this.viewport }
  getInteractions() { return this.interactions }
  getView() { return this.view }
  getPixelFromCoordinate(coordinate) { return coordinate.slice() }
  getCoordinateFromPixel(pixel) { return pixel.slice() }
  render() {}
  addLayer(layer) { this.layers.push(layer) }
  removeLayer(layer) { this.layers = this.layers.filter((value) => value !== layer) }
  addInteraction(interaction) { this.interactions.push(interaction); interaction.setMap(this) }
  removeInteraction(interaction) { this.interactions.remove(interaction); interaction.setMap(null) }
  get draw() { return this.interactions.getArray().find((interaction) => interaction instanceof api.Draw) }
  source(zIndex) { return this.layers.find((layer) => layer.getZIndex() === zIndex).getSource() }
  fire(type, coordinate) {
    const original = {
      type, button: 0, isPrimary: true, pointerType: 'mouse',
      altKey: false, ctrlKey: false, metaKey: false, shiftKey: false,
      preventDefault() {}, stopPropagation() {},
    }
    const event = new api.MapBrowserEvent(type, this, original, false, undefined,
      type === 'pointerdown' ? [original] : [])
    event.coordinate = coordinate.slice()
    event.pixel = coordinate.slice()
    // OL dispatches map listeners before interactions (parent selection must use isActive()).
    if (this.dispatchEvent(event) !== false) {
      for (const interaction of this.interactions.getArray().slice().reverse()) {
        if (interaction.getActive() && interaction.handleEvent(event) === false) break
      }
    }
    return event
  }
  click(coordinate) { this.fire('pointerdown', coordinate); return this.fire('pointerup', coordinate) }
}

function setup(t) {
  let now = 0, nextId = 0
  const timers = new Map()
  t.mock.method(globalThis, 'setTimeout', (fn, delay = 0) => {
    const id = ++nextId
    timers.set(id, { at: now + delay, fn })
    return id
  })
  t.mock.method(globalThis, 'clearTimeout', (id) => timers.delete(id))
  const tick = (ms = 0) => {
    const until = now + ms
    for (;;) {
      const next = [...timers].filter(([, timer]) => timer.at <= until).sort((a, b) => a[1].at - b[1].at)[0]
      if (!next) break
      const [id, timer] = next
      timers.delete(id)
      now = timer.at
      timer.fn()
    }
    now = until
  }
  const fetch = t.mock.method(globalThis, 'fetch', () => { throw new Error('Drawing must never fetch') })
  const map = new MapHost()
  const enabledZoom = new api.DoubleClickZoom()
  const disabledZoom = new api.DoubleClickZoom()
  disabledZoom.setActive(false)
  map.addInteraction(enabledZoom)
  map.addInteraction(disabledZoom)
  const states = []
  const off = api.onMeasureState((state) => states.push(state))
  const controller = api.createDrawingTools(map)
  t.after(() => { controller.destroy(); off() })
  return { map, controller, states, tick, timers, fetch, enabledZoom, disabledZoom }
}

const a = api.fromWgs84([144.96, -37.81])
const b = api.fromWgs84([144.98, -37.8])
const c = api.fromWgs84([144.97, -37.78])
function close(actual, expected, tolerance = 1e-7) {
  assert.equal(actual.length, expected.length)
  actual.forEach((value, i) => assert.ok(Math.abs(value - expected[i]) < tolerance, `${value} != ${expected[i]}`))
}

test('two fixed clicks measure locally; preview, endpoint dots, labels and zoom cooldown', (t) => {
  const { map, controller, states, tick, fetch, enabledZoom, disabledZoom } = setup(t)
  assert.equal(states.at(-1).status, 'idle')
  api.emitMeasureStart()
  assert.equal(controller.isActive(), true)
  assert.equal(enabledZoom.getActive(), false)
  assert.equal(disabledZoom.getActive(), false)
  assert.equal(map.viewport.style.cursor, 'crosshair')
  const draw = map.draw
  assert.equal(draw.getOverlay().getZIndex(), 5000)
  assert.equal(map.click(a).defaultPrevented, true, 'stopClick suppresses selection clicks')
  assert.equal(states.at(-1).status, 'drawing')
  close(states.at(-1).points[0], [144.96, -37.81])
  const count = states.length
  map.fire('pointermove', c)
  assert.equal(states.length, count, 'preview does not calculate or emit new results')
  const preview = draw.getOverlay().getSource().getFeatures().find((feature) => feature.getGeometry().getType() === 'LineString')
  const styles = draw.getOverlay().getStyleFunction()(preview, 1)
  assert.equal(styles[0].getStroke().getColor(), '#7b1fa2')
  assert.equal(styles[1].getGeometryFunction()(preview).getCoordinates().length, 2)
  map.click(b)
  assert.equal(map.draw, draw, 'removal is deferred until OL finishes pointerup')
  assert.equal(map.source(5000).getFeatures().length, 0)
  tick()
  assert.equal(map.draw, undefined)
  assert.equal(map.source(5000).getFeatures().length, 1)
  assert.equal(states.at(-1).status, 'complete')
  close(states.at(-1).points[1], [144.98, -37.8])
  assert.deepEqual(states.at(-1).result, api.measureDistance(a, b))
  assert.equal(states.at(-1).result.measurementCrs, 'EPSG:7855')
  assert.equal(fetch.mock.callCount(), 0)
  assert.equal(controller.isActive(), true, 'final click cannot select results')
  assert.equal(map.fire('dblclick', b).defaultPrevented, true)
  tick(299)
  assert.equal(enabledZoom.getActive(), false)
  tick(1)
  assert.equal(controller.isActive(), false)
  assert.equal(enabledZoom.getActive(), true)
  assert.equal(disabledZoom.getActive(), false)
  assert.equal(map.viewport.style.cursor, 'grab')
  api.emitMeasureRetry()
  assert.equal(states.at(-1).status, 'complete')
  assert.equal(fetch.mock.callCount(), 0)
  api.emitMeasureClear()
  assert.equal(states.at(-1).status, 'idle')
  assert.equal(map.source(5000).getFeatures().length, 0)
})

test('polygon Finish requires three distinct fixed vertices, excluding moving preview', (t) => {
  const { map, tick } = setup(t)
  const completed = []
  t.after(api.onSpatialDrawComplete((event) => completed.push(event.geometry)))
  api.emitSpatialDrawStart({ mode: 'polygon' })
  api.emitSpatialDrawFinish()
  map.click(a)
  api.emitSpatialDrawFinish()
  map.click(b)
  map.fire('pointermove', c)
  api.emitSpatialDrawFinish()
  tick()
  assert.equal(completed.length, 0)
  assert.ok(map.draw)
  map.click(c)
  map.fire('pointermove', [c[0] + 1000, c[1] + 1000])
  api.emitSpatialDrawFinish()
  tick()
  assert.equal(completed.length, 1)
  assert.equal(completed[0].type, 'Polygon')
  assert.equal(completed[0].coordinates[0].length, 4)
  close(completed[0].coordinates[0][0], [144.96, -37.81])
  close(completed[0].coordinates[0][2], [144.97, -37.78])
  assert.equal(map.source(4000).getFeatures().length, 1)
})

test('polygon completes on second click at final vertex without double-click zoom', (t) => {
  const { map, tick, enabledZoom } = setup(t)
  let completed = 0
  t.after(api.onSpatialDrawComplete(() => completed++))
  api.emitSpatialDrawStart({ mode: 'polygon' })
  map.click(a)
  map.click(b)
  map.click(c)
  map.click(c)
  assert.equal(map.fire('dblclick', c).defaultPrevented, true)
  tick()
  assert.equal(completed, 1)
  assert.equal(enabledZoom.getActive(), false)
  tick(300)
  assert.equal(enabledZoom.getActive(), true)
})

test('one-click spatial point and received WGS84 geometry display in native CRS', (t) => {
  const { map, tick } = setup(t)
  let completed
  t.after(api.onSpatialDrawComplete((event) => { completed = event.geometry }))
  api.emitSpatialDrawStart({ mode: 'point' })
  map.click(a)
  tick()
  assert.equal(completed.type, 'Point')
  close(completed.coordinates, [144.96, -37.81])
  api.emitSpatialDrawGeometry({ geometry: { type: 'Point', coordinates: [144.98, -37.8] } })
  close(map.source(4000).getFeatures()[0].getGeometry().getCoordinates(), b)
  api.emitSpatialDrawGeometry({ geometry: { type: 'Polygon', coordinates: [[[144.96, -37.81], [144.98, -37.8], [144.97, -37.78], [144.96, -37.81]]] } })
  close(map.source(4000).getFeatures()[0].getGeometry().getCoordinates()[0][2], c)
  api.emitSpatialDrawClear()
  assert.equal(map.source(4000).getFeatures().length, 0)
})

test('exclusive modes, feature clear, Escape clear notification and late query response', (t) => {
  const { map, controller, states, tick } = setup(t)
  let spatialClears = 0, featureClears = 0
  t.after(api.onSpatialDrawClear(() => spatialClears++))
  t.after(api.onFeatureClear(() => featureClears++))
  api.emitSpatialDrawStart({ mode: 'polygon' })
  map.click(a)
  assert.equal(map.keyboard.escape().defaultPrevented, true)
  assert.equal(spatialClears, 1, 'Escape notifies copied panel clear subscribers')
  assert.equal(controller.isActive(), false)
  api.emitMeasureStart()
  assert.equal(spatialClears, 2)
  assert.equal(featureClears, 1)
  map.click(a)
  api.emitSpatialDrawGeometry({ geometry: { type: 'Point', coordinates: [144.98, -37.8] } })
  assert.ok(map.draw)
  assert.equal(states.at(-1).status, 'drawing')
  assert.equal(map.source(4000).getFeatures().length, 0)
  map.click(b)
  tick()
  api.emitSpatialDrawStart({ mode: 'point' })
  assert.equal(states.at(-1).status, 'idle')
  assert.equal(map.source(5000).getFeatures().length, 0)
  api.emitMeasureStart()
  assert.equal(map.interactions.getArray().filter((i) => i instanceof api.Draw).length, 1)
  map.keyboard.escape()
  assert.equal(states.at(-1).status, 'idle')
  assert.equal(controller.isActive(), false)
})

test('clear or mode switch before deferred completion cannot insert stale features', (t) => {
  const { map, tick, states } = setup(t)
  let completed = 0
  t.after(api.onSpatialDrawComplete(() => completed++))
  api.emitSpatialDrawStart({ mode: 'point' })
  map.click(a)
  api.emitSpatialDrawClear()
  tick()
  assert.equal(completed, 0)
  assert.equal(map.source(4000).getFeatures().length, 0)
  api.emitMeasureStart()
  map.click(a)
  map.click(b)
  api.emitSpatialDrawStart({ mode: 'polygon' })
  tick()
  assert.equal(map.source(5000).getFeatures().length, 0)
  assert.equal(states.at(-1).status, 'idle')
  assert.ok(map.draw)
})

test('reentrant clear from completion subscriber does not resurrect a feature', (t) => {
  const { map, tick } = setup(t)
  t.after(api.onSpatialDrawComplete(() => api.emitSpatialDrawClear()))
  api.emitSpatialDrawStart({ mode: 'point' })
  map.click(a)
  tick()
  assert.equal(map.source(4000).getFeatures().length, 0)
  t.after(api.onMeasureState((state) => { if (state.status === 'complete') api.emitMeasureClear() }))
  api.emitMeasureStart()
  map.click(a)
  map.click(b)
  tick()
  assert.equal(map.source(5000).getFeatures().length, 0)
})

test('invalid final endpoints emit error; retry is local and clear resets state', (t) => {
  const { map, tick, states, fetch } = setup(t)
  api.emitMeasureStart()
  // Inject invalid geometry at OL's public drawend event to exercise validation.
  map.draw.once('drawend', ({ feature }) => feature.getGeometry().setCoordinates([a, [NaN, 2500000]]))
  map.click(a)
  map.click(b)
  tick()
  assert.equal(states.at(-1).status, 'error')
  assert.match(states.at(-1).error, /valid map positions/)
  api.emitMeasureRetry()
  assert.equal(states.at(-1).status, 'error')
  assert.equal(fetch.mock.callCount(), 0)
  api.emitMeasureClear()
  assert.equal(states.at(-1).status, 'idle')
  assert.deepEqual(states.at(-1).points, [])
})

test('destroy during deferred completion cleans bus, DOM, OL keys, layers and timers', (t) => {
  const { map, controller, tick, states, timers, enabledZoom, disabledZoom } = setup(t)
  api.emitMeasureStart()
  const extraZoom = new api.DoubleClickZoom()
  map.addInteraction(extraZoom)
  assert.equal(extraZoom.getActive(), false)
  const draw = map.draw
  map.click(a)
  map.click(b)
  controller.destroy()
  controller.destroy()
  assert.equal(states.at(-1).status, 'unavailable')
  assert.equal(controller.isActive(), false)
  assert.equal(map.layers.length, 0)
  assert.equal(map.draw, undefined)
  assert.equal(map.hasListener(), false)
  assert.equal(map.interactions.hasListener(), false)
  assert.equal(draw.hasListener(), false)
  assert.equal(map.keyboard.listeners.size, 0)
  // OL Layer queues its own uncancellable zero-delay sourceready notifications.
  // No controller completion/cooldown or Draw pointer timer may survive teardown.
  for (const { fn } of timers.values()) assert.match(String(fn), /dispatchEvent\(["']sourceready["']\)/)
  tick()
  assert.equal(timers.size, 0)
  assert.equal(enabledZoom.getActive(), true)
  assert.equal(disabledZoom.getActive(), false)
  assert.equal(extraZoom.getActive(), true)
  assert.equal(map.viewport.style.cursor, 'grab')
  const count = states.length
  api.emitMeasureStart()
  api.emitMeasureRetry()
  api.emitMeasureClear()
  api.emitSpatialDrawStart({ mode: 'polygon' })
  api.emitSpatialDrawFinish()
  api.emitSpatialDrawClear()
  api.emitSpatialDrawGeometry({ geometry: { type: 'Point', coordinates: [144.96, -37.81] } })
  tick(1000)
  assert.equal(states.length, count)
  assert.equal(map.layers.length, 0)
  assert.equal(map.draw, undefined)
})