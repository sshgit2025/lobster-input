import { apiGet } from './http'

export interface CreditItem {
  id: string
  type: string
  source: string
  label: string
  credits_total: number
  credits_used: number
  credits_remaining: number
  expires_at: string | null
}

export interface PlanInfo {
  tier: string
  credits_total: number
  credits_used: number
  credits_remaining: number
  credits_reset_at: string | null
  bonus_credits_remaining: number
  paid_topup_credits_remaining: number
  credit_items: CreditItem[]
  plan_expires_at: string | null
  subscription_expires_at: string | null
  subscription_billing_cycle: string | null
  subscription_auto_renew: boolean
  show_subscription_module_enabled: boolean
  show_invite_codes_enabled: boolean
}

export interface Order {
  payment_order_id?: string
  plan_code?: string
  from_plan_code?: string
  billing_cycle?: string
  price_cents?: number
  paid_amount_cents?: number
  refunded_cents?: number
  currency?: string
  status?: string
  refund_status?: string
  charge_type?: string
  provider?: string
  payment_channel?: string
  entitlement_started_at?: string | null
  entitlement_expires_at?: string | null
  created_at?: string | null
}

export interface InviteCode {
  code: string
  is_used: boolean
  used_by: string | null
  used_at: string | null
}

export const fetchPlan = () => apiGet<PlanInfo>('/v1/account/plan')
export const fetchOrders = () => apiGet<{ orders: Order[] }>('/v1/account/orders')
export const fetchInviteCodes = () => apiGet<{ show: boolean; invite_codes: InviteCode[] }>('/v1/account/invite-codes')
