<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { Coin } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtNum } from '@/utils/format'

interface RewardRow {
  user_email: string; date: string; operation: string
  total_credits: number; remark?: string; admin_email?: string
}

const OP_CONFIG: Record<string, { label: string; color: string }> = {
  admin_grant: { label: '管理员赠送', color: '#3b82f6' },
  registration_reward: { label: '注册积分奖励', color: '#22c55e' },
  invite_reward: { label: '邀请码注册奖励', color: '#f59e0b' },
}

const filters = ref({ email: '', operation: '', dateFrom: '', dateTo: '' })
const summary = ref({ adminGrant: '-', regReward: '-', inviteReward: '-' })
const items = ref<RewardRow[]>([])
const page = ref(1)
const total = ref(0)

function buildFilterParams(): URLSearchParams {
  const p = new URLSearchParams()
  const f = filters.value
  if (f.email.trim()) p.set('user_email', f.email.trim())
  if (f.operation) p.set('operation', f.operation)
  if (f.dateFrom) p.set('date_from', f.dateFrom)
  if (f.dateTo) p.set('date_to', f.dateTo)
  return p
}

function resetFilter() {
  filters.value = { email: '', operation: '', dateFrom: '', dateTo: '' }
  applyFilter()
}

function applyFilter() {
  page.value = 1
  loadSummary()
  loadRewards()
}

async function loadSummary() {
  const ops = ['admin_grant', 'registration_reward', 'invite_reward'] as const
  const keys = ['adminGrant', 'regReward', 'inviteReward'] as const
  const base = buildFilterParams()
  await Promise.all(ops.map(async (op, i) => {
    try {
      const p = new URLSearchParams(base)
      p.set('operation', op)
      p.set('client_platform', 'system')
      const data = await api<{ total_credits: number }>('GET', `/api/v1/ledger/summary?${p}`)
      summary.value[keys[i]] = fmtNum(data.total_credits)
    } catch {
      summary.value[keys[i]] = '0'
    }
  }))
}

async function loadRewards(p?: number) {
  if (p) page.value = p
  const params = buildFilterParams()
  params.set('client_platform', 'system')
  params.set('page', String(page.value))
  params.set('page_size', '20')
  try {
    const data = await api<{ items: RewardRow[]; total: number }>('GET', `/api/v1/ledger?${params}`)
    items.value = data.items || []
    total.value = data.total
  } catch (e) {
    console.error('loadRewards', e)
    items.value = []
    total.value = 0
  }
}

function opLabel(op: string): { label: string; color: string } {
  return OP_CONFIG[op] || { label: op, color: '#6b7280' }
}

onMounted(() => { loadSummary(); loadRewards() })
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">积分奖励明细</div>
      <div class="page-subtitle">汇总并查询管理员赠送、注册及邀请等系统侧积分发放流水,支持按用户、类型与日期检索。</div>
    </div>
  </div>

  <div class="card" style="margin-bottom:16px;padding:16px 20px">
    <div class="search-bar" style="margin-bottom:0;flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="用户邮箱" style="max-width:220px" clearable />
      <el-select v-model="filters.operation" placeholder="全部奖励类型" style="max-width:180px" clearable>
        <el-option label="全部奖励类型" value="" />
        <el-option label="管理员赠送" value="admin_grant" />
        <el-option label="注册积分奖励" value="registration_reward" />
        <el-option label="邀请码注册奖励" value="invite_reward" />
      </el-select>
      <el-date-picker v-model="filters.dateFrom" type="date" placeholder="开始日期" value-format="YYYY-MM-DD" style="max-width:148px" />
      <span style="color:var(--text-muted);line-height:32px">至</span>
      <el-date-picker v-model="filters.dateTo" type="date" placeholder="结束日期" value-format="YYYY-MM-DD" style="max-width:148px" />
      <el-button type="primary" @click="applyFilter">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
    </div>
  </div>

  <div class="stat-grid" style="grid-template-columns:repeat(3,1fr);max-width:640px;margin-bottom:16px">
    <div class="stat-card">
      <div class="stat-label">管理员赠送</div>
      <div class="stat-value" style="color:#3b82f6">{{ summary.adminGrant }}</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">注册积分奖励</div>
      <div class="stat-value" style="color:#22c55e">{{ summary.regReward }}</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">邀请码注册奖励</div>
      <div class="stat-value" style="color:#f59e0b">{{ summary.inviteReward }}</div>
    </div>
  </div>

  <div class="card">
    <div v-if="!items.length" class="empty-state">
      <div class="empty-icon"><el-icon><Coin /></el-icon></div>
      <div class="empty-title">暂无奖励记录</div>
      <div class="empty-hint">调整用户、奖励类型或日期范围后重试。</div>
    </div>
    <el-table v-else :data="items" stripe>
      <el-table-column prop="user_email" label="用户邮箱" min-width="180" />
      <el-table-column prop="date" label="日期" width="120" />
      <el-table-column label="奖励类型" width="150">
        <template #default="{ row }">
          <span class="reward-tag" :style="{ background: opLabel(row.operation).color + '22', color: opLabel(row.operation).color, borderColor: opLabel(row.operation).color + '44' }">
            {{ opLabel(row.operation).label }}
          </span>
        </template>
      </el-table-column>
      <el-table-column label="积分" width="100">
        <template #default="{ row }"><strong style="color:#22c55e;font-size:15px">+{{ fmtNum(row.total_credits) }}</strong></template>
      </el-table-column>
      <el-table-column prop="remark" label="备注" min-width="160"><template #default="{ row }"><span style="font-size:12px;color:var(--text-muted)">{{ row.remark || '-' }}</span></template></el-table-column>
      <el-table-column prop="admin_email" label="操作管理员" width="160"><template #default="{ row }"><span style="font-size:12px;color:var(--text-muted)">{{ row.admin_email || '-' }}</span></template></el-table-column>
    </el-table>
    <div class="pager-row">
      <el-pagination
        v-model:current-page="page"
        :page-size="20"
        :total="total"
        layout="total, prev, pager, next"
        @current-change="loadRewards"
      />
    </div>
  </div>
</template>

<style scoped>
.reward-tag {
  border: 1px solid;
  border-radius: 4px;
  padding: 2px 10px;
  font-size: 12px;
  font-weight: 600;
}
</style>
