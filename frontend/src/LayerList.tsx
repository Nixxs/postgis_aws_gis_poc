import { useState, useEffect } from 'react'
import { List, ListItem, ListItemText, ListItemIcon, Switch, Typography, Box, Tooltip } from '@mui/material'
import { useConfig, isLayerInZoomRange } from './config'
import { useAuth } from './auth'
import { emitLayerToggle, onMapZoom } from './events'

export default function LayerList() {
  const { config, error } = useConfig()
  const { user } = useAuth()
  const [visible, setVisible] = useState<Record<string, boolean>>({})
  const [zoom, setZoom] = useState(0)

  useEffect(() => onMapZoom((e) => setZoom(e.zoom)), [])
  useEffect(() => {
    if (!config) return
    setVisible(Object.fromEntries([...(config.basemaps ?? []), ...config.layers].map((l) => [l.id, l.visibleByDefault])))
  }, [config])

  const toggle = (id: string) => setVisible((prev) => {
    const next = !prev[id]
    emitLayerToggle({ id, visible: next })
    return { ...prev, [id]: next }
  })

  if (error) return <Typography color="error" sx={{ p: 2 }}>{error}</Typography>
  if (!config) return <Typography sx={{ p: 2 }}>Loading layers…</Typography>
  const visibleBasemaps = (config.basemaps ?? []).filter((b) => !b.requiresAuth || user)
  const zoomHint = (item: { minZoom?: number; maxZoom?: number }) => {
    if (item.minZoom != null && zoom < item.minZoom) return `Zoom in to level ${item.minZoom} to view this layer (currently ${zoom.toFixed(1)})`
    if (item.maxZoom != null && zoom >= item.maxZoom) return `Zoom out below level ${item.maxZoom} to view this layer (currently ${zoom.toFixed(1)})`
    return ''
  }
  const renderItems = (items: Array<{ id: string; label: string; color?: string; minZoom?: number; maxZoom?: number }>) => <List dense>
    {items.map((item) => {
      const inRange = isLayerInZoomRange(item, zoom)
      const row = <ListItem key={item.id} disablePadding sx={{ px: 1, opacity: inRange ? 1 : 0.4 }}>
        <ListItemIcon sx={{ minWidth: 0 }}><Switch edge="start" size="small" checked={visible[item.id] ?? false} onChange={() => toggle(item.id)} /></ListItemIcon>
        {item.color && <Box sx={{ width: 14, height: 14, mr: 1, borderRadius: '2px', bgcolor: item.color, flexShrink: 0 }} />}
        <ListItemText primary={item.label} />
      </ListItem>
      return inRange ? row : <Tooltip key={item.id} title={zoomHint(item)} placement="right" arrow>{row}</Tooltip>
    })}
  </List>

  return <>
    <Typography variant="overline" sx={{ px: 2, color: 'text.secondary' }}>Layers</Typography>
    {renderItems(config.layers.filter((l) => !l.requiresAuth || user))}
    {visibleBasemaps.length > 0 && <><Typography variant="overline" sx={{ px: 2, color: 'text.secondary' }}>Basemaps</Typography>{renderItems(visibleBasemaps)}</>}
  </>
}
