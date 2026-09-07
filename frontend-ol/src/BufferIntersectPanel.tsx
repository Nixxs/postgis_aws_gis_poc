import { useEffect, useMemo, useState } from 'react'
import { Box, Typography, TextField, MenuItem, Button, Stack, CircularProgress, Alert, Collapse, IconButton } from '@mui/material'
import ExpandMoreIcon from '@mui/icons-material/ExpandMore'
import ExpandLessIcon from '@mui/icons-material/ExpandLess'
import { useConfig, isLayerInZoomRange } from './config'
import { useAuth } from './auth'
import { spatialQuery } from './api'
import { onMeasureStart, onSpatialDrawClear } from './events'
import { emitSpatialDrawStart, emitSpatialDrawFinish, emitSpatialDrawClear, onSpatialDrawComplete, emitSpatialDrawGeometry, emitQueryResultMulti, emitClearQuery, onLayerToggle, onMapZoom, type DrawGeometry } from './events'

const UNIT_TO_METERS = { meters: 1, kilometers: 1000, feet: 0.3048, miles: 1609.344 } as const
type BufferUnit = keyof typeof UNIT_TO_METERS
const MAX_BUFFER_METERS = 50000

export default function BufferIntersectPanel() {
  const { config } = useConfig(); const { user } = useAuth()
  const [open, setOpen] = useState(false); const [geometry, setGeometry] = useState<DrawGeometry | null>(null); const [drawing, setDrawing] = useState(false)
  const [bufferValue, setBufferValue] = useState('100'); const [bufferUnit, setBufferUnit] = useState<BufferUnit>('meters'); const [running, setRunning] = useState(false)
  const [error, setError] = useState<string | null>(null); const [summary, setSummary] = useState<{ total: number; layers: number } | null>(null); const [failed, setFailed] = useState<string[]>([])
  const [visible, setVisible] = useState<Record<string, boolean>>({}); const [zoom, setZoom] = useState(0)
  useEffect(() => { if (config) setVisible(Object.fromEntries(config.layers.map((l) => [l.id, l.visibleByDefault]))) }, [config])
  useEffect(() => onLayerToggle((e) => setVisible((prev) => ({ ...prev, [e.id]: e.visible }))), [])
  useEffect(() => onMapZoom((e) => setZoom(e.zoom)), [])
  useEffect(() => onSpatialDrawComplete((e) => { setGeometry(e.geometry); setDrawing(false) }), [])
  useEffect(() => onMeasureStart(() => { setGeometry(null); setDrawing(false); setSummary(null) }), [])
  useEffect(() => onSpatialDrawClear(() => { setGeometry(null); setDrawing(false); setSummary(null); setFailed([]) }), [])
  const activeLayers = useMemo(() => (config?.layers ?? []).filter((l) => (!l.requiresAuth || user) && visible[l.id] && isLayerInZoomRange(l, zoom)), [config, user, visible, zoom])
  const bufferMeters = useMemo(() => { const n = Number(bufferValue); return bufferValue.trim() === '' || Number.isNaN(n) || n < 0 ? NaN : n * UNIT_TO_METERS[bufferUnit] }, [bufferValue, bufferUnit])
  const bufferValid = !Number.isNaN(bufferMeters); const bufferTooBig = bufferValid && bufferMeters > MAX_BUFFER_METERS
  const beginDraw = () => { setError(null); setSummary(null); setFailed([]); setGeometry(null); emitSpatialDrawClear(); emitSpatialDrawStart({ mode: 'polygon' }); setDrawing(true) }
  const run = async () => {
    if (!geometry || !bufferValid || !activeLayers.length) return
    setRunning(true); setError(null); setSummary(null); setFailed([])
    try {
      const settled = await Promise.allSettled(activeLayers.map((l) => spatialQuery(l.id, geometry, Math.min(bufferMeters, MAX_BUFFER_METERS))))
      const results: Array<{ layer: string; label: string; geojson: any }> = []; const failures: string[] = []; let total = 0; let queryGeometry: DrawGeometry | undefined
      settled.forEach((s, i) => { const layer = activeLayers[i]; if (s.status === 'fulfilled') { results.push({ layer: layer.id, label: layer.label, geojson: s.value }); total += s.value.features.length; if (!queryGeometry && s.value.queryGeometry) queryGeometry = s.value.queryGeometry as DrawGeometry } else failures.push(layer.label) })
      emitQueryResultMulti({ results }); if (queryGeometry) emitSpatialDrawGeometry({ geometry: queryGeometry }); setSummary({ total, layers: results.filter((r) => r.geojson.features.length).length }); setFailed(failures)
    } catch (e: any) { setError(String(e.message ?? e)) } finally { setRunning(false) }
  }
  const clear = () => { emitClearQuery(); emitSpatialDrawClear(); setGeometry(null); setDrawing(false); setSummary(null); setFailed([]); setError(null) }
  const status = drawing ? 'Click the map to add points, double-click or Finish to close.' : geometry?.type === 'Polygon' ? 'Polygon selected.' : 'Draw a polygon on the map.'

  return <Box>
    <Box onClick={() => setOpen((o) => !o)} sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer', userSelect: 'none' }}><Typography variant="overline" sx={{ color: 'text.secondary' }}>Buffer intersect</Typography><IconButton size="small" aria-label={open ? 'Collapse buffer intersect' : 'Expand buffer intersect'}>{open ? <ExpandLessIcon fontSize="small" /> : <ExpandMoreIcon fontSize="small" />}</IconButton></Box>
    <Collapse in={open}><Stack spacing={1.5} sx={{ mt: 1 }}>
      <Stack direction="row" spacing={1}><TextField size="small" label="Buffer" type="number" value={bufferValue} onChange={(e) => setBufferValue(e.target.value)} error={bufferValue !== '' && !bufferValid} slotProps={{ htmlInput: { min: 0, step: 'any' } }} sx={{ flex: 1 }} /><TextField select size="small" label="Units" value={bufferUnit} onChange={(e) => setBufferUnit(e.target.value as BufferUnit)} sx={{ minWidth: 120 }}><MenuItem value="meters">Metres</MenuItem><MenuItem value="kilometers">Kilometres</MenuItem><MenuItem value="feet">Feet</MenuItem><MenuItem value="miles">Miles</MenuItem></TextField></Stack>
      <Button variant="outlined" size="small" fullWidth onClick={beginDraw} disabled={running}>Draw polygon</Button>
      {drawing && <Stack direction="row" spacing={1}><Button variant="contained" size="small" fullWidth onClick={() => emitSpatialDrawFinish()}>Finish</Button><Button variant="text" size="small" fullWidth onClick={clear}>Cancel</Button></Stack>}
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>{status}</Typography>
      <Stack direction="row" spacing={1}><Button variant="contained" size="small" onClick={run} disabled={!geometry || !bufferValid || running || drawing || !activeLayers.length} startIcon={running ? <CircularProgress size={16} color="inherit" /> : undefined}>Run buffer intersect</Button><Button variant="outlined" size="small" onClick={clear}>Clear</Button></Stack>
      <Typography variant="caption" sx={{ color: 'text.secondary' }}>{activeLayers.length ? `Queries ${activeLayers.length} visible layer${activeLayers.length === 1 ? '' : 's'}: ${activeLayers.map((l) => l.label).join(', ')}.` : 'No visible layers in view — turn a layer on and zoom in to query it.'}</Typography>
      {bufferTooBig && <Alert severity="warning">Buffer capped at {MAX_BUFFER_METERS.toLocaleString()} m.</Alert>}{error && <Alert severity="error">{error}</Alert>}{failed.length > 0 && <Alert severity="warning">Failed: {failed.join(', ')}.</Alert>}{summary && !error && <Alert severity={summary.total ? 'success' : 'info'}>{summary.total} feature{summary.total === 1 ? '' : 's'} across {summary.layers} layer{summary.layers === 1 ? '' : 's'}.</Alert>}
    </Stack></Collapse>
  </Box>
}