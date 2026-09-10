import { useEffect, useState } from 'react'
import {
  Alert, Box, Button, CircularProgress, Collapse, Stack, Table, TableBody,
  TableCell, TableContainer, TableHead, TableRow, Typography,
} from '@mui/material'
import SquareFootIcon from '@mui/icons-material/SquareFoot'
import ExpandMoreIcon from '@mui/icons-material/ExpandMore'
import ExpandLessIcon from '@mui/icons-material/ExpandLess'
import {
  emitPolygonMeasureClear, emitPolygonMeasureRetry, emitPolygonMeasureStart,
  emitPolygonSegmentHover, onPolygonMeasureState, type PolygonMeasureState,
} from './events'

const metres = (value: number) => value.toLocaleString(undefined, { maximumFractionDigits: 2 })
const area = (value: number) => value.toLocaleString(undefined, { maximumFractionDigits: 2 })

export default function PolygonMeasurePanel() {
  const [open, setOpen] = useState(false)
  const [state, setState] = useState<PolygonMeasureState>({ status: 'unavailable' })
  useEffect(() => onPolygonMeasureState(setState), [])
  const selecting = state.status === 'selecting'
  const loading = state.status === 'loading'
  const result = state.result

  return <Box sx={{ whiteSpace: 'normal' }}>
    <Button fullWidth color="inherit" aria-expanded={open} aria-controls="polygon-measure-panel"
      onClick={() => setOpen(!open)} startIcon={<SquareFootIcon />}
      endIcon={open ? <ExpandLessIcon /> : <ExpandMoreIcon />}
      sx={{ justifyContent: 'space-between', px: 0, color: 'text.secondary' }}>
      Measure polygon
    </Button>
    <Collapse in={open} id="polygon-measure-panel">
      <Stack spacing={1.5} sx={{ mt: 1 }}>
        <Typography variant="body2">Select a visible polygon. Its complete database geometry is measured locally in your browser.</Typography>
        <Stack direction="row" spacing={1}>
          <Button variant="contained" size="small" onClick={emitPolygonMeasureStart} disabled={state.status === 'unavailable' || loading}>
            {selecting ? 'Select another' : 'Select feature'}
          </Button>
          <Button variant="outlined" size="small" onClick={emitPolygonMeasureClear} disabled={state.status === 'unavailable' || state.status === 'idle'}>
            {selecting || loading ? 'Cancel' : 'Clear'}
          </Button>
        </Stack>
        <Box role="status" aria-live="polite">
          {state.status === 'unavailable' && <Typography variant="caption">Waiting for the map…</Typography>}
          {selecting && <Typography variant="body2">Click a visible polygon. Press Escape to cancel.</Typography>}
          {loading && <Stack direction="row" spacing={1} sx={{ alignItems: 'center' }}><CircularProgress size={16} /><Typography variant="body2">Loading complete feature geometry…</Typography></Stack>}
          {result && <Alert severity="success">Measurement complete</Alert>}
        </Box>
        {state.error && <Alert severity="error" action={state.objectId ? <Button color="inherit" size="small" onClick={emitPolygonMeasureRetry}>Retry</Button> : undefined}>{state.error}</Alert>}
        {state.layer && <Typography variant="caption">Layer: {state.layer}</Typography>}
        {state.objectId && <Typography variant="caption">OBJECTID: {state.objectId}</Typography>}
        {result && <TableContainer sx={{ border: 1, borderColor: 'divider' }}>
          <Table size="small" aria-label="Polygon area and perimeter">
            <TableBody>
              <TableRow><TableCell>Area</TableCell><TableCell align="right">{area(result.area)} m²</TableCell></TableRow>
              <TableRow><TableCell>Area (hectares)</TableCell><TableCell align="right">{(result.area / 10_000).toLocaleString(undefined, { maximumFractionDigits: 4 })} ha</TableCell></TableRow>
              <TableRow><TableCell>Perimeter</TableCell><TableCell align="right">{metres(result.perimeter)} m</TableCell></TableRow>
            </TableBody>
          </Table>
        </TableContainer>}
        {result && <TableContainer onMouseLeave={() => emitPolygonSegmentHover(null)} sx={{ maxHeight: 300, border: 1, borderColor: 'divider' }}>
          <Table size="small" stickyHeader aria-label="Polygon segment measurements">
            <TableHead><TableRow>
              <TableCell>Part</TableCell>
              <TableCell>Ring</TableCell>
              <TableCell>Segment</TableCell>
              <TableCell align="right">Length (m)</TableCell>
            </TableRow></TableHead>
            <TableBody>{result.segments.map((segment) => <TableRow
              key={`${segment.polygonIndex}-${segment.ringIndex}-${segment.segmentIndex}`}
              hover tabIndex={0}
              onMouseEnter={() => emitPolygonSegmentHover(segment)}
              onFocus={() => emitPolygonSegmentHover(segment)}
              onBlur={() => emitPolygonSegmentHover(null)}
              sx={{ cursor: 'pointer' }}
            >
              <TableCell>{segment.polygonIndex}</TableCell>
              <TableCell>{segment.ringIndex}</TableCell>
              <TableCell>{segment.segmentIndex}</TableCell>
              <TableCell align="right">{metres(segment.length)}</TableCell>
            </TableRow>)}</TableBody>
          </Table>
        </TableContainer>}
        <Typography variant="caption" color="text.secondary">Calculated client-side in GDA2020 / MGA zone 55 (EPSG:7855). Hover or focus a segment row to highlight its edge. Part identifies each polygon; ring 0 is its exterior boundary and later rings are holes.</Typography>
      </Stack>
    </Collapse>
  </Box>
}
