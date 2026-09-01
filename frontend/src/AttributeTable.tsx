import { useEffect, useMemo, useState } from 'react'
import { Box, Paper, Typography, IconButton, Table, TableBody, TableCell, TableContainer, TableHead, TableRow, Tooltip, Tabs, Tab } from '@mui/material'
import CloseIcon from '@mui/icons-material/Close'
import UnfoldLessIcon from '@mui/icons-material/UnfoldLess'
import UnfoldMoreIcon from '@mui/icons-material/UnfoldMore'
import { onQueryResult, onQueryResultMulti, onClearQuery, emitResultFeatureSelect } from './events'
import type { FeatureCollection } from './api'

type Feature = FeatureCollection['features'][number]
type ResultSet = { layer: string; label: string; features: Feature[] }
function formatValue(value: unknown): string { if (value == null) return ''; return typeof value === 'object' ? JSON.stringify(value) : String(value) }

export default function AttributeTable() {
  const [results, setResults] = useState<ResultSet[]>([]); const [active, setActive] = useState(0); const [collapsed, setCollapsed] = useState(false); const [selected, setSelected] = useState<number | null>(null)
  useEffect(() => {
    const offResult = onQueryResult((e) => { setResults([{ layer: e.layer, label: e.layer, features: e.geojson.features ?? [] }]); setActive(0); setCollapsed(false); setSelected(null) })
    const offMulti = onQueryResultMulti((e) => { setResults(e.results.map((r) => ({ layer: r.layer, label: r.label ?? r.layer, features: r.geojson.features ?? [] })).filter((r) => r.features.length)); setActive(0); setCollapsed(false); setSelected(null) })
    const offClear = onClearQuery(() => { setResults([]); setActive(0); setSelected(null) })
    return () => { offResult(); offMulti(); offClear() }
  }, [])
  const activeIndex = active < results.length ? active : 0; const current = results[activeIndex]; const features = current?.features ?? []
  const columns = useMemo(() => { const seen = new Set<string>(); for (const f of features) for (const key of Object.keys(f.properties ?? {})) seen.add(key); return [...seen] }, [features])
  if (!results.length) return null
  return <Paper elevation={6} sx={{ position: 'absolute', left: 8, right: 8, bottom: 40, maxHeight: collapsed ? 'auto' : '42%', display: 'flex', flexDirection: 'column', overflow: 'hidden', zIndex: 5 }}>
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, px: 1.5, py: 0.5, borderBottom: collapsed ? 'none' : 1, borderColor: 'divider', bgcolor: 'grey.100' }}>
      <Typography variant="subtitle2" sx={{ flexGrow: 1 }}>Results — {current?.label} ({features.length})</Typography>
      <Tooltip title={collapsed ? 'Expand' : 'Collapse'}><IconButton size="small" onClick={() => setCollapsed((c) => !c)}>{collapsed ? <UnfoldMoreIcon fontSize="small" /> : <UnfoldLessIcon fontSize="small" />}</IconButton></Tooltip>
      <Tooltip title="Close"><IconButton size="small" onClick={() => setResults([])}><CloseIcon fontSize="small" /></IconButton></Tooltip>
    </Box>
    {results.length > 1 && !collapsed && <Tabs value={activeIndex} onChange={(_, v) => { setActive(v); setSelected(null) }} variant="scrollable" scrollButtons="auto" sx={{ minHeight: 36, borderBottom: 1, borderColor: 'divider' }}>{results.map((r) => <Tab key={r.layer} label={`${r.label} (${r.features.length})`} sx={{ minHeight: 36, textTransform: 'none' }} />)}</Tabs>}
    {!collapsed && <TableContainer sx={{ overflow: 'auto' }}><Table size="small" stickyHeader><TableHead><TableRow>{columns.map((col) => <TableCell key={col} sx={{ fontWeight: 600, whiteSpace: 'nowrap' }}>{col}</TableCell>)}</TableRow></TableHead><TableBody>
      {features.map((f, i) => <TableRow key={i} hover selected={selected === i} onClick={() => { setSelected(i); emitResultFeatureSelect({ feature: f }) }} sx={{ cursor: 'pointer' }}>{columns.map((col) => <TableCell key={col} sx={{ whiteSpace: 'nowrap' }}>{formatValue(f.properties?.[col])}</TableCell>)}</TableRow>)}
    </TableBody></Table></TableContainer>}
  </Paper>
}
