<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { User } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface PlanConfig { sort_order?: number; rank?: number; sale_type?: string }
interface AccountRow {
  email: string; plan_code?: string; subscription_billing_cycle?: string
  subscription_auto_renew: boolean; subscription_started_at?: string
  subscription_expires_at?: string; plan_current_period_note?: string
  plan_current_period_end?: string; plan_credits_used?: number; plan_credits_total?: number
  pending_plan_code?: string; pending_billing_cycle?: string; pending_requires_payment?: boolean
  pending_payment_status?: string; pending_payment_charge_type?: string
  pending_payment_amount_cents?: number; pending_effective_at?: string
  pending_payment_blocked_reason?: string
}
interface HistoryRow {
  created_at: string; event_type?: string; from_plan_code?: string
  to_plan_code?: string; plan_code?: string; admin_email?: string; operator?: string
  before?: { plan_code?: string }; after?: { plan_code?: string }
}
interface DetailCurrent extends AccountRow {
  last_auto_charge_status?: string; last_auto_charge_type?: string; last_auto_charge_at?: string
}

const filters = ref({ email: '', plan: '' })
const accounts = ref<AccountRow[]>([])
const page = ref(1)
const total = ref(0)
const planOptions = ref<string[]>([])
const planConfigs = ref<Record<string, PlanConfig>>({})

const grantVisible = ref(false)
const grantForm = ref({ email: '', plan_code: '', start: '', end: '', reason: '' })

const detailVisible = ref(false)
const detailCurrent = ref<DetailCurrent | null>(null)
const detailHistory = ref<HistoryRow[]>([])

function money(cents?: number): string {
  return ((parseInt(String(cents)) || 0) / 100).toFixed(2)
}

function chargeTypeLabel(value?: string): string {
  const labels: Record<string, string> = {
    manual_purchase: '手动支付', auto_renewal: '自动续费', scheduled_downgrade: '到期降级扣费',
  }
  return labels[value || ''] || value || '-'
}

function resetLabel(row: AccountRow): string {
  return row.plan_current_period_note || fmtTime(row.plan_current_period_end)
}

function pendingSummary(row: AccountRow): string {
  if (!row.pending_plan_code) return '-'
  const payment = row.pending_requires_payment
    ? `${row.pending_payment_status || 'scheduled'} / ${chargeTypeLabel(row.pending_payment_charge_type)} / ￥${money(row.pending_payment_amount_cents)}`
    : '无需扣费'
  return `${row.pending_plan_code} ${row.pending_billing_cycle || ''}\n${payment}`
}

async function loadPlanFilter() {
  const data = await api<{ plan_configs?: Record<string, PlanConfig> }>('GET', '/api/v1/plans/config')
  const configs = data.plan_configs || {}
  planConfigs.value = configs
  planOptions.value = Object.keys(configs).sort((a, b) => {
    const pa = configs[a] || {}
    const pb = configs[b] || {}
    return (parseInt(String(pa.sort_order)) || 0) - (parseInt(String(pb.sort_order)) || 0)
      || (parseInt(String(pa.rank)) || 0) - (parseInt(String(pb.rank)) || 0)
      || a.localeCompare(b)
  })
}

async function loadAccounts(p = 1) {
  page.value = p
  const params = new URLSearchParams({ page: String(p), page_size: '20' })
  if (filters.value.email.trim()) params.set('email', filters.value.email.trim())
  if (filters.value.plan) params.set('plan_code', filters.value.plan)
  try {
    const data = await api<{ items: AccountRow[]; total: number }>('GET', `/api/v1/plans/accounts?${params}`)
    accounts.value = data.items
    total.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function resetFilter() {
  filters.value = { email: '', plan: '' }
  loadAccounts(1)
}

async function openDetail(email: string) {
  try {
    const data = await api<{ current: DetailCurrent; history: HistoryRow[] }>('GET', `/api/v1/plans/accounts/detail?email=${encodeURIComponent(email)}`)
    detailCurrent.value = data.current
    detailHistory.value = data.history || []
    detailVisible.value = true
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function openGrant(email = '') {
  grantForm.value = { email, plan_code: '', start: '', end: '', reason: '' }
  grantVisible.value = true
}

async function submitGrant() {
  const f = grantForm.value
  if (!f.email.trim() || !f.plan_code) { showToast('请填写邮箱与套餐', 'error'); return }
  try {
    await api('POST', '/api/v1/plans/grant', {
      email: f.email.trim(), plan_code: f.plan_code,
      start: f.start || null, end: f.end || null, reason: f.reason,
    })
    showToast('套餐已发放', 'success')
    grantVisible.value = false
    loadAccounts(page.value)
  } catch (e) { showToast(e instanceof Error ? e.message : '发放失败', 'error') }
}

async function revokePlan(email: string) {
  try {
    await api('POST', '/api/v1/plans/revoke', { email, to_free: true })
    showToast('已取消套餐并回落免费版', 'success')
    loadAccounts(page.value)
  } catch (e) { showToast(e instanceof Error ? e.message : '取消失败', 'error') }
}

onMounted(() => loadPlanFilter().finally(() => loadAccounts(1)))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">套餐账号</div>
      <div class="page-subtitle">查看每位用户的订阅状态、积分用量与待生效变更，按邮箱或套餐筛选并下钻至订阅历史。</div>
    </div>
    <div class="ph-actions">
      <el-button type="primary" @click="openGrant()">发放套餐</el-button>
    </div>
  </div>
  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="邮箱搜索" style="max-width:240px" clearable />
      <el-select v-model="filters.plan" placeholder="全部套餐" style="max-width:150px" clearable>
        <el-option label="全部套餐" value="" />
        <el-option v-for="code in planOptions" :key="code" :label="code" :value="code" />
      </el-select>
      <el-button type="primary" @click="loadAccounts(1)">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
    </div>

    <el-table :data="accounts" stripe>
      <template #empty>
        <div class="empty-state">
          <div class="empty-icon"><el-icon><User /></el-icon></div>
          <div class="empty-title">暂无订阅账号</div>
          <div class="empty-hint">调整邮箱或套餐筛选条件后重试。</div>
        </div>
      </template>
      <el-table-column prop="email" label="邮箱" min-width="180" />
      <el-table-column label="套餐" width="100"><template #default="{ row }"><el-tag size="small">{{ row.plan_code || '-' }}</el-tag></template></el-table-column>
      <el-table-column prop="subscription_billing_cycle" label="支付方式" width="100"><template #default="{ row }">{{ row.subscription_billing_cycle || '-' }}</template></el-table-column>
      <el-table-column label="自动续费" width="90"><template #default="{ row }">{{ row.subscription_auto_renew ? '开' : '关' }}</template></el-table-column>
      <el-table-column label="订阅开始" width="170"><template #default="{ row }">{{ fmtTime(row.subscription_started_at) }}</template></el-table-column>
      <el-table-column label="订阅到期" width="170"><template #default="{ row }">{{ row.subscription_expires_at ? fmtTime(row.subscription_expires_at) : '永久/无' }}</template></el-table-column>
      <el-table-column label="周期结束" width="170"><template #default="{ row }">{{ resetLabel(row) }}</template></el-table-column>
      <el-table-column label="套餐积分" width="100"><template #default="{ row }">{{ row.plan_credits_used || 0 }}/{{ row.plan_credits_total || 0 }}</template></el-table-column>
      <el-table-column label="待生效" min-width="160"><template #default="{ row }"><span style="font-size:12px;white-space:pre-line">{{ pendingSummary(row) }}</span></template></el-table-column>
      <el-table-column label="操作" width="230" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="openDetail(row.email)">详情</el-button>
          <el-button size="small" type="warning" @click="openGrant(row.email)">发放</el-button>
          <el-popconfirm title="取消当前套餐并回落免费版?" width="220" @confirm="revokePlan(row.email)">
            <template #reference><el-button size="small" type="danger">取消</el-button></template>
          </el-popconfirm>
        </template>
      </el-table-column>
    </el-table>

    <div class="pager-row">
      <el-pagination
        v-model:current-page="page"
        :page-size="20"
        :total="total"
        layout="total, prev, pager, next"
        @current-change="loadAccounts"
      />
    </div>
  </div>

  <el-dialog v-model="detailVisible" title="套餐详情" width="760px">
    <template v-if="detailCurrent">
      <div class="detail-info">
        <p>邮箱：<code>{{ detailCurrent.email }}</code></p>
        <p>当前套餐：<code>{{ detailCurrent.plan_code || '-' }}</code>，支付方式：<code>{{ detailCurrent.subscription_billing_cycle || '-' }}</code>，自动续费：{{ detailCurrent.subscription_auto_renew ? '开' : '关' }}</p>
        <p>订阅开始：{{ fmtTime(detailCurrent.subscription_started_at) }}，订阅到期：{{ detailCurrent.subscription_expires_at ? fmtTime(detailCurrent.subscription_expires_at) : '永久/无' }}</p>
        <p>周期结束：{{ resetLabel(detailCurrent) }}，套餐积分：{{ detailCurrent.plan_credits_used || 0 }}/{{ detailCurrent.plan_credits_total || 0 }}</p>
        <p v-if="detailCurrent.pending_plan_code">
          待生效：<code>{{ detailCurrent.pending_plan_code }}</code> {{ detailCurrent.pending_billing_cycle || '' }} {{ detailCurrent.pending_effective_at ? fmtTime(detailCurrent.pending_effective_at) : '' }}
        </p>
        <p v-if="detailCurrent.pending_plan_code">
          待扣费：{{ detailCurrent.pending_requires_payment ? `${detailCurrent.pending_payment_status || 'scheduled'} / ${chargeTypeLabel(detailCurrent.pending_payment_charge_type)} / ￥${money(detailCurrent.pending_payment_amount_cents)}` : '无需扣费' }}
        </p>
        <p v-if="detailCurrent.pending_payment_blocked_reason">阻断：{{ detailCurrent.pending_payment_blocked_reason }}</p>
        <p>最近自动扣费：{{ detailCurrent.last_auto_charge_status || '-' }} / {{ chargeTypeLabel(detailCurrent.last_auto_charge_type) }} / {{ detailCurrent.last_auto_charge_at ? fmtTime(detailCurrent.last_auto_charge_at) : '-' }}</p>
      </div>
      <div class="card-title" style="margin-top:16px">套餐历史</div>
      <el-table :data="detailHistory" stripe size="small">
        <el-table-column label="时间" width="170"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
        <el-table-column prop="event_type" label="事件" width="120"><template #default="{ row }">{{ row.event_type || '-' }}</template></el-table-column>
        <el-table-column label="前套餐" width="100"><template #default="{ row }">{{ row.from_plan_code || row.before?.plan_code || '-' }}</template></el-table-column>
        <el-table-column label="后套餐" width="100"><template #default="{ row }">{{ row.to_plan_code || row.after?.plan_code || row.plan_code || '-' }}</template></el-table-column>
        <el-table-column label="操作人" min-width="140"><template #default="{ row }">{{ row.admin_email || row.operator || '-' }}</template></el-table-column>
      </el-table>
    </template>
  </el-dialog>

  <el-dialog v-model="grantVisible" title="发放套餐（赠送）" width="520px">
    <el-form label-width="90px">
      <el-form-item label="邮箱">
        <el-input v-model="grantForm.email" placeholder="用户邮箱" />
      </el-form-item>
      <el-form-item label="套餐">
        <el-select v-model="grantForm.plan_code" placeholder="选择套餐" style="width:100%">
          <el-option
            v-for="code in planOptions"
            :key="code"
            :value="code"
            :label="planConfigs[code]?.sale_type ? `${code}（${planConfigs[code].sale_type}）` : code"
          />
        </el-select>
      </el-form-item>
      <el-form-item label="生效开始">
        <el-date-picker v-model="grantForm.start" type="datetime" placeholder="留空 = 立即生效" style="width:100%" value-format="YYYY-MM-DDTHH:mm:ss[Z]" />
      </el-form-item>
      <el-form-item label="到期">
        <el-date-picker v-model="grantForm.end" type="datetime" placeholder="留空 = 按套餐有效期" style="width:100%" value-format="YYYY-MM-DDTHH:mm:ss[Z]" />
      </el-form-item>
      <el-form-item label="备注">
        <el-input v-model="grantForm.reason" placeholder="发放原因（可选）" />
      </el-form-item>
    </el-form>
    <div style="font-size:12px;color:var(--text-muted);line-height:1.6">
      赠送套餐不产生支付订单、不自动续费；对同一套餐重复发放将从当前到期时间延长。内部套餐仅能通过此处发放。
    </div>
    <template #footer>
      <el-button @click="grantVisible=false">取消</el-button>
      <el-button type="primary" @click="submitGrant">确认发放</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.detail-info { font-size: 13px; color: var(--text-muted); line-height: 1.8; }
.detail-info p { margin: 4px 0; }
</style>
