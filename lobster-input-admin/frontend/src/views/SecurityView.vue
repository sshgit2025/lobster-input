<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { Filter, RefreshLeft, View, Unlock, Close, CircleCheck } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface IdentityRow {
  id: string; identity_type: string; identity_value: string; status: string
  reasons?: string[]; risk_score?: number; blocked_until?: string
  limited_until?: string; last_seen_at?: string
}
interface IdentityDetail extends IdentityRow {
  user_email?: string; user_emails?: string[]; ips?: string[]
  last_user_agent?: string; events?: SecurityEvent[]
}
interface SecurityEvent {
  created_at: string; user_email?: string; ip?: string; reason_code?: string
  action?: string; method?: string; path?: string; request_count?: number
  window_seconds?: number; user_agent?: string
}

const STATUS_LABEL: Record<string, string> = { normal: '正常', limited: '限制中', blocked: '封禁中' }
const ACTION_LABEL: Record<string, string> = { observe: '观察', limited: '限制', blocked: '封禁', manual_clear: '手动解除' }
const REASON_LABEL: Record<string, string> = {
  IP_RATE_LIMIT: 'IP 高频请求', ACCOUNT_RATE_LIMIT: '账号高频请求',
  HIGH_COST_AUDIO_ABUSE: '音频接口滥用', HOTWORD_WRITE_ABUSE: '词典写入滥用',
  AUTH_RATE_LIMIT: '认证接口高频访问', AUTH_ABUSE: '认证异常',
  PROBING_OR_SCAN: '探测扫描', MULTI_IP_ACCOUNT_ABUSE: '多 IP 账号攻击',
}

const filters = ref({ email: '', ip: '', status: 'active', reason: '' })
const identities = ref<IdentityRow[]>([])
const page = ref(1)
const total = ref(0)
const detailVisible = ref(false)
const detail = ref<IdentityDetail | null>(null)

function statusType(status: string): '' | 'success' | 'warning' | 'danger' | 'info' {
  if (status === 'normal') return 'success'
  if (status === 'limited') return 'warning'
  if (status === 'blocked') return 'danger'
  return 'info'
}

function reasonLabel(code: string): string {
  return REASON_LABEL[code] || code
}

async function loadIdentities(p = 1) {
  page.value = p
  const params = new URLSearchParams({ page: String(p), page_size: '20' })
  const f = filters.value
  if (f.email.trim()) params.set('email', f.email.trim())
  if (f.ip.trim()) params.set('ip', f.ip.trim())
  if (f.status) params.set('status', f.status)
  if (f.reason) params.set('reason', f.reason)
  try {
    const data = await api<{ items: IdentityRow[]; total: number }>('GET', `/api/v1/security/identities?${params}`)
    identities.value = data.items || []
    total.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function resetFilter() {
  filters.value = { email: '', ip: '', status: 'active', reason: '' }
  detailVisible.value = false
  detail.value = null
  loadIdentities(1)
}

async function showDetail(id: string) {
  try {
    detail.value = await api<IdentityDetail>('GET', `/api/v1/security/identities/${id}`)
    detailVisible.value = true
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function closeDetail() {
  detailVisible.value = false
  detail.value = null
}

async function clearIdentity(id: string) {
  try {
    await ElMessageBox.confirm('确认解除该对象的限制/封禁？', '确认')
    await api('POST', `/api/v1/security/identities/${id}/clear`)
    showToast('已解除限制')
    closeDetail()
    loadIdentities(page.value)
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? e.message : '操作失败', 'error')
  }
}

onMounted(() => loadIdentities(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">安全风控</div>
      <div class="page-subtitle">监控触发风控的账号与 IP，按风险原因排查滥用行为，必要时解除限制或封禁。</div>
    </div>
  </div>
  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="账号邮箱" style="max-width:220px" clearable />
      <el-input v-model="filters.ip" placeholder="IP" style="max-width:160px" clearable />
      <el-select v-model="filters.status" style="max-width:150px">
        <el-option label="仅风险中" value="active" />
        <el-option label="限制中" value="limited" />
        <el-option label="封禁中" value="blocked" />
        <el-option label="全部" value="" />
        <el-option label="正常" value="normal" />
      </el-select>
      <el-select v-model="filters.reason" placeholder="全部原因" style="max-width:190px" clearable>
        <el-option label="全部原因" value="" />
        <el-option label="IP 高频请求" value="IP_RATE_LIMIT" />
        <el-option label="账号高频请求" value="ACCOUNT_RATE_LIMIT" />
        <el-option label="音频接口滥用" value="HIGH_COST_AUDIO_ABUSE" />
        <el-option label="词典写入滥用" value="HOTWORD_WRITE_ABUSE" />
        <el-option label="认证异常" value="AUTH_ABUSE" />
        <el-option label="探测扫描" value="PROBING_OR_SCAN" />
        <el-option label="多 IP 账号攻击" value="MULTI_IP_ACCOUNT_ABUSE" />
      </el-select>
      <el-button type="primary" @click="loadIdentities(1)"><el-icon><Filter /></el-icon>筛选</el-button>
      <el-button @click="resetFilter"><el-icon><RefreshLeft /></el-icon>重置</el-button>
    </div>

    <el-table :data="identities" stripe>
      <el-table-column label="风险对象" min-width="180">
        <template #default="{ row }">
          <b>{{ row.identity_type === 'account' ? '账号' : 'IP' }}</b><br>
          <span class="muted">{{ row.identity_value }}</span>
        </template>
      </el-table-column>
      <el-table-column label="状态" width="90">
        <template #default="{ row }">
          <el-tag :type="statusType(row.status)" size="small">{{ STATUS_LABEL[row.status] || row.status || '-' }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="风险原因" min-width="160">
        <template #default="{ row }">
          <el-tag v-for="r in (row.reasons || []).slice(0, 3)" :key="r" type="warning" size="small" style="margin:1px">{{ reasonLabel(r) }}</el-tag>
          <span v-if="!(row.reasons || []).length">-</span>
        </template>
      </el-table-column>
      <el-table-column label="风险分" width="80"><template #default="{ row }">{{ row.risk_score || 0 }}</template></el-table-column>
      <el-table-column label="限制到期" width="170"><template #default="{ row }"><span class="muted">{{ fmtTime(row.blocked_until || row.limited_until) }}</span></template></el-table-column>
      <el-table-column label="最近命中" width="170"><template #default="{ row }"><span class="muted">{{ fmtTime(row.last_seen_at) }}</span></template></el-table-column>
      <el-table-column label="操作" width="150" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="showDetail(row.id)"><el-icon><View /></el-icon>详情</el-button>
          <el-button v-if="row.status !== 'normal'" size="small" type="primary" @click="clearIdentity(row.id)"><el-icon><Unlock /></el-icon>解除</el-button>
        </template>
      </el-table-column>
      <template #empty>
        <div class="empty-state">
          <div class="empty-icon"><el-icon><CircleCheck /></el-icon></div>
          <div class="empty-title">未发现风险对象</div>
          <div class="empty-hint">当前筛选条件下没有触发风控的账号或 IP</div>
        </div>
      </template>
    </el-table>

    <el-pagination
      v-model:current-page="page"
      :page-size="20"
      :total="total"
      layout="total, prev, pager, next"
      style="margin-top:16px;justify-content:flex-end"
      @current-change="loadIdentities"
    />
  </div>

  <div v-if="detailVisible && detail" class="card detail-card" style="margin-top:16px">
    <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
      <div>
        <div class="card-title">{{ detail.identity_type === 'account' ? '账号' : 'IP' }}风险详情</div>
        <div class="muted">{{ detail.identity_value }}</div>
      </div>
      <el-button size="small" @click="closeDetail"><el-icon><Close /></el-icon>关闭</el-button>
    </div>
    <div class="detail-grid">
      <div><span>状态</span><b>{{ STATUS_LABEL[detail.status] || detail.status || '-' }}</b></div>
      <div><span>风险分</span><b>{{ detail.risk_score || 0 }}</b></div>
      <div><span>账号</span><b>{{ detail.user_email || (detail.user_emails || []).join(', ') || '-' }}</b></div>
      <div><span>IP</span><b>{{ (detail.ips || []).join(', ') || detail.identity_value || '-' }}</b></div>
      <div><span>原因</span><b>{{ (detail.reasons || []).map(r => reasonLabel(r)).join(' / ') || '-' }}</b></div>
      <div><span>User-Agent</span><b>{{ detail.last_user_agent || '-' }}</b></div>
    </div>
    <el-table :data="detail.events || []" stripe size="small" style="margin-top:14px">
      <el-table-column label="时间" width="170"><template #default="{ row }"><span class="muted">{{ fmtTime(row.created_at) }}</span></template></el-table-column>
      <el-table-column prop="user_email" label="账号" width="140"><template #default="{ row }">{{ row.user_email || '-' }}</template></el-table-column>
      <el-table-column prop="ip" label="IP" width="120"><template #default="{ row }">{{ row.ip || '-' }}</template></el-table-column>
      <el-table-column label="原因" width="140"><template #default="{ row }">{{ reasonLabel(row.reason_code || '') || '-' }}</template></el-table-column>
      <el-table-column label="动作" width="80">
        <template #default="{ row }">
          <el-tag :type="row.action === 'blocked' ? 'danger' : 'warning'" size="small">{{ ACTION_LABEL[row.action || ''] || row.action }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="请求" min-width="160"><template #default="{ row }"><span class="muted">{{ row.method }} {{ row.path }}</span></template></el-table-column>
      <el-table-column label="次数/窗口" width="100"><template #default="{ row }">{{ row.request_count || 0 }}/{{ row.window_seconds || 0 }}s</template></el-table-column>
      <el-table-column label="User-Agent" min-width="180"><template #default="{ row }"><span class="muted">{{ (row.user_agent || '').slice(0, 120) }}</span></template></el-table-column>
    </el-table>
  </div>
</template>

<style scoped>
.muted { color: var(--text-muted); font-size: 12px; }
.detail-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 10px; }
.detail-grid div { border: 1px solid var(--border); border-radius: 8px; padding: 10px; background: rgba(255,255,255,.02); }
.detail-grid span { display: block; color: var(--text-muted); font-size: 12px; margin-bottom: 4px; }
.detail-grid b { font-size: 13px; word-break: break-all; }
</style>
