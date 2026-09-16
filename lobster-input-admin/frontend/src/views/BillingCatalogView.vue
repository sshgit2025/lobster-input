<script setup lang="ts">
import { computed, h, onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { EditPen, Plus, Refresh, Upload, Document } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

interface PlanDisplay { description?: string; sort_order?: number; badge?: string }
interface PlanEntitlements { credits_per_period?: number; reset_period?: string }
interface Plan {
  plan_code: string
  rank: number
  name: string
  display?: PlanDisplay
  entitlements?: PlanEntitlements
  paid?: boolean
  status: string
  plan_family?: string
  stackable?: boolean
  self_checkout_enabled?: boolean
  auto_renew_supported?: boolean
  paid_topup_enabled?: boolean
  updated_at?: string
}

interface ChannelBinding {
  payment_method?: string
  channel_code?: string
  account_code?: string
  mode?: string
  external_product_id?: string
  enabled?: boolean
}

interface Price {
  price_id: string
  plan_code: string
  period: string
  currency: string
  amount_cents: number
  lookup_key?: string
  sellable?: boolean
  version?: number
  channel_bindings?: Record<string, ChannelBinding>
  effective_from?: string
  created_at?: string
}

interface KeyedDiff { added: string[]; removed: string[]; changed: Record<string, Record<string, { from: unknown; to: unknown }>> }
interface PublishResult {
  dry_run: boolean
  has_changes: boolean
  diff: { plan_configs?: KeyedDiff; billing_config?: Record<string, unknown> }
  plan_count?: number
  price_count?: number
  snapshot_version?: number
  published_at?: string
}
interface PublishLog {
  snapshot_version?: number
  operator?: string
  published_at?: string
  plan_count?: number
  price_count?: number
  diff_summary?: unknown
}

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------

const loading = ref(false)
const plans = ref<Plan[]>([])
const prices = ref<Price[]>([])
const expandedPlans = ref<Record<string, boolean>>({})

const PERIODS = ['monthly', 'quarterly', 'yearly'] as const
const PERIOD_LABELS: Record<string, string> = { monthly: '月付', quarterly: '季付', yearly: '年付' }
const PLAN_STATUS_LABELS: Record<string, string> = { active: '在售', hidden: '隐藏', retired: '退役' }
const PLAN_STATUS_BADGES: Record<string, string> = { active: 'success', hidden: 'warning', retired: 'muted' }

const operatorName = sessionStorage.getItem('admin_username') || 'admin'

function money(cents?: number, currency?: string): string {
  return `${currency || ''} ${((Number(cents) || 0) / 100).toFixed(2)}`
}

function errMsg(e: unknown, fallback: string): string {
  return e instanceof Error ? e.message : fallback
}

async function loadAll() {
  loading.value = true
  try {
    const [planData, priceData] = await Promise.all([
      api<{ plans: Plan[] }>('GET', '/api/v1/billing-catalog/plans'),
      api<{ prices: Price[] }>('GET', '/api/v1/billing-catalog/prices'),
    ])
    plans.value = planData.plans || []
    prices.value = priceData.prices || []
  } catch (e) {
    showToast(errMsg(e, '加载计费目录失败'), 'error')
  } finally {
    loading.value = false
  }
}

function planPrices(planCode: string): Price[] {
  return prices.value.filter((p) => p.plan_code === planCode)
}

function planCurrencies(planCode: string): string[] {
  return [...new Set(planPrices(planCode).map((p) => p.currency))].sort()
}

/** 当前在售版 = 持有 lookup_key 的 price(每 plan×period×currency 至多一条)。 */
function currentPrice(planCode: string, period: string, currency: string): Price | undefined {
  return planPrices(planCode).find((p) => p.period === period && p.currency === currency && !!p.lookup_key)
}

function versionCount(planCode: string, period: string, currency: string): number {
  return planPrices(planCode).filter((p) => p.period === period && p.currency === currency).length
}

function priceRowClass({ row }: { row: Price }): string {
  return row.sellable ? '' : 'price-row-archived'
}

function showImpactHints(hints: string[] | undefined, fallback: string) {
  if (hints && hints.length) {
    ElMessageBox.alert(
      () => h('div', { class: 'impact-hints' }, hints.map((t) => h('p', { style: 'margin:0 0 10px;line-height:1.6' }, t))),
      '影响提示',
      { confirmButtonText: '知道了', type: 'warning' },
    ).catch(() => {})
  } else {
    showToast(fallback)
  }
}

// ---------------------------------------------------------------------------
// 套餐编辑
// ---------------------------------------------------------------------------

const planDialogVisible = ref(false)
const planSaving = ref(false)
// catalog 只管价格 + 展示元数据(名称/描述/角标/排序/rank);
// 积分/有效期/刷新周期/可购性(自助购买、自动续费、付费加油包)等套餐定义均在"套餐配置"页(PlansView)维护。
const planForm = ref({
  plan_code: '',
  name: '',
  description: '',
  sort_order: 0,
  badge: '',
})

function openPlanEdit(plan: Plan) {
  planForm.value = {
    plan_code: plan.plan_code,
    name: plan.name || '',
    description: plan.display?.description || '',
    sort_order: Number(plan.display?.sort_order) || 0,
    badge: plan.display?.badge || '',
  }
  planDialogVisible.value = true
}

async function savePlan() {
  const f = planForm.value
  if (!f.name.trim()) return showToast('套餐名称不能为空', 'error')
  planSaving.value = true
  try {
    // 只提交展示元数据(name/display/rank);可购性(self_checkout 等)真源在"套餐配置"页,catalog 不再提交。
    const data = await api<{ plan: Plan; impact_hints?: string[] }>('POST', '/api/v1/billing-catalog/plans', {
      plan_code: f.plan_code,
      name: f.name.trim(),
      display: { description: f.description, sort_order: f.sort_order, badge: f.badge },
    })
    planDialogVisible.value = false
    showImpactHints(data.impact_hints, '套餐展示信息已保存(记得"发布投影"后价格才对线上生效;积分/刷新周期/可购性请在"套餐配置"页维护)')
    await loadAll()
  } catch (e) {
    showToast(errMsg(e, '保存套餐失败'), 'error')
  } finally {
    planSaving.value = false
  }
}

async function changePlanStatus(plan: Plan, status: string) {
  if (status === plan.status) return
  const tips: Record<string, string> = {
    active: '恢复为在售:发布后该套餐重新对用户开放。',
    hidden: '设为隐藏:发布后套餐不再展示,但存量用户不受影响。',
    retired: '设为退役:仅停止新购,存量用户续费/积分重置不受影响。',
  }
  try {
    await ElMessageBox.confirm(
      `确认将套餐 ${plan.name}(${plan.plan_code})状态改为「${PLAN_STATUS_LABELS[status] || status}」?${tips[status] || ''}`,
      '变更套餐状态',
      { type: 'warning' },
    )
  } catch {
    return
  }
  try {
    const data = await api<{ plan: Plan; impact_hints?: string[] }>(
      'POST',
      `/api/v1/billing-catalog/plans/${encodeURIComponent(plan.plan_code)}/status`,
      { status },
    )
    showImpactHints(data.impact_hints, '状态已变更(记得"发布投影"后才对线上生效)')
    await loadAll()
  } catch (e) {
    showToast(errMsg(e, '变更状态失败'), 'error')
  }
}

// ---------------------------------------------------------------------------
// 价格版本操作(归档 / 设为在售)
// ---------------------------------------------------------------------------

async function archivePrice(row: Price) {
  try {
    await ElMessageBox.confirm(
      `确认归档价格版本 v${row.version}(${PERIOD_LABELS[row.period] || row.period} / ${money(row.amount_cents, row.currency)})?归档仅下架停止新购,不影响存量订阅。`,
      '归档价格版本',
      { type: 'warning' },
    )
  } catch {
    return
  }
  try {
    await api('POST', `/api/v1/billing-catalog/prices/${encodeURIComponent(row.price_id)}/archive`)
    showToast('已归档,请通过"发布投影"使变更生效')
    await loadAll()
  } catch (e) {
    showToast(errMsg(e, '归档失败'), 'error')
  }
}

async function makePriceCurrent(row: Price) {
  try {
    await ElMessageBox.confirm(
      `确认将 v${row.version}(${money(row.amount_cents, row.currency)})设为「${PERIOD_LABELS[row.period] || row.period}」当前在售价?同币种旧在售版将自动下架。`,
      '设为在售版',
      { type: 'warning' },
    )
  } catch {
    return
  }
  try {
    await api('POST', `/api/v1/billing-catalog/prices/${encodeURIComponent(row.price_id)}/make-current`)
    showToast('已设为在售版,请通过"发布投影"使变更生效')
    await loadAll()
  } catch (e) {
    showToast(errMsg(e, '操作失败'), 'error')
  }
}

// ---------------------------------------------------------------------------
// 改价向导(三步)
// ---------------------------------------------------------------------------

const wizardVisible = ref(false)
const wizardStep = ref(0)
const wizardBusy = ref(false)
const wizardPreview = ref<PublishResult | null>(null)
const wizardForm = ref({
  plan_code: '',
  period: 'monthly',
  currency: 'USD',
  amount: 0,
  creemEnabled: false,
  creem: { payment_method: 'card', account_code: '', mode: 'external_product', external_product_id: '' },
  zpayEnabled: false,
  zpay: { payment_method: 'alipay', account_code: '' },
})

function openWizard(plan: Plan) {
  wizardStep.value = 0
  wizardPreview.value = null
  wizardForm.value = {
    plan_code: plan.plan_code,
    period: 'monthly',
    currency: 'USD',
    amount: 0,
    creemEnabled: false,
    creem: { payment_method: 'card', account_code: '', mode: 'external_product', external_product_id: '' },
    zpayEnabled: false,
    zpay: { payment_method: 'alipay', account_code: '' },
  }
  wizardVisible.value = true
}

function buildWizardBindings(): Record<string, ChannelBinding> {
  const f = wizardForm.value
  const bindings: Record<string, ChannelBinding> = {}
  if (f.creemEnabled) {
    bindings.creem = {
      channel_code: 'creem',
      payment_method: f.creem.payment_method,
      account_code: f.creem.account_code,
      mode: f.creem.mode,
      external_product_id: f.creem.external_product_id,
    }
  }
  if (f.zpayEnabled) {
    bindings.zpay = {
      channel_code: 'zpay',
      payment_method: f.zpay.payment_method,
      account_code: f.zpay.account_code,
      mode: 'amount_order',
    }
  }
  return bindings
}

function validateWizardForm(): string {
  const f = wizardForm.value
  if (!f.currency.trim()) return '请填写币种'
  if (!f.amount || f.amount <= 0) return '请填写有效金额'
  if (!f.creemEnabled && !f.zpayEnabled) return '请至少启用一个渠道绑定'
  if (f.creemEnabled && f.creem.mode === 'external_product' && !f.creem.external_product_id.trim()) {
    return 'Creem external_product 模式需填写渠道商品 ID'
  }
  return ''
}

async function wizardNextToPreview() {
  const err = validateWizardForm()
  if (err) return showToast(err, 'error')
  wizardBusy.value = true
  try {
    wizardPreview.value = await api<PublishResult>('POST', '/api/v1/billing-catalog/publish?dry_run=true', { operator: operatorName })
    wizardStep.value = 1
  } catch (e) {
    showToast(errMsg(e, '预览发布 diff 失败'), 'error')
  } finally {
    wizardBusy.value = false
  }
}

async function wizardSubmit() {
  const f = wizardForm.value
  wizardBusy.value = true
  try {
    await api<{ price: Price; made_current: boolean }>('POST', '/api/v1/billing-catalog/prices', {
      plan_code: f.plan_code,
      period: f.period,
      currency: f.currency.trim().toUpperCase(),
      amount_cents: Math.round(f.amount * 100),
      channel_bindings: buildWizardBindings(),
      make_current: true,
    })
    const result = await api<PublishResult>('POST', '/api/v1/billing-catalog/publish?dry_run=false', { operator: operatorName })
    wizardVisible.value = false
    showToast(`改价完成,已发布快照 v${result.snapshot_version ?? '-'}(仅对新购生效,存量订阅不受影响)`)
    await loadAll()
  } catch (e) {
    showToast(errMsg(e, '改价失败'), 'error')
  } finally {
    wizardBusy.value = false
  }
}

// ---------------------------------------------------------------------------
// 发布投影(dry-run → 确认发布)与发布记录
// ---------------------------------------------------------------------------

const publishVisible = ref(false)
const publishBusy = ref(false)
const publishPreview = ref<PublishResult | null>(null)

async function openPublishPreview() {
  publishBusy.value = true
  try {
    publishPreview.value = await api<PublishResult>('POST', '/api/v1/billing-catalog/publish?dry_run=true', { operator: operatorName })
    publishVisible.value = true
  } catch (e) {
    showToast(errMsg(e, '获取发布预览失败'), 'error')
  } finally {
    publishBusy.value = false
  }
}

async function confirmPublish() {
  try {
    await ElMessageBox.confirm(
      '确认正式发布?发布只更新支付平台的商品与价格投影,不影响套餐定义(积分/有效期/刷新周期由"套餐配置"页管理)。立即对线上生效,仅影响新购,存量订阅不变。',
      '确认发布',
      { type: 'warning' },
    )
  } catch {
    return
  }
  publishBusy.value = true
  try {
    const result = await api<PublishResult>('POST', '/api/v1/billing-catalog/publish?dry_run=false', { operator: operatorName })
    publishVisible.value = false
    showToast(`发布成功,快照版本 v${result.snapshot_version ?? '-'}`)
    await loadAll()
  } catch (e) {
    showToast(errMsg(e, '发布失败'), 'error')
  } finally {
    publishBusy.value = false
  }
}

const logsVisible = ref(false)
const publishLogs = ref<PublishLog[]>([])
const logDetail = ref<PublishLog | null>(null)

async function openPublishLogs() {
  try {
    const data = await api<{ logs: PublishLog[] }>('GET', '/api/v1/billing-catalog/publish-log?limit=50')
    publishLogs.value = data.logs || []
    logDetail.value = null
    logsVisible.value = true
  } catch (e) {
    showToast(errMsg(e, '加载发布记录失败'), 'error')
  }
}

// ---------------------------------------------------------------------------
// diff 渲染:归一化为分组 sections
// ---------------------------------------------------------------------------

interface DiffChangeRow { key: string; fields: { field: string; from: string; to: string }[] }
interface DiffSection { title: string; added: string[]; removed: string[]; changed: DiffChangeRow[] }

const DIFF_SECTION_TITLES: Record<string, string> = {
  plan_configs: '套餐投影 plan_configs',
  products: '商品 products',
  channel_prices: '渠道价 channel_prices',
  currencies: '币种 currencies',
  payment_methods: '支付方式 payment_methods',
  channels: '渠道 channels',
  exchange_rate_provider: '汇率源 exchange_rate_provider',
}

function fmtDiffValue(v: unknown): string {
  if (v === undefined || v === null) return '(空)'
  if (typeof v === 'string') return v || '(空)'
  return JSON.stringify(v)
}

function isKeyedDiff(v: unknown): v is KeyedDiff {
  return !!v && typeof v === 'object' && 'added' in (v as object) && 'removed' in (v as object) && 'changed' in (v as object)
}

function toChangeRows(changed: Record<string, Record<string, { from: unknown; to: unknown }>>): DiffChangeRow[] {
  return Object.entries(changed || {}).map(([key, fields]) => ({
    key,
    fields: Object.entries(fields || {}).map(([field, delta]) => ({
      field,
      from: fmtDiffValue(delta?.from),
      to: fmtDiffValue(delta?.to),
    })),
  }))
}

function diffSections(result: PublishResult | null): DiffSection[] {
  if (!result?.diff) return []
  const sections: DiffSection[] = []
  const push = (name: string, value: unknown) => {
    if (isKeyedDiff(value)) {
      const changed = toChangeRows(value.changed)
      if (value.added.length || value.removed.length || changed.length) {
        sections.push({ title: DIFF_SECTION_TITLES[name] || name, added: value.added, removed: value.removed, changed })
      }
    } else if (value && typeof value === 'object' && Object.keys(value as object).length) {
      // entry diff(如 exchange_rate_provider):field → {from,to}
      sections.push({
        title: DIFF_SECTION_TITLES[name] || name,
        added: [],
        removed: [],
        changed: toChangeRows({ [name]: value as Record<string, { from: unknown; to: unknown }> }),
      })
    }
  }
  push('plan_configs', result.diff.plan_configs)
  for (const [name, value] of Object.entries(result.diff.billing_config || {})) push(name, value)
  return sections
}

const publishSections = computed(() => diffSections(publishPreview.value))
const wizardSections = computed(() => diffSections(wizardPreview.value))

onMounted(loadAll)
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">价格目录</div>
      <div class="page-subtitle">价格版本管理页;发布只更新价格,不影响套餐定义(套餐积分/有效期/刷新周期在"套餐配置"页管理)。改价不影响存量订阅,仅对新购生效。</div>
    </div>
    <div class="ph-actions">
      <el-button :icon="Refresh" @click="loadAll">刷新</el-button>
      <el-button :icon="Document" @click="openPublishLogs">发布记录</el-button>
      <el-button type="primary" :icon="Upload" :loading="publishBusy" @click="openPublishPreview">发布投影</el-button>
    </div>
  </div>

  <el-alert type="info" :closable="false" show-icon style="margin-bottom:16px">
    改价采用"新建版本 + 转移在售标记"模式:历史价格版本不可修改,不影响存量订阅,仅对新购生效。
  </el-alert>

  <div v-loading="loading">
    <div v-if="!plans.length && !loading" class="card">
      <div class="empty-state">
        <div class="empty-title">暂无套餐</div>
        <div class="empty-hint">请先在支付服务执行 catalog 迁移脚本,或检查支付服务配置。</div>
      </div>
    </div>

    <div v-for="plan in plans" :key="plan.plan_code" class="card plan-card">
      <div class="plan-head">
        <div class="plan-title-wrap">
          <span class="plan-name">{{ plan.name }}</span>
          <code class="plan-code">{{ plan.plan_code }}</code>
          <span class="badge" :class="`badge-${PLAN_STATUS_BADGES[plan.status] || 'muted'}`">{{ PLAN_STATUS_LABELS[plan.status] || plan.status }}</span>
          <span v-if="plan.display?.badge" class="badge badge-primary">{{ plan.display.badge }}</span>
        </div>
        <div class="plan-actions">
          <el-select
            :model-value="plan.status"
            size="small"
            style="width:110px"
            @change="(v: string) => changePlanStatus(plan, v)"
          >
            <el-option label="在售" value="active" />
            <el-option label="隐藏" value="hidden" />
            <el-option label="退役" value="retired" />
          </el-select>
          <el-button size="small" :icon="EditPen" @click="openPlanEdit(plan)">编辑</el-button>
          <el-button size="small" type="primary" plain :icon="Plus" @click="openWizard(plan)">改价向导</el-button>
        </div>
      </div>

      <div class="plan-meta">
        <span>rank <strong>{{ plan.rank }}</strong></span>
        <span>排序 <strong>{{ plan.display?.sort_order ?? 0 }}</strong></span>
        <span v-if="plan.display?.description" class="plan-desc">{{ plan.display.description }}</span>
      </div>

      <template v-if="planPrices(plan.plan_code).length">
        <table class="price-matrix">
          <thead>
            <tr>
              <th>周期 \ 币种</th>
              <th v-for="cur in planCurrencies(plan.plan_code)" :key="cur">{{ cur }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="period in PERIODS" :key="period">
              <td class="matrix-period">{{ PERIOD_LABELS[period] }}</td>
              <td v-for="cur in planCurrencies(plan.plan_code)" :key="cur">
                <template v-if="currentPrice(plan.plan_code, period, cur)">
                  <span class="matrix-amount">{{ money(currentPrice(plan.plan_code, period, cur)!.amount_cents, cur) }}</span>
                  <span class="matrix-version">v{{ currentPrice(plan.plan_code, period, cur)!.version }}</span>
                  <span v-if="versionCount(plan.plan_code, period, cur) > 1" class="matrix-history">共 {{ versionCount(plan.plan_code, period, cur) }} 版</span>
                </template>
                <span v-else-if="versionCount(plan.plan_code, period, cur)" class="matrix-empty">无在售({{ versionCount(plan.plan_code, period, cur) }} 版历史)</span>
                <span v-else class="matrix-empty">-</span>
              </td>
            </tr>
          </tbody>
        </table>

        <el-button link type="primary" size="small" @click="expandedPlans[plan.plan_code] = !expandedPlans[plan.plan_code]">
          {{ expandedPlans[plan.plan_code] ? '收起价格版本列表' : `展开全部价格版本(${planPrices(plan.plan_code).length})` }}
        </el-button>

        <el-table
          v-if="expandedPlans[plan.plan_code]"
          :data="planPrices(plan.plan_code)"
          size="small"
          stripe
          :row-class-name="priceRowClass"
          style="margin-top:8px"
        >
          <el-table-column label="版本" width="70"><template #default="{ row }">v{{ row.version }}</template></el-table-column>
          <el-table-column label="周期" width="80"><template #default="{ row }">{{ PERIOD_LABELS[row.period] || row.period }}</template></el-table-column>
          <el-table-column prop="currency" label="币种" width="70" />
          <el-table-column label="金额" width="120" align="right"><template #default="{ row }"><span class="amount">{{ money(row.amount_cents, row.currency) }}</span></template></el-table-column>
          <el-table-column label="状态" width="90">
            <template #default="{ row }">
              <span v-if="row.lookup_key" class="badge badge-success">在售</span>
              <span v-else-if="row.sellable" class="badge badge-info">可售</span>
              <span v-else class="badge badge-muted">停售</span>
            </template>
          </el-table-column>
          <el-table-column label="lookup_key" min-width="130"><template #default="{ row }"><code>{{ row.lookup_key || '-' }}</code></template></el-table-column>
          <el-table-column label="渠道绑定" min-width="160">
            <template #default="{ row }">
              <span v-if="Object.keys(row.channel_bindings || {}).length">
                <el-tag v-for="(binding, key) in row.channel_bindings" :key="String(key)" size="small" style="margin-right:4px">
                  {{ key }} · {{ binding.payment_method || '-' }}{{ binding.mode === 'external_product' ? ' · 渠道商品' : '' }}
                </el-tag>
              </span>
              <span v-else>-</span>
            </template>
          </el-table-column>
          <el-table-column label="price_id" min-width="170"><template #default="{ row }"><code>{{ row.price_id }}</code></template></el-table-column>
          <el-table-column label="创建时间" width="160"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
          <el-table-column label="操作" width="150" fixed="right">
            <template #default="{ row }">
              <el-button v-if="row.sellable" size="small" type="warning" plain @click="archivePrice(row)">归档</el-button>
              <el-button v-if="!row.lookup_key" size="small" type="primary" plain @click="makePriceCurrent(row)">设为在售</el-button>
            </template>
          </el-table-column>
        </el-table>
      </template>
      <div v-else class="empty-hint">该套餐暂无价格版本,可通过"改价向导"创建。</div>
    </div>
  </div>

  <!-- 套餐编辑 -->
  <el-dialog v-model="planDialogVisible" :title="`编辑套餐 · ${planForm.plan_code}`" width="620px">
    <el-form label-width="130px">
      <el-form-item label="名称">
        <el-input v-model="planForm.name" placeholder="套餐展示名称" />
      </el-form-item>
      <el-form-item label="描述">
        <el-input v-model="planForm.description" type="textarea" :rows="2" placeholder="套餐描述文案" />
      </el-form-item>
      <el-form-item label="角标 badge">
        <el-input v-model="planForm.badge" placeholder="如 最受欢迎(可留空)" />
      </el-form-item>
      <el-form-item label="展示排序">
        <el-input-number v-model="planForm.sort_order" :min="0" :step="1" />
      </el-form-item>
      <el-form-item>
        <div class="form-hint">
          套餐的积分 / 有效期 / 刷新周期 / 可购性(自助购买、自动续费、付费加油包)等定义均在「套餐配置」页维护,此处只管价格与展示元数据。
        </div>
      </el-form-item>
    </el-form>
    <template #footer>
      <el-button @click="planDialogVisible = false">取消</el-button>
      <el-button type="primary" :loading="planSaving" @click="savePlan">保存</el-button>
    </template>
  </el-dialog>

  <!-- 改价向导 -->
  <el-dialog v-model="wizardVisible" :title="`改价向导 · ${wizardForm.plan_code}`" width="760px" :close-on-click-modal="false">
    <el-steps :active="wizardStep" align-center finish-status="success" style="margin-bottom:20px">
      <el-step title="填写新价" />
      <el-step title="预览 diff" />
      <el-step title="确认发布" />
    </el-steps>

    <el-alert type="warning" :closable="false" show-icon style="margin-bottom:16px">
      改价不影响存量订阅,仅对新购生效。确认后将新建价格版本并设为在售,然后正式发布投影。
    </el-alert>

    <template v-if="wizardStep === 0">
      <el-form label-width="120px">
        <el-form-item label="周期">
          <el-select v-model="wizardForm.period" style="width:200px">
            <el-option label="月付 monthly" value="monthly" />
            <el-option label="季付 quarterly" value="quarterly" />
            <el-option label="年付 yearly" value="yearly" />
          </el-select>
        </el-form-item>
        <el-form-item label="币种">
          <el-select v-model="wizardForm.currency" filterable allow-create style="width:200px">
            <el-option label="USD" value="USD" />
            <el-option label="CNY" value="CNY" />
          </el-select>
        </el-form-item>
        <el-form-item label="金额(元)">
          <el-input-number v-model="wizardForm.amount" :min="0" :precision="2" :step="1" style="width:200px" />
        </el-form-item>

        <el-divider content-position="left">渠道绑定</el-divider>

        <el-form-item label="Creem">
          <el-switch v-model="wizardForm.creemEnabled" />
        </el-form-item>
        <template v-if="wizardForm.creemEnabled">
          <el-form-item label="支付方式">
            <el-input v-model="wizardForm.creem.payment_method" placeholder="如 card" style="width:200px" />
          </el-form-item>
          <el-form-item label="账号 account">
            <el-input v-model="wizardForm.creem.account_code" placeholder="渠道账号 code,可留空使用默认账号" style="width:280px" />
          </el-form-item>
          <el-form-item label="模式">
            <el-select v-model="wizardForm.creem.mode" style="width:220px">
              <el-option label="渠道商品 external_product" value="external_product" />
              <el-option label="按金额下单 amount_order" value="amount_order" />
            </el-select>
          </el-form-item>
          <el-form-item v-if="wizardForm.creem.mode === 'external_product'" label="渠道商品 ID">
            <el-input v-model="wizardForm.creem.external_product_id" placeholder="Creem product id(需先在 Creem 后台按新价创建)" style="width:340px" />
          </el-form-item>
        </template>

        <el-form-item label="ZPay">
          <el-switch v-model="wizardForm.zpayEnabled" />
        </el-form-item>
        <template v-if="wizardForm.zpayEnabled">
          <el-form-item label="支付方式">
            <el-select v-model="wizardForm.zpay.payment_method" style="width:200px">
              <el-option label="支付宝 alipay" value="alipay" />
              <el-option label="微信 wxpay" value="wxpay" />
            </el-select>
          </el-form-item>
          <el-form-item label="账号 account">
            <el-input v-model="wizardForm.zpay.account_code" placeholder="渠道账号 code,可留空使用默认账号" style="width:280px" />
          </el-form-item>
          <el-form-item label="模式">
            <el-input model-value="amount_order(按金额下单,固定)" disabled style="width:280px" />
          </el-form-item>
        </template>
      </el-form>
    </template>

    <template v-else-if="wizardStep === 1">
      <div class="wizard-summary">
        新价:<strong>{{ wizardForm.plan_code }}</strong> · {{ PERIOD_LABELS[wizardForm.period] }} · <span class="amount">{{ wizardForm.currency }} {{ wizardForm.amount.toFixed(2) }}</span>
        · 渠道:{{ [wizardForm.creemEnabled ? 'creem' : '', wizardForm.zpayEnabled ? 'zpay' : ''].filter(Boolean).join(' / ') }}
      </div>
      <div class="hint-box" style="margin-bottom:12px">
        以下为当前目录相对线上投影的待发布 diff(尚未包含本次新价;确认后会连同本次新价一并发布)。
      </div>
      <template v-if="wizardSections.length">
        <div v-for="section in wizardSections" :key="section.title" class="diff-section">
          <div class="card-title">{{ section.title }}</div>
          <div v-if="section.added.length" class="diff-line">新增:<span v-for="k in section.added" :key="k" class="badge badge-success diff-badge">{{ k }}</span></div>
          <div v-if="section.removed.length" class="diff-line">移除:<span v-for="k in section.removed" :key="k" class="badge badge-danger diff-badge">{{ k }}</span></div>
          <div v-for="row in section.changed" :key="row.key" class="diff-change">
            <div class="diff-key">变更:{{ row.key }}</div>
            <div v-for="f in row.fields" :key="f.field" class="diff-field">
              <code>{{ f.field }}</code>:<span class="diff-from">{{ f.from }}</span> → <span class="diff-to">{{ f.to }}</span>
            </div>
          </div>
        </div>
      </template>
      <div v-else class="empty-hint">当前目录与线上投影一致,本次发布将只包含新价格版本。</div>
    </template>

    <template v-else>
      <div class="wizard-confirm">
        <p>即将执行:</p>
        <ol>
          <li>创建价格版本:<strong>{{ wizardForm.plan_code }}</strong> · {{ PERIOD_LABELS[wizardForm.period] }} · <span class="amount">{{ wizardForm.currency }} {{ wizardForm.amount.toFixed(2) }}</span>,并设为在售(同币种旧在售版自动下架);</li>
          <li>正式发布投影(包含目录中全部未发布变更)。</li>
        </ol>
        <p class="hint-box">改价不影响存量订阅,仅对新购生效。此操作会写入发布审计日志。</p>
      </div>
    </template>

    <template #footer>
      <el-button @click="wizardVisible = false">取消</el-button>
      <el-button v-if="wizardStep > 0" :disabled="wizardBusy" @click="wizardStep -= 1">上一步</el-button>
      <el-button v-if="wizardStep === 0" type="primary" :loading="wizardBusy" @click="wizardNextToPreview">下一步:预览</el-button>
      <el-button v-else-if="wizardStep === 1" type="primary" @click="wizardStep = 2">下一步:确认</el-button>
      <el-button v-else type="danger" :loading="wizardBusy" @click="wizardSubmit">确认改价并发布</el-button>
    </template>
  </el-dialog>

  <!-- 发布投影预览 -->
  <el-dialog v-model="publishVisible" title="发布投影(dry-run 预览)" width="820px">
    <template v-if="publishPreview">
      <div class="publish-meta">
        套餐 {{ publishPreview.plan_count ?? '-' }} 个 · 价格版本 {{ publishPreview.price_count ?? '-' }} 条 ·
        <span class="badge" :class="publishPreview.has_changes ? 'badge-warning' : 'badge-success'">
          {{ publishPreview.has_changes ? '有待发布变更' : '与线上一致,无变更' }}
        </span>
      </div>
      <template v-if="publishSections.length">
        <div v-for="section in publishSections" :key="section.title" class="diff-section">
          <div class="card-title">{{ section.title }}</div>
          <div v-if="section.added.length" class="diff-line">新增:<span v-for="k in section.added" :key="k" class="badge badge-success diff-badge">{{ k }}</span></div>
          <div v-if="section.removed.length" class="diff-line">移除:<span v-for="k in section.removed" :key="k" class="badge badge-danger diff-badge">{{ k }}</span></div>
          <div v-for="row in section.changed" :key="row.key" class="diff-change">
            <div class="diff-key">变更:{{ row.key }}</div>
            <div v-for="f in row.fields" :key="f.field" class="diff-field">
              <code>{{ f.field }}</code>:<span class="diff-from">{{ f.from }}</span> → <span class="diff-to">{{ f.to }}</span>
            </div>
          </div>
        </div>
      </template>
      <div v-else class="empty-hint">目录与线上投影完全一致,无需发布。</div>
    </template>
    <template #footer>
      <el-button @click="publishVisible = false">关闭</el-button>
      <el-button type="danger" :disabled="!publishPreview?.has_changes" :loading="publishBusy" @click="confirmPublish">确认正式发布</el-button>
    </template>
  </el-dialog>

  <!-- 发布记录 -->
  <el-dialog v-model="logsVisible" title="发布记录" width="820px">
    <el-table :data="publishLogs" size="small" stripe max-height="420">
      <el-table-column label="快照版本" width="90"><template #default="{ row }">v{{ row.snapshot_version ?? '-' }}</template></el-table-column>
      <el-table-column label="操作人" min-width="120"><template #default="{ row }">{{ row.operator || '-' }}</template></el-table-column>
      <el-table-column label="发布时间" width="170"><template #default="{ row }">{{ fmtTime(row.published_at) }}</template></el-table-column>
      <el-table-column label="套餐数" width="80" align="right"><template #default="{ row }">{{ row.plan_count ?? '-' }}</template></el-table-column>
      <el-table-column label="价格数" width="80" align="right"><template #default="{ row }">{{ row.price_count ?? '-' }}</template></el-table-column>
      <el-table-column label="操作" width="90">
        <template #default="{ row }"><el-button size="small" link type="primary" @click="logDetail = row">diff 详情</el-button></template>
      </el-table-column>
      <template #empty><div class="empty-hint">暂无发布记录</div></template>
    </el-table>
    <template v-if="logDetail">
      <div class="card-title" style="margin-top:14px">快照 v{{ logDetail.snapshot_version }} diff 摘要</div>
      <pre class="code-block">{{ JSON.stringify(logDetail.diff_summary ?? {}, null, 2) }}</pre>
    </template>
    <template #footer>
      <el-button @click="logsVisible = false">关闭</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.page-subtitle { color: var(--text-muted); font-size: 13px; }

.plan-card { margin-bottom: 16px; }
.plan-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.plan-title-wrap { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.plan-name { font-size: 16px; font-weight: 700; color: var(--text); }
.plan-code { font-size: 12px; color: var(--text-muted); }
.plan-actions { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.plan-meta { display: flex; align-items: center; gap: 18px; flex-wrap: wrap; margin: 10px 0 14px; font-size: 13px; color: var(--text-muted); }
.plan-meta strong { color: var(--text); }
.plan-desc { font-size: 12px; color: var(--text-faint); }

.price-matrix { width: 100%; border-collapse: collapse; margin-bottom: 10px; font-size: 13px; }
.price-matrix th, .price-matrix td { border: 1px solid var(--border); padding: 8px 12px; text-align: left; }
.price-matrix th { color: var(--text-muted); font-weight: 600; background: rgba(148, 163, 184, 0.06); }
.matrix-period { color: var(--text-muted); width: 120px; }
.matrix-amount { font-weight: 700; color: var(--text); font-variant-numeric: tabular-nums; margin-right: 8px; }
.matrix-version { font-size: 11px; color: var(--text-muted); margin-right: 8px; }
.matrix-history { font-size: 11px; color: var(--text-faint); }
.matrix-empty { color: var(--text-faint); font-size: 12px; }

:deep(.price-row-archived) { opacity: 0.55; }

.amount { font-variant-numeric: tabular-nums; font-weight: 600; }
.empty-hint { color: var(--text-muted); font-size: 13px; padding: 8px 0; }
.form-hint { font-size: 12px; color: var(--text-faint); line-height: 1.5; margin-top: 4px; }
.hint-box { color: var(--text-muted); font-size: 12px; line-height: 1.6; }

.wizard-summary { font-size: 13px; color: var(--text-muted); margin-bottom: 10px; }
.wizard-confirm { font-size: 13px; color: var(--text-muted); line-height: 1.8; }
.wizard-confirm ol { padding-left: 20px; margin: 8px 0; }

.publish-meta { font-size: 13px; color: var(--text-muted); margin-bottom: 12px; display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }

.diff-section { margin-bottom: 16px; }
.diff-line { font-size: 13px; color: var(--text-muted); margin: 6px 0; }
.diff-badge { margin-right: 6px; }
.diff-change { border-left: 2px solid var(--border); padding-left: 10px; margin: 8px 0; }
.diff-key { font-size: 13px; color: var(--text); font-weight: 600; margin-bottom: 4px; }
.diff-field { font-size: 12px; color: var(--text-muted); margin: 2px 0; word-break: break-all; }
.diff-from { color: var(--danger); text-decoration: line-through; }
.diff-to { color: var(--success); }

.code-block { max-height: 300px; overflow: auto; background: rgba(0,0,0,.22); border: 1px solid var(--border); border-radius: 8px; padding: 12px; color: var(--text-muted); font-size: 12px; }
</style>
