import { apiGet, apiPost } from './http'

export interface AuthResult {
  authenticated: boolean
  email: string
  tier: string
  is_new_user: boolean
  require_invite: boolean
}

export interface VerifyPayload {
  email: string
  code: string
  device_id: string
  hardware_fingerprint?: string
}

export interface VerifyInvitePayload {
  email: string
  invite_code: string
  device_id: string
  hardware_fingerprint?: string
}

export const sendCode = (email: string) => apiPost('/v1/auth/send-code', { email })
export const verifyCode = (payload: VerifyPayload) => apiPost<AuthResult>('/v1/auth/verify', payload)
export const verifyInvite = (payload: VerifyInvitePayload) => apiPost<AuthResult>('/v1/auth/verify-invite', payload)
export const fetchMe = () => apiGet<{ email: string }>('/v1/auth/me')
export const logout = () => apiPost('/v1/auth/logout')
