import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import { initI18n } from './i18n'
import { useAuthStore } from './stores/auth'

import './styles/tokens.css'
import './styles/base.css'
import './styles/header.css'
import './styles/home.css'
import './styles/legal.css'
import './styles/auth.css'

// 启动时确定语言（URL ?lang / 本地手动选择 / IP 地理推断）
// 注：Element Plus（ElMessage）只在登录/个人中心页按需引入，首页保持轻量，
// 不把组件库打进营销首屏，保护性能与 SEO。
initI18n()

const app = createApp(App)
app.use(router)
app.mount('#app')

// 非阻塞地确认登录态（基于官网 HttpOnly Cookie）
useAuthStore().refresh()
