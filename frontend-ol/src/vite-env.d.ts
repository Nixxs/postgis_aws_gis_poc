/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_QUERY_API_URL: string
  readonly VITE_TILE_API_URL: string
  readonly VITE_CONFIG_URL: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}