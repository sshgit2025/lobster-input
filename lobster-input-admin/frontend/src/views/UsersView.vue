<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { UserFilled } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface PlanConfig { paid?: boolean; sort_order?: number; rank?: number }
interface UserRow {
  email: string; plan_code?: string; is_active: boolean; reg_ip?: string
  invited_by?: string; created_at: string
}
interface CreditGrant {
  credit_type: string; source?: string; amount_total?: number
  amount_used?: number; amount_remaining?: number; expires_at?: string
}
interface CreditsData {
  email: string; plan_code: string; credits_total: number; credits_used: number
  bonus_credits_remaining?: number; paid_topup_credits_remaining?: number
  credits_remaining: number; credits_reset_note?: string; credits_reset_at?: string
  subscription_expires_at?: string; pending_plan_code?: string; pending_effective_at?: string
  credit_grants?: CreditGrant[]
}

const filters = ref({ email: '', ip: '', device: '', plan: '', active: '' })
const users = ref<UserRow[]>([])
const page = ref(1)
const total = ref(0)
const planConfigs = ref<Record<string, PlanConfig>>({})
const planOptions = ref<string[]>([])

const creditsVisible = ref(false)
const creditsData = ref<CreditsData | null>(null)

const grantVisible = ref(false)
const grantForm = ref({ email: '', amount: '', reason: '', expires: '', followSubscription: false })
const grantCanFollow = ref(false)
const grantSubExpires = ref<string | null>(null)
const grantHint = ref('输入或选择用户后，可对试用/付费套餐用户勾选随套餐失效。免费套餐必须手动设置有效期。')

function defaultGrantDate(): string {
  const d = new Date()
  d.setFullYear(d.getFullYear() + 1)
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${d.getFullYear()}-${m}-${day}`
}

function planCanFollow(data: CreditsData): boolean {
  return !!(data.plan_code && data.plan_code !== 'free' && data.subscription_expires_at
    && new Date(data.subscription_expires_at).getTime() > Date.now())
}

async function loadPlanFilter() {
  const data = await api<{ plan_configs?: Record<string, PlanConfig> }>('GET', '/api/v1/plans/config')
  planConfigs.value = data.plan_configs || {}
  planOptions.value = Object.keys(planConfigs.value).sort((a, b) => {
    const pa = planConfigs.value[a] || {}
    const pb = planConfigs.value[b] || {}
    return (parseInt(String(pa.sort_order)) || 0) - (parseInt(String(pb.sort_order)) || 0)
      || (parseInt(String(pa.rank)) || 0) - (parseInt(String(pb.rank)) || 0)
      || a.localeCompare(b)
  })
}

async function loadUsers(p = 1) {
  page.value = p
  const params = new URLSearchParams({ page: String(p), page_size: '20' })
  const f = filters.value
  if (f.email.trim()) params.set('email', f.email.trim())
  if (f.ip.trim()) params.set('ip', f.ip.trim())
  if (f.device.trim()) params.set('device_id', f.device.trim())
  if (f.plan) params.set('plan_code', f.plan)
  if (f.active !== '') params.set('is_active', f.active)
  try {
    const data = await api<{ items: UserRow[]; total: number }>('GET', `/api/v1/users?${params}`)
    users.value = data.items
    total.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function resetFilter() {
  filters.value = { email: '', ip: '', device: '', plan: '', active: '' }
  loadUsers(1)
}

async function doBan(email: string) {
  try {
    await ElMessageBox.confirm(`确认禁用用户 ${email}？`, '确认')
    await api('POST', '/api/v1/users/ban', { email })
    showToast('已禁用')
    loadUsers(page.value)
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? e.message : '操作失败', 'error')
  }
}

async function doUnban(email: string) {
  try {
    await api('POST', '/api/v1/users/unban', { email })
    showToast('已解封')
    loadUsers(page.value)
  } catch (e) {
    showToast(e instanceof Error ? e.message : '操作失败', 'error')
  }
}

async function openCreditsModal(email: string) {
  try {
    creditsData.value = await api<CreditsData>('POST', '/api/v1/users/credits', { email })
    creditsVisible.value = true
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function openGrantModal(email = '') {
  grantForm.value = { email, amount: '', reason: '', expires: defaultGrantDate(), followSubscription: false }
  grantCanFollow.value = false
  grantSubExpires.value = null
  grantHint.value = '输入或选择用户后，可对试用/付费套餐用户勾选随套餐失效。免费套餐必须手动设置有效期。'
  grantVisible.value = true
  if (email) loadGrantExpiryContext(email)
}

async function loadGrantExpiryContext(email: string) {
  try {
    const data = await api<CreditsData>('POST', '/api/v1/users/credits', { email })
    grantCanFollow.value = planCanFollow(data)
    grantSubExpires.value = data.subscription_expires_at || null
    if (!grantCanFollow.value && grantForm.value.followSubscription) grantForm.value.followSubscription = false
    if (grantCanFollow.value) {
      grantHint.value = `当前 ${data.plan_code} 套餐可选择随套餐失效，当前订阅到期：${fmtTime(data.subscription_expires_at)}`
    } else {
      grantHint.value = '当前用户没有有效的试用/付费套餐，赠送积分只能手动设置有效期。'
    }
    syncGrantExpiry()
  } catch (e) {
    grantCanFollow.value = false
    grantSubExpires.value = null
    grantForm.value.followSubscription = false
    grantHint.value = e instanceof Error ? e.message : '加载失败'
  }
}

function syncGrantExpiry() {
  const follow = grantForm.value.followSubscription && grantCanFollow.value
  if (follow && grantSubExpires.value) {
    const d = new Date(grantSubExpires.value)
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    grantForm.value.expires = `${yyyy}-${mm}-${dd}`
    grantHint.value = `赠送积分将绑定订阅生命周期，当前有效期参考：${fmtTime(grantSubExpires.value)}`
  }
}

async function doGrantCredits() {
  const { email, amount, reason, expires, followSubscription } = grantForm.value
  const follow = followSubscription && grantCanFollow.value
  if (!email.trim()) return showToast('请输入邮箱', 'error')
  const amt = parseInt(amount)
  if (!amt || amt <= 0) return showToast('积分数量必须大于0', 'error')
  if (!reason.trim()) return showToast('请填写赠送原因', 'error')
  if (!follow && !expires) return showToast('请选择有效期', 'error')
  try {
    const body: Record<string, unknown> = { email: email.trim(), amount: amt, reason: reason.trim(), expires_at_mode: follow ? 'subscription' : 'manual' }
    if (!follow) body.expires_at = new Date(`${expires}T23:59:59+08:00`).toISOString()
    const d = await api<{ message: string }>('POST', '/api/v1/users/grant-credits', body)
    showToast(d.message)
    grantVisible.value = false
    loadUsers(page.value)
  } catch (e) {
    showToast(e instanceof Error ? e.message : '赠送失败', 'error')
  }
}

onMounted(() => loadPlanFilter().finally(() => loadUsers(1)))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">用户管理</div>
      <div class="page-subtitle">检索全平台注册用户,查看套餐与积分明细,执行封禁/解封及人工赠送积分等运营操作。</div>
    </div>
    <div class="ph-actions">
      <el-button type="warning" @click="openGrantModal()">赠送积分</el-button>
    </div>
  </div>
  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="邮箱搜索" style="max-width:220px" clearable />
      <el-input v-model="filters.ip" placeholder="IP 搜索" style="max-width:160px" clearable />
      <el-input v-model="filters.device" placeholder="设备ID" style="max-width:200px" clearable />
      <el-select v-model="filters.plan" placeholder="全部套餐" style="max-width:120px" clearable>
        <el-option label="全部套餐" value="" />
        <el-option v-for="code in planOptions" :key="code" :label="code" :value="code" />
      </el-select>
      <el-select v-model="filters.active" placeholder="全部状态" style="max-width:120px" clearable>
        <el-option label="全部状态" value="" />
        <el-option label="正常" value="true" />
        <el-option label="已禁用" value="false" />
      </el-select>
      <el-button type="primary" @click="loadUsers(1)">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
    </div>

    <div v-if="!users.length" class="empty-state">
      <div class="empty-icon"><el-icon><UserFilled /></el-icon></div>
      <div class="empty-title">暂无用户</div>
      <div class="empty-hint">调整邮箱、IP、设备或套餐筛选条件后重试。</div>
    </div>
    <el-table v-else :data="users" stripe>
      <el-table-column prop="email" label="邮箱" min-width="180" />
      <el-table-column label="套餐" width="100">
        <template #default="{ row }">
          <el-tag :type="planConfigs[row.plan_code || '']?.paid ? 'warning' : 'info'" size="small">{{ row.plan_code || '-' }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="状态" width="80">
        <template #default="{ row }">
          <el-tag :type="row.is_active ? 'success' : 'danger'" size="small">{{ row.is_active ? '正常' : '禁用' }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="reg_ip" label="注册IP" width="120"><template #default="{ row }">{{ row.reg_ip || '-' }}</template></el-table-column>
      <el-table-column prop="invited_by" label="邀请人" width="140"><template #default="{ row }">{{ row.invited_by || '-' }}</template></el-table-column>
      <el-table-column label="注册时间" width="170"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
      <el-table-column label="操作" width="220" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="openCreditsModal(row.email)">积分</el-button>
          <el-button size="small" type="warning" @click="openGrantModal(row.email)">赠送</el-button>
          <el-button v-if="row.is_active" size="small" type="danger" @click="doBan(row.email)">禁用</el-button>
          <el-button v-else size="small" type="primary" @click="doUnban(row.email)">解封</el-button>
        </template>
      </el-table-column>
    </el-table>

    <div class="pager-row">
      <el-pagination
        v-model:current-page="page"
        :page-size="20"
        :total="total"
        layout="total, prev, pager, next"
        @current-change="loadUsers"
      />
    </div>
  </div>

  <el-dialog v-model="creditsVisible" title="积分详情" width="720px">
    <template v-if="creditsData">
      <el-form label-width="130px">
        <el-row :gutter="16">
          <el-col :span="12"><el-form-item label="邮箱"><el-input :model-value="creditsData.email" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="套餐"><el-input :model-value="creditsData.plan_code" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="总积分"><el-input :model-value="String(creditsData.credits_total)" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="已使用"><el-input :model-value="String(creditsData.credits_used)" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="奖励积分剩余"><el-input :model-value="String(creditsData.bonus_credits_remaining || 0)" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="付费加购积分剩余"><el-input :model-value="String(creditsData.paid_topup_credits_remaining || 0)" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="剩余"><el-input :model-value="String(creditsData.credits_remaining)" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="下次重置"><el-input :model-value="creditsData.credits_reset_note || (creditsData.credits_reset_at ? fmtTime(creditsData.credits_reset_at) : '-')" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="订阅到期"><el-input :model-value="creditsData.subscription_expires_at ? fmtTime(creditsData.subscription_expires_at) : '永久/无'" readonly /></el-form-item></el-col>
          <el-col :span="12"><el-form-item label="待生效套餐"><el-input :model-value="creditsData.pending_plan_code ? `${creditsData.pending_plan_code} @ ${fmtTime(creditsData.pending_effective_at)}` : '-'" readonly /></el-form-item></el-col>
        </el-row>
      </el-form>
      <div class="card-title" style="margin-top:14px">非套餐积分批次</div>
      <el-table :data="creditsData.credit_grants || []" stripe size="small">
        <el-table-column label="类型"><template #default="{ row }">{{ row.credit_type === 'paid_topup' ? '付费加购' : '奖励' }}</template></el-table-column>
        <el-table-column prop="source" label="来源"><template #default="{ row }">{{ row.source || '-' }}</template></el-table-column>
        <el-table-column prop="amount_total" label="总量" />
        <el-table-column prop="amount_used" label="已用" />
        <el-table-column prop="amount_remaining" label="剩余" />
        <el-table-column label="有效期"><template #default="{ row }">{{ row.expires_at ? fmtTime(row.expires_at) : '永久有效' }}</template></el-table-column>
      </el-table>
    </template>
  </el-dialog>

  <el-dialog v-model="grantVisible" title="赠送积分" width="480px">
    <el-form label-width="80px">
      <el-form-item label="邮箱">
        <el-input v-model="grantForm.email" placeholder="用户邮箱" @blur="grantForm.email.trim() && loadGrantExpiryContext(grantForm.email.trim())" />
      </el-form-item>
      <el-form-item label="数量">
        <el-input v-model="grantForm.amount" type="number" :min="1" placeholder="赠送积分数量" />
      </el-form-item>
      <el-form-item label="原因">
        <el-input v-model="grantForm.reason" placeholder="赠送原因（必填）" />
      </el-form-item>
      <el-form-item>
        <el-checkbox v-model="grantForm.followSubscription" :disabled="!grantCanFollow" @change="syncGrantExpiry">随套餐失效</el-checkbox>
      </el-form-item>
      <el-form-item label="有效期至">
        <el-date-picker v-model="grantForm.expires" type="date" value-format="YYYY-MM-DD" :disabled="grantForm.followSubscription && grantCanFollow" style="width:100%" />
      </el-form-item>
      <div style="font-size:12px;color:var(--text-muted);line-height:1.6">{{ grantHint }}</div>
    </el-form>
    <template #footer>
      <el-button @click="grantVisible = false">取消</el-button>
      <el-button type="primary" @click="doGrantCredits">确认赠送</el-button>
    </template>
  </el-dialog>
</template>
