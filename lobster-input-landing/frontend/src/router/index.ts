import { createRouter, createWebHistory, type RouteLocationNormalized } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

const router = createRouter({
  history: createWebHistory('/'),
  scrollBehavior(to, _from, savedPosition) {
    if (to.hash) return { el: to.hash, behavior: 'smooth', top: 80 }
    if (savedPosition) return savedPosition
    return { top: 0 }
  },
  routes: [
    { path: '/', name: 'home', component: () => import('@/views/HomeView.vue') },
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue') },
    { path: '/account', name: 'account', component: () => import('@/views/AccountView.vue'), meta: { requiresAuth: true } },
    { path: '/privacy', name: 'privacy', component: () => import('@/views/LegalView.vue') },
    { path: '/terms', name: 'terms', component: () => import('@/views/LegalView.vue') },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

router.beforeEach(async (to: RouteLocationNormalized) => {
  if (to.meta.requiresAuth) {
    const { email, ready, refresh } = useAuthStore()
    if (!ready.value) await refresh()
    if (!email.value) return { path: '/login', query: { redirect: to.fullPath } }
  }
  return true
})

export default router
