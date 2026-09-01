import { useEffect, useMemo, useState } from 'react'
import { Box, Paper, Typography, IconButton, Table, TableBody, TableCell, TableContainer, TableRow, Tooltip } from '@mui/material'
import CloseIcon from '@mui/icons-material/Close'
import { onFeatureSelect, emitFeatureClear } from './events'
import { useConfig } from './config'

function formatValue(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

export default function FeatureInfoPanel() {
  const { config } = useConfig()
  const [layer, setLayer] = useState('')
  const [properties, setProperties] = useState<Record<string, unknown> | null>(null)

  useEffect(() => onFeatureSelect((e) => { setLayer(e.layer); setProperties(e.properties) }), [])
  const title = useMemo(() => config?.layers.find((l) => l.id === layer)?.label ?? layer, [config, layer])
  const rows = useMemo(() => properties ? Object.entries(properties) : [], [properties])
  const close = () => { setProperties(null); emitFeatureClear() }

  if (!properties) return null
  return <Paper elevation={6} sx={{ position: 'absolute', top: 10, right: 52, width: 400, maxHeight: 'calc(100% - 100px)', display: 'flex', flexDirection: 'column', overflow: 'hidden', zIndex: 5 }}>
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, px: 1.5, py: 0.5, borderBottom: 1, borderColor: 'divider', bgcolor: 'grey.100' }}>
      <Typography variant="subtitle2" sx={{ flexGrow: 1 }} noWrap title={title}>{title}</Typography>
      <Tooltip title="Close"><IconButton size="small" onClick={close}><CloseIcon fontSize="small" /></IconButton></Tooltip>
    </Box>
    <TableContainer sx={{ overflow: 'auto' }}><Table size="small"><TableBody>
      {rows.map(([key, value]) => <TableRow key={key} hover>
        <TableCell sx={{ fontWeight: 600, verticalAlign: 'top', width: '40%', wordBreak: 'break-word' }}>{key}</TableCell>
        <TableCell sx={{ wordBreak: 'break-word' }}>{formatValue(value)}</TableCell>
      </TableRow>)}
    </TableBody></Table></TableContainer>
  </Paper>
}
