import { createRouter, createWebHistory } from 'vue-router'
import { BASE_URL } from '@/constants'
import { checkAuth } from '@/api'

const router = createRouter({
  history: createWebHistory(BASE_URL + '/'),
  routes: [
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue'), meta: { public: true } },
    {
      path: '/',
      component: () => import('@/layouts/MainLayout.vue'),
      children: [
        { path: '', redirect: '/dashboard' },
        { path: 'dashboard', name: 'dashboard', component: () => import('@/views/DashboardView.vue'), meta: { active: 'dashboard' } },
        { path: 'keys', name: 'keys', component: () => import('@/views/KeysView.vue'), meta: { active: 'keys' } },
        { path: 'usage', name: 'usage', component: () => import('@/views/UsageView.vue'), meta: { active: 'usage' } },
        { path: 'account', name: 'account', component: () => import('@/views/AccountView.vue'), meta: { active: 'account' } },
      ],
    },
  ],
})

router.beforeEach(async (to) => {
  if (to.meta.public) return true
  const ok = await checkAuth()
  if (!ok) return { path: '/login', query: { redirect: to.fullPath } }
  return true
})

export default router
