import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// 官网前端在根路径 /；后端 API 公共前缀 /lobster/site（Nginx rewrite 掉后转 8891）。
// 本地直连预览时由下面的 proxy 把 /lobster/site 转给后端，生产由网关 Nginx 负责。
const apiProxy = {
  '/lobster/site': {
    target: 'http://127.0.0.1:8891',
    changeOrigin: true,
    rewrite: (path: string) => path.replace(/^\/lobster\/site/, ''),
  },
}

export default defineConfig({
  base: '/',
  plugins: [vue()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  server: {
    proxy: apiProxy,
  },
  preview: {
    port: 7891,
    host: '0.0.0.0',
    allowedHosts: true,
    proxy: apiProxy,
  },
})
