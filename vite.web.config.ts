// Interface no navegador, com o simulador de api.ts (sem Electron e sem PowerShell).
import { resolve } from 'node:path'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  root: resolve('src/renderer'),
  resolve: { alias: { '@shared': resolve('src/shared') } },
  plugins: [react()],
  server: { port: 5199, fs: { allow: [resolve('.')] } }
})
