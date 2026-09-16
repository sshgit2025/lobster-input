<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue'
import { Check, Plus, Tickets } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'
import { BONUS_SOURCE_LABELS, zhLabel } from '@/utils/labels'

const PERIODS = [['none', '不刷新'], ['week', '周'], ['month', '月'], ['year', '年']] as const
const VALIDITY_PERIODS = [['forever', '永久'], ['day', '天'], ['week', '周'], ['month', '月'], ['year', '年']] as const
const BILLING_CYCLES = [['monthly', '月付'], ['quarterly', '季付'], ['yearly', '年付']] as const

interface BillingOption {
  cycle: string
  enabled: boolean
  duration_period: string
  duration_count: number
}

interface PlanConfig {
  code: string
  name?: string
  enabled?: boolean
  lifecycle_status?: string
  credits?: number
  validity_period?: string
  validity_count?: number
  reset_period?: string
  rank?: number
  sort_order?: number
  plan_family?: string
  stackable?: boolean
  paid?: boolean
  self_checkout_enabled?: boolean
  auto_renew_supported?: boolean
  paid_topup_enabled?: boolean
  manual_assign_enabled?: boolean
  billing_options?: Record<string, BillingOption>
  auto_assign_on_register?: boolean
  sale_type?: string
  localized_names?: Record<string, string>
  localized_descriptions?: Record<string, string>
  localized_badges?: Record<string, string>
}

interface BonusPolicy {
  enabled?: boolean
  credits?: number
  expires_days?: number
}

interface SubscriptionData {
  plan_code?: string
  subscription_billing_cycle?: string
  subscription_auto_renew?: boolean
  subscription_expires_at?: string
  plan_current_period_note?: string
  plan_current_period_end?: string
  plan_credits_total?: number
  plan_credits_used?: number
  plan_credits_remaining?: number | null
  bonus_credits_remaining?: number
  paid_topup_credits_remaining?: number
  credits_remaining?: number | null
  pending_plan_code?: string
  pending_billing_cycle?: string
  pending_effective_at?: string
  pending_requires_payment?: boolean
  pending_payment_status?: string
  pending_payment_charge_type?: string
  pending_payment_due_at?: string
  pending_payment_blocked_reason?: string
  last_auto_charge_status?: string
  last_auto_charge_type?: string
  last_auto_charge_at?: string
}

const planConfigs = ref<Record<string, PlanConfig>>({})
const bonusPolicy = ref<Record<string, BonusPolicy>>({})
const planModalVisible = ref(false)
const editingPlanCode = ref('')

const assignEmail = ref('')
const assignPlan = ref('')
const assignBillingCycle = ref('monthly')
const assignChangeMode = ref('activate_now')
const assignAutoRenew = ref(false)
const subscriptionInfo = ref('先输入邮箱查询当前订阅，确认到期时间和待生效套餐后再操作。')

const planForm = reactive({
  code: '',
  name: '',
  lifecycle_status: 'active',
  plan_family: 'base',
  rank: 10,
  sort_order: 10,
  credits: 0,
  reset_period: 'month',
  validity_period: 'month',
  validity_count: 1,
  paid: true,
  self_checkout_enabled: true,
  auto_renew_supported: true,
  paid_topup_enabled: true,
  stackable: false,
  manual_assign_enabled: true,
  sale_type: 'external',
  localized_names: {} as Record<string, string>,
  localized_descriptions: {} as Record<string, string>,
  localized_badges: {} as Record<string, string>,
  billing_options: {} as Record<string, BillingOption>,
})

const I18N_LANGS = [
  { code: 'zh', label: '简体' }, { code: 'zh-Hant', label: '繁体' }, { code: 'yue', label: '粤语' },
  { code: 'en', label: 'EN' }, { code: 'ru', label: 'RU' }, { code: 'ko', label: 'KO' },
]
const SALE_TYPES = [
  { value: 'external', label: '外部（客户端可见可购买）' },
  { value: 'internal', label: '内部（仅管理端发放，客户端不可见）' },
  { value: 'system', label: '系统（free/trial 兜底）' },
]

const planCodes = computed(() =>
  Object.keys(planConfigs.value).sort((a, b) => {
    const pa = planConfigs.value[a] || {}
    const pb = planConfigs.value[b] || {}
    return (parseInt(String(pa.sort_order)) || 0) - (parseInt(String(pb.sort_order)) || 0)
      || (parseInt(String(pa.rank)) || 0) - (parseInt(String(pb.rank)) || 0)
      || a.localeCompare(b)
  }),
)

const assignPlanOptions = computed(() =>
  planCodes.value.filter((code) => {
    const p = planConfigs.value[code] || {}
    return p.manual_assign_enabled !== false && p.lifecycle_status !== 'archived'
  }),
)

function defaultBillingOptions(): Record<string, BillingOption> {
  return {
    monthly: { cycle: 'monthly', enabled: true, duration_period: 'month', duration_count: 1 },
    quarterly: { cycle: 'quarterly', enabled: true, duration_period: 'month', duration_count: 3 },
    yearly: { cycle: 'yearly', enabled: true, duration_period: 'year', duration_count: 1 },
  }
}

// 有效期:套餐何时结束(永久 / N天 / 按账期)。
function validityText(plan: PlanConfig): string {
  const period = plan.validity_period || (plan.paid ? 'month' : 'forever')
  if (period === 'forever') return '永久有效'
  const label = Object.fromEntries(VALIDITY_PERIODS)[period] || period
  return `${parseInt(String(plan.validity_count)) || 1}${label}`
}

// 积分刷新周期:有效期内积分多久重置一次(仅影响积分,不影响有效期)。
function resetText(plan: PlanConfig): string {
  const period = plan.reset_period || 'month'
  if (period === 'none') return '不周期刷新'
  const label = Object.fromEntries(PERIODS)[period]
  return label ? `每${label}刷新` : period
}

// 一致文案:有效期 · 积分刷新,例:"永久有效 · 每周刷新"、"7天 · 不周期刷新"。
function planCycleSummary(plan: PlanConfig): string {
  return `${validityText(plan)} · ${resetText(plan)}`
}

function planCapabilities(plan: PlanConfig): string {
  const items: string[] = []
  if (plan.paid) items.push('付费')
  if (plan.self_checkout_enabled && plan.paid) items.push('用户支付')
  if (plan.auto_renew_supported && plan.paid) items.push('自动续费')
  if (plan.paid_topup_enabled && plan.paid) items.push('加购')
  if (plan.manual_assign_enabled !== false) items.push('手动')
  return items.length ? items.join(' / ') : '-'
}

function planStatus(plan: PlanConfig): string {
  return (plan.lifecycle_status || 'active') === 'active' && plan.enabled !== false ? '启用' : '归档'
}

function bonusDesc(source: string): string {
  if (source === 'registration_reward') return '注册成功时发放，独立批次，到期自动失效'
  if (source === 'invite_reward') return '邀请奖励，独立批次，到期自动失效'
  return ''
}

function chargeTypeLabel(value?: string): string {
  const labels: Record<string, string> = {
    manual_purchase: '手动支付',
    auto_renewal: '自动续费',
    scheduled_downgrade: '到期降级扣费',
  }
  return labels[value || ''] || value || '-'
}

function pendingPaymentText(data: SubscriptionData): string {
  if (!data.pending_requires_payment) return '无需扣费'
  const parts = [data.pending_payment_status || 'scheduled', chargeTypeLabel(data.pending_payment_charge_type)]
  if (data.pending_payment_due_at) parts.push(`到期扣费时间：${fmtTime(data.pending_payment_due_at)}`)
  if (data.pending_payment_blocked_reason) parts.push(`阻断：${data.pending_payment_blocked_reason}`)
  return parts.join(' / ')
}

function lastAutoChargeText(data: SubscriptionData): string {
  if (!data.last_auto_charge_status) return '-'
  return `${data.last_auto_charge_status} / ${chargeTypeLabel(data.last_auto_charge_type)} / ${fmtTime(data.last_auto_charge_at)}`
}

function intValue(value: unknown): number {
  return parseInt(String(value)) || 0
}

async function loadAll() {
  const data = await api<{ plan_configs?: Record<string, PlanConfig>; bonus_credit_policy?: Record<string, BonusPolicy> }>('GET', '/api/v1/plans/config')
  planConfigs.value = data.plan_configs || {}
  bonusPolicy.value = data.bonus_credit_policy || {}
  if (!bonusPolicy.value.registration_reward) bonusPolicy.value.registration_reward = {}
  if (!bonusPolicy.value.invite_reward) bonusPolicy.value.invite_reward = {}
  if (assignPlanOptions.value.length && !assignPlan.value) {
    assignPlan.value = assignPlanOptions.value[0]
  }
}

function openPlanModal(code = '') {
  editingPlanCode.value = code
  const plan: PlanConfig = code
    ? { ...(planConfigs.value[code] || {}), code }
    : {
        code: '',
        name: '',
        enabled: true,
        lifecycle_status: 'active',
        credits: 0,
        validity_period: 'month',
        validity_count: 1,
        reset_period: 'month',
        rank: 10,
        sort_order: planCodes.value.length * 10 + 10,
        plan_family: 'base',
        stackable: false,
        paid: true,
        self_checkout_enabled: true,
        auto_renew_supported: true,
        paid_topup_enabled: true,
        manual_assign_enabled: true,
        sale_type: 'external',
        localized_names: {},
        localized_descriptions: {},
        localized_badges: {},
        billing_options: defaultBillingOptions(),
      }

  planForm.code = plan.code || code
  planForm.name = plan.name || code
  planForm.lifecycle_status = plan.lifecycle_status || 'active'
  planForm.plan_family = plan.plan_family || 'base'
  planForm.rank = parseInt(String(plan.rank)) || 0
  planForm.sort_order = parseInt(String(plan.sort_order)) || 0
  planForm.credits = parseInt(String(plan.credits)) || 0
  planForm.reset_period = plan.reset_period || 'month'
  planForm.validity_period = plan.validity_period || (plan.paid ? 'month' : 'forever')
  planForm.validity_count = planForm.validity_period === 'forever' ? 0 : (parseInt(String(plan.validity_count)) || 1)
  planForm.paid = !!plan.paid
  planForm.self_checkout_enabled = plan.self_checkout_enabled !== false && !!plan.paid
  planForm.auto_renew_supported = plan.auto_renew_supported !== false && !!plan.paid
  planForm.paid_topup_enabled = plan.paid_topup_enabled !== false && !!plan.paid
  planForm.stackable = !!plan.stackable
  planForm.manual_assign_enabled = plan.manual_assign_enabled !== false
  planForm.sale_type = plan.sale_type || (plan.code === 'free' || plan.code === 'trial' ? 'system' : (plan.paid ? 'external' : 'internal'))
  planForm.localized_names = { ...(plan.localized_names || {}) }
  if (!planForm.localized_names.zh && plan.name) planForm.localized_names.zh = plan.name
  planForm.localized_descriptions = { ...(plan.localized_descriptions || {}) }
  planForm.localized_badges = { ...(plan.localized_badges || {}) }
  planForm.billing_options = defaultBillingOptions()
  Object.entries(plan.billing_options || {}).forEach(([cycle, opt]) => {
    if (planForm.billing_options[cycle]) Object.assign(planForm.billing_options[cycle], opt)
  })
  planModalVisible.value = true
}

function savePlanModal() {
  const code = (editingPlanCode.value || planForm.code).trim().toLowerCase().replace(/[^a-z0-9_-]/g, '')
  if (!code) { showToast('套餐代码只能包含字母、数字、-、_', 'error'); return }
  if (!editingPlanCode.value && planConfigs.value[code]) { showToast('套餐代码已存在', 'error'); return }

  const paid = planForm.paid
  const validityPeriod = planForm.validity_period
  planConfigs.value[code] = {
    code,
    name: (planForm.localized_names.zh || planForm.name || code).trim(),
    sale_type: planForm.sale_type,
    localized_names: { ...planForm.localized_names },
    localized_descriptions: { ...planForm.localized_descriptions },
    localized_badges: { ...planForm.localized_badges },
    enabled: planForm.lifecycle_status === 'active',
    lifecycle_status: planForm.lifecycle_status,
    credits: planForm.credits || 0,
    validity_period: validityPeriod,
    validity_count: validityPeriod === 'forever' ? 0 : Math.max(1, planForm.validity_count || 1),
    reset_period: planForm.reset_period,
    auto_assign_on_register: code === 'trial',
    rank: planForm.rank || 0,
    sort_order: planForm.sort_order || 0,
    plan_family: planForm.plan_family,
    stackable: planForm.stackable,
    self_checkout_enabled: paid && planForm.self_checkout_enabled,
    auto_renew_supported: paid && planForm.auto_renew_supported,
    paid_topup_enabled: paid && planForm.paid_topup_enabled,
    manual_assign_enabled: planForm.manual_assign_enabled,
    paid,
    billing_options: paid ? { ...planForm.billing_options } : {},
  }
  planModalVisible.value = false
}

async function saveAll() {
  try {
    await api('POST', '/api/v1/plans/config', {
      plan_configs: planConfigs.value,
      bonus_credit_policy: bonusPolicy.value,
    })
    showToast('保存成功')
    await loadAll()
  } catch (e) {
    showToast(e instanceof Error ? e.message : '保存失败', 'error')
  }
}

async function loadSubscription() {
  const email = assignEmail.value.trim()
  if (!email) { showToast('请输入用户邮箱', 'error'); return }
  try {
    const data = await api<SubscriptionData>('GET', `/api/v1/plans/subscription?email=${encodeURIComponent(email)}`)
    const planTotal = intValue(data.plan_credits_total)
    const planUsed = intValue(data.plan_credits_used)
    const planRemaining = data.plan_credits_remaining == null ? Math.max(0, planTotal - planUsed) : intValue(data.plan_credits_remaining)
    const bonusRemaining = intValue(data.bonus_credits_remaining)
    const paidTopupRemaining = intValue(data.paid_topup_credits_remaining)
    const totalRemaining = data.credits_remaining == null ? planRemaining + bonusRemaining + paidTopupRemaining : intValue(data.credits_remaining)
    subscriptionInfo.value =
      `当前套餐：${data.plan_code || '-'}，支付方式：${data.subscription_billing_cycle || '-'}，自动续费：${data.subscription_auto_renew ? '开' : '关'}，订阅到期：${fmtTime(data.subscription_expires_at)}，周期重置：${data.plan_current_period_note || fmtTime(data.plan_current_period_end)}，套餐剩余：${planRemaining}/${planTotal}（已用 ${planUsed}），可用总额：${totalRemaining}（赠送 ${bonusRemaining}，加购 ${paidTopupRemaining}），待生效：${data.pending_plan_code || '-'} ${data.pending_billing_cycle || ''} ${fmtTime(data.pending_effective_at)}，待扣费：${pendingPaymentText(data)}，最近自动扣费：${lastAutoChargeText(data)}`
  } catch (e) {
    showToast(e instanceof Error ? e.message : '查询失败', 'error')
  }
}

async function assignPlanAction() {
  const email = assignEmail.value.trim()
  if (!email) { showToast('请输入用户邮箱', 'error'); return }
  try {
    const d = await api<{ message?: string }>('POST', '/api/v1/plans/assign', {
      email,
      plan_code: assignPlan.value,
      billing_cycle: assignBillingCycle.value,
      change_mode: assignChangeMode.value,
      auto_renew: assignAutoRenew.value,
    })
    showToast(d.message || '已处理')
    await loadSubscription()
  } catch (e) {
    showToast(e instanceof Error ? e.message : '操作失败', 'error')
  }
}

onMounted(() => {
  loadAll().catch((e) => showToast(e instanceof Error ? e.message : '加载失败', 'error'))
})
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">套餐配置</div>
      <div class="page-subtitle">定义套餐档位的权益、计费周期与购买能力，价格由当前激活的支付平台商品映射决定。</div>
    </div>
    <div class="ph-actions">
      <el-button type="primary" @click="saveAll">
        <el-icon><Check /></el-icon>保存套餐配置
      </el-button>
    </div>
  </div>

  <div class="card">
    <div style="display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:12px">
      <div class="card-title" style="margin:0">套餐档位</div>
      <el-button type="primary" size="small" @click="openPlanModal()">
        <el-icon><Plus /></el-icon>新增套餐
      </el-button>
    </div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>代码</th><th>名称</th><th>状态</th><th>类型</th><th>等级</th>
            <th>积分容量</th><th>有效期</th><th>积分刷新</th><th>购买能力</th><th>操作</th>
          </tr>
        </thead>
        <tbody>
          <tr v-if="planCodes.length === 0">
            <td colspan="10">
              <div class="empty-state">
                <div class="empty-icon"><el-icon><Tickets /></el-icon></div>
                <div class="empty-title">暂无套餐档位</div>
                <div class="empty-hint">点击右上角“新增套餐”创建第一个套餐档位。</div>
              </div>
            </td>
          </tr>
          <tr v-for="code in planCodes" :key="code">
            <td><code>{{ code }}</code></td>
            <td>{{ planConfigs[code]?.name || code }}</td>
            <td>{{ planStatus(planConfigs[code] || { code }) }}</td>
            <td>{{ (planConfigs[code]?.plan_family || 'base') === 'addon' ? '叠加包' : '基础订阅' }}</td>
            <td>{{ parseInt(String(planConfigs[code]?.rank)) || 0 }}</td>
            <td>{{ parseInt(String(planConfigs[code]?.credits)) || 0 }}</td>
            <td :title="planCycleSummary(planConfigs[code] || { code })">{{ validityText(planConfigs[code] || { code }) }}</td>
            <td>{{ resetText(planConfigs[code] || { code }) }}</td>
            <td style="font-size:12px;color:var(--text-muted)">{{ planCapabilities(planConfigs[code] || { code }) }}</td>
            <td><el-button size="small" @click="openPlanModal(code)">编辑</el-button></td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="card">
    <div class="card-title">用户订阅管理</div>
    <div class="search-bar" style="margin-bottom:0">
      <input v-model="assignEmail" class="form-input" placeholder="用户邮箱" style="max-width:260px">
      <el-button @click="loadSubscription">查询订阅</el-button>
      <select v-model="assignPlan" class="form-select" style="max-width:180px">
        <option v-for="code in assignPlanOptions" :key="code" :value="code">{{ planConfigs[code]?.name || code }}</option>
      </select>
      <select v-model="assignBillingCycle" class="form-select" style="max-width:120px">
        <option v-for="[cycle, label] in BILLING_CYCLES" :key="cycle" :value="cycle">{{ label }}</option>
      </select>
      <select v-model="assignChangeMode" class="form-select" style="max-width:160px">
        <option value="activate_now">立即开通/升级</option>
        <option value="renew">同套餐续费</option>
        <option value="downgrade_later">到期降级/切换</option>
      </select>
      <label style="display:flex;gap:6px;align-items:center;font-size:13px;color:var(--text-muted)">
        <input v-model="assignAutoRenew" type="checkbox"> 自动续费
      </label>
      <el-button type="primary" @click="assignPlanAction">执行订阅操作</el-button>
    </div>
    <div style="font-size:12px;color:var(--text-muted);margin-top:8px">{{ subscriptionInfo }}</div>
  </div>

  <div class="card">
    <div class="card-title">非套餐积分策略</div>
    <div class="table-wrap">
      <table>
        <thead><tr><th>来源</th><th>启用</th><th>积分数</th><th>有效期天数</th><th>说明</th></tr></thead>
        <tbody>
          <tr v-for="source in ['registration_reward', 'invite_reward']" :key="source">
            <td><div style="font-weight:600">{{ zhLabel(BONUS_SOURCE_LABELS, source) }}</div><code style="font-size:11px;color:var(--text-faint)">{{ source }}</code></td>
            <td><input v-model="bonusPolicy[source]!.enabled" type="checkbox"></td>
            <td><input v-model.number="bonusPolicy[source]!.credits" type="number" class="form-input" min="0"></td>
            <td><input v-model.number="bonusPolicy[source]!.expires_days" type="number" class="form-input" min="1"></td>
            <td style="font-size:12px;color:var(--text-muted)">{{ bonusDesc(source) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
    <div style="font-size:12px;color:var(--text-muted);margin-top:8px">注册奖励、邀请奖励都作为独立 bonus 批次，不参与套餐周期重置；管理员赠送的有效期在赠送表单中单独选择。</div>
  </div>

  <el-dialog v-model="planModalVisible" :title="editingPlanCode ? '编辑套餐' : '新增套餐'" width="860px" destroy-on-close>
    <div class="modal-help">套餐只配置权益、周期和购买能力；实际展示价格来自当前激活支付平台的商品映射。</div>
    <div class="modal-grid" style="margin-top:14px">
      <label>代码<input v-model="planForm.code" class="form-input" placeholder="lite" :disabled="!!editingPlanCode"></label>
      <label>可售类型<select v-model="planForm.sale_type" class="form-select"><option v-for="s in SALE_TYPES" :key="s.value" :value="s.value">{{ s.label }}</option></select></label>
      <div class="i18n-block">
        <div class="i18n-title">套餐名称（多语言）</div>
        <label v-for="l in I18N_LANGS" :key="l.code" class="i18n-row">{{ l.label }}<input v-model="planForm.localized_names[l.code]" class="form-input" :placeholder="l.code === 'zh' ? '专业套餐' : ''"></label>
      </div>
      <div class="i18n-block">
        <div class="i18n-title">角标 badge（多语言，可选）</div>
        <label v-for="l in I18N_LANGS" :key="l.code" class="i18n-row">{{ l.label }}<input v-model="planForm.localized_badges[l.code]" class="form-input"></label>
      </div>
      <div class="i18n-block">
        <div class="i18n-title">描述（多语言，可选）</div>
        <label v-for="l in I18N_LANGS" :key="l.code" class="i18n-row">{{ l.label }}<input v-model="planForm.localized_descriptions[l.code]" class="form-input"></label>
      </div>
      <label>状态<select v-model="planForm.lifecycle_status" class="form-select"><option value="active">启用</option><option value="archived">归档</option></select></label>
      <label>类型<select v-model="planForm.plan_family" class="form-select"><option value="base">基础订阅</option><option value="addon">叠加包</option></select></label>
      <label>等级<input v-model.number="planForm.rank" class="form-input" type="number"></label>
      <label>排序<input v-model.number="planForm.sort_order" class="form-input" type="number"></label>
      <label>积分容量<input v-model.number="planForm.credits" class="form-input" type="number" min="0"></label>
      <label>有效期单位<select v-model="planForm.validity_period" class="form-select"><option v-for="[v, l] in VALIDITY_PERIODS" :key="v" :value="v">{{ l }}</option></select></label>
      <label>有效期数量<input v-model.number="planForm.validity_count" class="form-input" type="number" min="0" :disabled="planForm.validity_period === 'forever'"></label>
      <label>积分刷新周期<select v-model="planForm.reset_period" class="form-select"><option v-for="[v, l] in PERIODS" :key="v" :value="v">每{{ l }}</option></select></label>
    </div>
    <div class="modal-help" style="margin-top:10px">
      有效期 = 套餐何时结束(永久 / N天 / 按账期,永久时数量忽略);积分刷新周期 = 有效期内积分多久重置一次,仅影响积分不影响有效期。
      免费套餐固定「永久有效」,刷新周期可按运营需要任选。
    </div>
    <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-top:16px">
      <label><input v-model="planForm.paid" type="checkbox"> 付费套餐</label>
      <label><input v-model="planForm.self_checkout_enabled" type="checkbox" :disabled="!planForm.paid"> 用户支付</label>
      <label><input v-model="planForm.auto_renew_supported" type="checkbox" :disabled="!planForm.paid"> 支持自动续费</label>
      <label><input v-model="planForm.paid_topup_enabled" type="checkbox" :disabled="!planForm.paid"> 允许客户端加购</label>
      <label><input v-model="planForm.stackable" type="checkbox"> 叠加包</label>
      <label><input v-model="planForm.manual_assign_enabled" type="checkbox"> 手动开通</label>
    </div>
    <div v-if="planForm.paid" style="margin-top:18px">
      <div class="card-title" style="font-size:14px;margin-bottom:10px">计费周期</div>
      <div class="table-wrap">
        <table>
          <thead><tr><th>周期</th><th>启用</th><th>生效数量</th><th>生效单位</th></tr></thead>
          <tbody>
            <tr v-for="[cycle, label] in BILLING_CYCLES" :key="cycle">
              <td>{{ label }}</td>
              <td><input v-model="planForm.billing_options[cycle]!.enabled" type="checkbox"></td>
              <td><input v-model.number="planForm.billing_options[cycle]!.duration_count" class="form-input" type="number" min="1"></td>
              <td>
                <select v-model="planForm.billing_options[cycle]!.duration_period" class="form-select">
                  <option value="month">月</option>
                  <option value="year">年</option>
                </select>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    <div v-else style="font-size:12px;color:var(--text-muted);padding:12px">非付费套餐不需要配置计费周期。</div>
    <template #footer>
      <el-button @click="planModalVisible = false">取消</el-button>
      <el-button type="primary" @click="savePlanModal">确定</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.i18n-block { border: 1px solid var(--border-color, #e5e7eb); border-radius: 6px; padding: 8px 10px; margin: 6px 0; }
.i18n-title { font-size: 12px; color: var(--text-muted); margin-bottom: 6px; }
.i18n-row { display: inline-flex; align-items: center; gap: 4px; margin: 2px 10px 2px 0; font-size: 12px; }
.i18n-row .form-input { width: 130px; }
</style>
