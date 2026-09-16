import { API_BASE } from '@/constants'

export interface ApiError extends Error {
  code?: string
  status?: number
}

function parseError(data: unknown): { message: string; code?: string } {
  const detail = (data as { detail?: unknown })?.detail
  if (detail && typeof detail === 'object') {
    const d = detail as { message?: string; detail?: string; code?: string }
    return { message: d.message || d.detail || '请求失败', code: d.code }
  }
  if (typeof detail === 'string') return { message: detail }
  const msg = (data as { message?: unknown })?.message
  if (typeof msg === 'string') return { message: msg }
  return { message: '请求失败' }
}

export async function apiFetch<T = unknown>(method: string, path: string, body?: unknown): Promise<T> {
  const opts: RequestInit = {
    method,
    credentials: 'include',
    headers: { 'Content-Type': 'application/json' },
  }
  if (body !== undefined) opts.body = JSON.stringify(body)
  const res = await fetch(API_BASE + path, opts)
  const data = await res.json().catch(() => ({}))
  if (!res.ok) {
    const { message, code } = parseError(data)
    const err = new Error(message) as ApiError
    err.code = code
    err.status = res.status
    throw err
  }
  return data as T
}

export const apiGet = <T = unknown>(path: string) => apiFetch<T>('GET', path)
export const apiPost = <T = unknown>(path: string, body?: unknown) => apiFetch<T>('POST', path, body)
