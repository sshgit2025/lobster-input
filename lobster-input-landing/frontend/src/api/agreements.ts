import { apiGet } from './http'

export interface Agreement {
  type: string
  lang: string
  content: string
  updated_at?: string | null
}

export const fetchAgreement = (type: 'privacy' | 'terms', lang: string) =>
  apiGet<Agreement>(`/v1/agreements?type=${encodeURIComponent(type)}&lang=${encodeURIComponent(lang)}`)
