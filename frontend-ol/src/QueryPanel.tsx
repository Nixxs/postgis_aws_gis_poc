import { useEffect, useMemo, useState } from 'react'
import { Box, Typography, TextField, MenuItem, Autocomplete, Button, Stack, CircularProgress, Alert, Collapse, IconButton } from '@mui/material'
import ExpandMoreIcon from '@mui/icons-material/ExpandMore'
import ExpandLessIcon from '@mui/icons-material/ExpandLess'
import { useConfig } from './config'
import { useAuth } from './auth'
import { describeLayer, getUniqueValues, queryLayer, type ColumnInfo } from './api'
import { emitQueryResult, emitClearQuery } from './events'

const OPERATORS = ['=', '!=', '>', '<', '>=', '<=', 'LIKE'] as const
type Operator = (typeof OPERATORS)[number]
function isNumeric(type: string): boolean { return /INT|DOUBLE|DECIMAL|FLOAT|REAL|NUMERIC|HUGEINT/i.test(type) }
function buildWhere(col: ColumnInfo, op: Operator, value: string): string {
  if (op === 'LIKE') return `"${col.name}" LIKE '${value.replace(/'/g, "''")}'`
  if (isNumeric(col.type) && value.trim() !== '' && !Number.isNaN(Number(value))) return `"${col.name}" ${op} ${value}`
  return `"${col.name}" ${op} '${value.replace(/'/g, "''")}'`
}

export default function QueryPanel() {
  const { config } = useConfig(); const { user } = useAuth()
  const availableLayers = useMemo(() => config?.layers.filter((l) => !l.requiresAuth || user) ?? [], [config, user])
  const [layer, setLayer] = useState(''); const [open, setOpen] = useState(false); const [columns, setColumns] = useState<ColumnInfo[]>([])
  const [field, setField] = useState(''); const [op, setOp] = useState<Operator>('='); const [value, setValue] = useState('')
  const [suggestions, setSuggestions] = useState<string[]>([]); const [loadingSuggestions, setLoadingSuggestions] = useState(false)
  const [describing, setDescribing] = useState(false); const [running, setRunning] = useState(false); const [error, setError] = useState<string | null>(null); const [resultCount, setResultCount] = useState<number | null>(null)
  const selectedColumn = useMemo(() => columns.find((c) => c.name === field), [columns, field])

  useEffect(() => { if (layer && !availableLayers.some((l) => l.id === layer)) setLayer('') }, [availableLayers, layer])
  useEffect(() => {
    if (!layer) return
    setDescribing(true); setError(null); setColumns([]); setField(''); setValue(''); setSuggestions([])
    describeLayer(layer).then((res) => setColumns(res.columns.filter((c) => !c.is_geometry))).catch((e) => setError(String(e.message ?? e))).finally(() => setDescribing(false))
  }, [layer])
  useEffect(() => {
    if (!layer || !field) return
    const handle = setTimeout(() => { setLoadingSuggestions(true); getUniqueValues(layer, field, value, 50).then((res) => setSuggestions(res.values.map(String))).catch(() => setSuggestions([])).finally(() => setLoadingSuggestions(false)) }, 250)
    return () => clearTimeout(handle)
  }, [layer, field, value])

  const submit = async () => {
    if (!selectedColumn) return
    setRunning(true); setError(null); setResultCount(null)
    try { const geojson = await queryLayer(layer, buildWhere(selectedColumn, op, value)); setResultCount(geojson.features.length); emitQueryResult({ layer, geojson }) }
    catch (e: any) { setError(String(e.message ?? e)) } finally { setRunning(false) }
  }
  const clear = () => { setValue(''); setResultCount(null); setError(null); emitClearQuery() }

  return <Box>
    <Box onClick={() => setOpen((o) => !o)} sx={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer', userSelect: 'none' }}>
      <Typography variant="overline" sx={{ color: 'text.secondary' }}>Query</Typography>
      <IconButton size="small" aria-label={open ? 'Collapse query' : 'Expand query'}>{open ? <ExpandLessIcon fontSize="small" /> : <ExpandMoreIcon fontSize="small" />}</IconButton>
    </Box>
    <Collapse in={open}><Stack spacing={1.5} sx={{ mt: 1 }}>
      <TextField select size="small" label="Layer" value={layer} onChange={(e) => setLayer(e.target.value)}>{availableLayers.length ? availableLayers.map((l) => <MenuItem key={l.id} value={l.id}>{l.label}</MenuItem>) : <MenuItem disabled value="">Loading layers…</MenuItem>}</TextField>
      <TextField select size="small" label="Column" value={field} onChange={(e) => { setField(e.target.value); setValue(''); setSuggestions([]) }} disabled={!layer || describing} helperText={describing ? 'Loading columns…' : ' '}>
        {columns.length ? columns.map((c) => <MenuItem key={c.name} value={c.name}>{c.name}</MenuItem>) : <MenuItem disabled value="">Pick a layer first</MenuItem>}
      </TextField>
      <TextField select size="small" label="Operator" value={op} onChange={(e) => setOp(e.target.value as Operator)} disabled={!field}>{OPERATORS.map((o) => <MenuItem key={o} value={o}>{o}</MenuItem>)}</TextField>
      <Autocomplete freeSolo size="small" options={suggestions} inputValue={value} onInputChange={(_, v) => setValue(v)} disabled={!field} loading={loadingSuggestions} renderInput={(params) => <TextField {...params} label="Value" slotProps={{ ...params.slotProps, input: { ...params.slotProps.input, endAdornment: <>{loadingSuggestions ? <CircularProgress size={16} color="inherit" /> : null}{params.slotProps.input.endAdornment}</> } }} />} />
      <Stack direction="row" spacing={1}><Button variant="contained" size="small" onClick={submit} disabled={!layer || !field || !value.trim() || running} startIcon={running ? <CircularProgress size={16} color="inherit" /> : undefined}>Run query</Button><Button variant="outlined" size="small" onClick={clear}>Clear</Button></Stack>
      {error && <Alert severity="error">{error}</Alert>}
      {resultCount !== null && !error && <Alert severity={resultCount ? 'success' : 'info'}>{resultCount} feature{resultCount === 1 ? '' : 's'} found</Alert>}
    </Stack></Collapse>
  </Box>
}