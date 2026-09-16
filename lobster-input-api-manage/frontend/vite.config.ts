import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { resolve } from 'path'

export default defineConfig({
  plugins: [vue()],
  base: process.env.VITE_BASE_URL || '/lobster/api-pool/',
  resolve: {
    alias: { '@': resolve(__dirname, 'src') },
  },
  server: {
    port: 5174,
    proxy: {
      '/lobster/api-pool/api': {
        target: 'http://127.0.0.1:8889',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/lobster\/api-pool/, ''),
      },
    },
  },
  preview: {
    port: 7889,
    host: '0.0.0.0',
    allowedHosts: true,
    proxy: {
      '/lobster/api-pool/api': {
        target: 'http://127.0.0.1:8889',
        changeOrigin: true,
        rewrite: (path) => path.replace(/^\/lobster\/api-pool/, ''),
      },
    },
  },
})
