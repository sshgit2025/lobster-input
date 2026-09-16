import { BASE_URL } from '@/constants'

export async function api<T = unknown>(
  path: string,
  method = 'GET',
  body?: unknown,
): Promise<T> {
  const opts: RequestInit = {
    method,
    credentials: 'include',
    headers: {},
  }
  if (body !== undefined) {
    opts.headers = { 'Content-Type': 'application/json' }
    opts.body = JSON.stringify(body)
  }
  const res = await fetch(`${BASE_URL}${path}`, opts)
  const isLoginRequest = path.startsWith('/api/v1/auth/login')
  if (res.status === 401 && !isLoginRequest) {
    window.location.href = `${BASE_URL}/login`
    throw new Error('未登录')
  }
  if (!res.ok) {
    const data = await res.json().catch(() => ({}))
    const detail = (data as { detail?: string }).detail
    throw new Error(detail || `请求失败 (${res.status})`)
  }
  return res.json()
}

export async function logout() {
  await fetch(`${BASE_URL}/api/v1/auth/logout`, {
    method: 'POST',
    credentials: 'include',
  })
  window.location.href = `${BASE_URL}/login`
}

export async function checkAuth(): Promise<boolean> {
  try {
    const res = await fetch(`${BASE_URL}/api/v1/stats/dashboard`, { credentials: 'include' })
    if (!res.ok) return false
    const data = await res.json()
    return data !== null && typeof data === 'object' && 'total_keys' in data
  } catch {
    return false
  }
}
