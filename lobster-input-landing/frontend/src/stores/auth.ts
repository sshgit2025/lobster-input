/** 全局登录态（模块级单例 ref，跨组件共享）。基于官网 HttpOnly Cookie，
 *  通过 /auth/me 判断是否已登录。 */
import { ref, computed } from 'vue'
import * as authApi from '@/api/auth'

const email = ref<string | null>(null)
const ready = ref(false)

const isAuthenticated = computed(() => !!email.value)

async function refresh(): Promise<void> {
  try {
    const me = await authApi.fetchMe()
    email.value = me.email
  } catch {
    email.value = null
  } finally {
    ready.value = true
  }
}

function setEmail(value: string | null): void {
  email.value = value
}

async function logout(): Promise<void> {
  try {
    await authApi.logout()
  } catch {
    /* ignore */
  }
  email.value = null
}

export function useAuthStore() {
  return { email, ready, isAuthenticated, refresh, setEmail, logout }
}
