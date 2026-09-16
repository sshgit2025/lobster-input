import { BASE_URL } from '@/constants'

function parseErrorMessage(data: unknown): string {
  let message: unknown = (data as { detail?: unknown; message?: unknown })?.detail
    ?? (data as { message?: unknown })?.message
    ?? '请求失败'
  if (Array.isArray(message)) {
    return message
      .map((item) => {
        if (typeof item === 'object' && item !== null) {
          const obj = item as { msg?: string; message?: string }
          return obj.msg || obj.message || JSON.stringify(item)
        }
        return String(item)
      })
      .join('\n')
  }
  if (message && typeof message === 'object') {
    const obj = message as { message?: string }
    return obj.message || JSON.stringify(message)
  }
  return String(message)
}

export async function api<T = unknown>(
  method: string,
  url: string,
  body?: unknown,
): Promise<T> {
  const fullUrl = BASE_URL + url
  const opts: RequestInit = {
    method,
    credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
  }
  if (body !== undefined) opts.body = JSON.stringify(body)
  const res = await fetch(fullUrl, opts)
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(parseErrorMessage(data))
  return data as T
}

export async function logout(): Promise<void> {
  await fetch(BASE_URL + '/api/v1/auth/logout', { method: 'POST', credentials: 'include' })
  sessionStorage.removeItem('admin_username')
  window.location.href = BASE_URL + '/login'
}

export async function checkAuth(): Promise<boolean> {
  try {
    await api('GET', '/api/v1/users?page_size=1')
    return true
  } catch {
    return false
  }
}
