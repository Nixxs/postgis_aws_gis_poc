import { useEffect, useState } from 'react'
import { Alert, Box, Button, CircularProgress, Collapse, Stack, Typography } from '@mui/material'
import StraightenIcon from '@mui/icons-material/Straighten'
import ExpandMoreIcon from '@mui/icons-material/ExpandMore'
import ExpandLessIcon from '@mui/icons-material/ExpandLess'
import { emitMeasureClear, emitMeasureRetry, emitMeasureStart, onMeasureState, type MeasureState } from './events'

export default function MeasurePanel() {
  const [open, setOpen] = useState(false)
  const [state, setState] = useState<MeasureState>({ status: 'unavailable', points: [] })
  useEffect(() => onMeasureState(setState), [])
  const drawing = state.status === 'drawing'
  const loading = state.status === 'loading'
  const result = state.result

  return <Box sx={{ whiteSpace: 'normal' }}>
    <Button fullWidth color="inherit" aria-expanded={open} aria-controls="measure-panel"
      onClick={() => setOpen(!open)} startIcon={<StraightenIcon />}
      endIcon={open ? <ExpandLessIcon /> : <ExpandMoreIcon />}
      sx={{ justifyContent: 'space-between', px: 0, color: 'text.secondary' }}>
      Measure distance
    </Button>
    <Collapse in={open} id="measure-panel">
      <Stack spacing={1.5} sx={{ mt: 1 }}>
        <Typography variant="body2">Select two points to measure their straight-line MGA zone 55 grid distance client-side in your browser, without a measurement API request.</Typography>
        <Stack direction="row" spacing={1}>
          <Button variant="contained" size="small" onClick={emitMeasureStart} disabled={state.status === 'unavailable'}>
            {state.points.length || drawing ? 'Start again' : 'Select two points'}
          </Button>
          <Button variant="outlined" size="small" onClick={emitMeasureClear} disabled={state.status === 'unavailable' || state.status === 'idle'}>
            {drawing || loading ? 'Cancel' : 'Clear'}
          </Button>
        </Stack>
        <Box role="status" aria-live="polite">
          {state.status === 'unavailable' && <Typography variant="caption">Waiting for the map…</Typography>}
          {drawing && <Typography variant="body2">{state.points.length ? 'Click the end point. Press Escape to cancel.' : 'Click the start point. Press Escape to cancel.'}</Typography>}
          {loading && <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}><CircularProgress size={16} /><Typography variant="body2">Calculating distance…</Typography></Stack>}
          {result && <Alert severity="success">
            <Typography variant="h6">{result.distance.toLocaleString(undefined, { maximumFractionDigits: 2 })} m</Typography>
            {result.distance >= 1000 && <Typography variant="body2">{(result.distance / 1000).toLocaleString(undefined, { maximumFractionDigits: 3 })} km</Typography>}
          </Alert>}
        </Box>
        {state.error && <Alert severity="error" action={<Button color="inherit" size="small" onClick={emitMeasureRetry}>Retry</Button>}>{state.error}</Alert>}
        {state.points.map((point, index) => <Typography key={index} variant="caption">
          {index === 0 ? 'Start' : 'End'} (lon, lat): {point[0].toFixed(6)}, {point[1].toFixed(6)}
        </Typography>)}
        <Typography variant="caption" color="text.secondary">GDA2020 / MGA zone 55 (EPSG:7855). Intended for central/eastern Victoria; not a road or terrain distance.</Typography>
      </Stack>
    </Collapse>
  </Box>
}