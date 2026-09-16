<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { ElMessage } from 'element-plus'
import 'element-plus/theme-chalk/el-message.css'
import { t } from '@/i18n'
import { fetchPlan, fetchOrders, fetchInviteCodes, type PlanInfo, type Order, type InviteCode } from '@/api/account'
import type { ApiError } from '@/api/http'
import { useAuthStore } from '@/stores/auth'

const router = useRouter()
const { email, setEmail } = useAuthStore()

const plan = ref<PlanInfo | null>(null)
const orders = ref<Order[]>([])
const invites = ref<InviteCode[]>([])
const showInvites = ref(false)
const loading = ref(true)

const TIER_KEYS: Record<string, string> = {
  trial: 'ui_tierTrial',
  free: 'ui_tierFree',
  lite: 'ui_tierLite',
  standard: 'ui_tierStandard',
  pro: 'ui_tierPro',
  none: 'ui_tierNone',
}
const CYCLE_KEYS: Record<string, string> = {
  monthly: 'ui_cycleMonthly',
  quarterly: 'ui_cycleQuarterly',
  yearly: 'ui_cycleYearly',
}

function tierLabel(code: string | undefined): string {
  if (!code) return t('ui_tierNone')
  return TIER_KEYS[code] ? t(TIER_KEYS[code]) : code
}
function cycleLabel(code: string | undefined): string {
  if (!code) return '—'
  return CYCLE_KEYS[code] ? t(CYCLE_KEYS[code]) : code
}
function creditTypeLabel(type: string): string {
  if (type === 'plan') return t('ui_planCredits')
  if (type === 'bonus') return t('ui_bonusCredits')
  if (type === 'paid_topup') return t('ui_topupCredits')
  return type
}
function fmtNum(n: number | undefined): string {
  return (n ?? 0).toLocaleString('en-US')
}
function fmtAmount(cents: number | undefined, currency: string | undefined): string {
  const v = ((cents ?? 0) / 100).toFixed(2)
  return currency ? `${v} ${currency.toUpperCase()}` : v
}
function fmtDate(iso: string | null | undefined, withTime = false): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  const date = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
  if (!withTime) return date
  return `${date} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}
function statusLabel(s: string | undefined): string {
  if (s === 'applied') return t('ui_statusApplied')
  if (s === 'processing') return t('ui_statusProcessing')
  return t('ui_statusOther')
}
function isRefunded(o: Order): boolean {
  return !!o.refund_status || (o.refunded_cents ?? 0) > 0
}
function barWidth(remaining: number, total: number): string {
  if (!total) return '0%'
  return `${Math.min(100, Math.round((remaining / total) * 100))}%`
}

async function copyCode(code: string) {
  try {
    await navigator.clipboard.writeText(code)
    ElMessage.success(t('ui_copied'))
  } catch {
    /* ignore */
  }
}

const resetAt = computed(() => fmtDate(plan.value?.credits_reset_at))

async function loadAll() {
  loading.value = true
  try {
    const [p, o] = await Promise.all([fetchPlan(), fetchOrders()])
    plan.value = p
    orders.value = o.orders || []
    if (p.show_invite_codes_enabled) {
      try {
        const inv = await fetchInviteCodes()
        showInvites.value = inv.show
        invites.value = inv.invite_codes || []
      } catch {
        showInvites.value = false
      }
    }
  } catch (e) {
    const err = e as ApiError
    if (err.status === 401) {
      setEmail(null)
      router.replace({ path: '/login', query: { redirect: '/account' } })
      return
    }
    ElMessage.error(err.message || '加载失败')
  } finally {
    loading.value = false
  }
}

onMounted(loadAll)
</script>

<template>
  <main class="account-page">
    <div class="wrap">
      <div v-if="loading" class="account-loading">{{ t('ui_loading') }}</div>

      <template v-else-if="plan">
        <div class="account-hero">
          <div>
            <div class="account-eyebrow"><span class="num">N°00</span> · <span>{{ t('ui_accountEyebrow') }}</span></div>
            <h1>{{ t('ui_accountTitle') }}</h1>
            <div class="account-email-big">{{ email }}</div>
          </div>
          <div class="account-tier-badge">
            <svg width="14" height="14" style="color:var(--cream)"><use href="#ic-chip" /></svg>
            {{ tierLabel(plan.tier) }}
          </div>
        </div>

        <!-- 账号与积分 -->
        <section class="account-section">
          <div class="account-section-tag"><span class="num">N°01</span> · <span>{{ t('ui_sectionCredits') }}</span></div>

          <div class="credit-summary">
            <div class="credit-cell is-accent">
              <span class="k">{{ t('ui_creditsRemaining') }}</span>
              <span class="v">{{ fmtNum(plan.credits_remaining) }}<span class="unit">{{ t('ui_creditsUnit') }}</span></span>
            </div>
            <div class="credit-cell">
              <span class="k">{{ t('ui_creditsTotal') }}</span>
              <span class="v">{{ fmtNum(plan.credits_total) }}</span>
            </div>
            <div class="credit-cell">
              <span class="k">{{ t('ui_creditsUsed') }}</span>
              <span class="v">{{ fmtNum(plan.credits_used) }}</span>
            </div>
            <div class="credit-cell">
              <span class="k">{{ t('ui_resetAt') }}</span>
              <span class="v" style="font-size:18px;font-family:'Geist Mono',monospace;">{{ resetAt }}</span>
            </div>
          </div>

          <div v-if="plan.credit_items.length" class="credit-items">
            <div v-for="item in plan.credit_items" :key="item.id" class="credit-item">
              <div class="ci-label">
                <span class="ci-name">{{ creditTypeLabel(item.type) }}</span>
                <span class="ci-type">{{ item.type }}</span>
              </div>
              <div class="ci-bar"><span :style="{ width: barWidth(item.credits_remaining, item.credits_total) }"></span></div>
              <div class="ci-num">
                {{ fmtNum(item.credits_remaining) }} / {{ fmtNum(item.credits_total) }}
                <div class="ci-expire">{{ item.expires_at ? t('ui_expireAt') + ' ' + fmtDate(item.expires_at) : t('ui_neverExpire') }}</div>
              </div>
            </div>
          </div>
        </section>

        <!-- 订阅订单 -->
        <section class="account-section">
          <div class="account-section-tag"><span class="num">N°02</span> · <span>{{ t('ui_sectionOrders') }}</span></div>
          <div v-if="orders.length" class="orders-wrap">
            <table class="orders-table">
              <thead>
                <tr>
                  <th>{{ t('ui_orderNo') }}</th>
                  <th>{{ t('ui_orderPlan') }}</th>
                  <th>{{ t('ui_orderCycle') }}</th>
                  <th>{{ t('ui_orderAmount') }}</th>
                  <th>{{ t('ui_orderStatus') }}</th>
                  <th>{{ t('ui_orderTime') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="(o, i) in orders" :key="o.payment_order_id || i">
                  <td>{{ o.payment_order_id || '—' }}</td>
                  <td>{{ tierLabel(o.plan_code) }}</td>
                  <td>{{ cycleLabel(o.billing_cycle) }}</td>
                  <td class="o-amount">{{ fmtAmount(o.paid_amount_cents ?? o.price_cents, o.currency) }}</td>
                  <td>
                    <span class="order-status" :class="{ 'is-ok': o.status === 'applied' && !isRefunded(o), 'is-refund': isRefunded(o) }">
                      {{ isRefunded(o) ? t('ui_orderRefunded') : statusLabel(o.status) }}
                    </span>
                  </td>
                  <td>{{ fmtDate(o.created_at, true) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div v-else class="account-empty">{{ t('ui_noOrders') }}</div>
        </section>

        <!-- 我的邀请码 -->
        <section v-if="showInvites" class="account-section">
          <div class="account-section-tag"><span class="num">N°03</span> · <span>{{ t('ui_sectionInvites') }}</span></div>
          <div class="invite-codes">
            <div v-for="c in invites" :key="c.code" class="invite-chip" :class="{ 'is-used': c.is_used }">
              <span>{{ c.code }}</span>
              <svg v-if="!c.is_used" class="copy" width="14" height="14" @click="copyCode(c.code)"><use href="#ic-stack" /></svg>
            </div>
          </div>
        </section>
      </template>
    </div>
  </main>
</template>
