import { apiGet } from './http'

export interface StartupConfig {
  registration_enabled: boolean
  invite_code_enabled: boolean
  show_invite_codes_enabled: boolean
  show_subscription_module_enabled: boolean
  registration_limit_enabled: boolean
  registration_limit_count: number
}

export const fetchStartupConfig = () => apiGet<StartupConfig>('/v1/config/startup')
