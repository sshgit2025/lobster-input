<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { api } from '@/api'
import { fmtNum } from '@/utils/format'
import { Histogram, Lightning, Message, Calendar } from '@element-plus/icons-vue'
import { CHART_COLORS, destroyChart, mkDoughnutChart, mkLineChart } from '@/utils/chart'
import type { Chart } from 'chart.js/auto'

interface BreakdownItem {
  platform: string
  credits: number
  input_tokens?: number
  output_tokens?: number
  audio_duration_sec?: number
  audio_chars?: number
  search_count?: number
}

interface LedgerItem {
  user_email: string
  date: string
  operation: string
  client_platform?: string
  total_credits: number
  breakdown?: BreakdownItem[]
}

interface TopUser {
  email: string
  total_credits: number
  record_count: number
}

const activeTab = ref<'overview' | 'detail'>('overview')
const fEmail = ref('')
const fOperation = ref('')
const fClientPlatform = ref('')
const fDateFrom = ref('')
const fDateTo = ref('')
const summaryCredits = ref('-')
const summaryRecords = ref('-')
const topUsers = ref<TopUser[]>([])
const ledgerItems = ref<LedgerItem[]>([])
const currentPage = ref(1)
const totalRecords = ref(0)
const pageSize = 20
const bdModalVisible = ref(false)
const bdItem = ref<LedgerItem | null>(null)

const chartDailyRef = ref<HTMLCanvasElement | null>(null)
const chartPlatformRef = ref<HTMLCanvasElement | null>(null)
let dailyChart: Chart | null = null
let platformChart: Chart | null = null

const hasFilter = computed(() =>
  !!(fEmail.value.trim() || fOperation.value || fClientPlatform.value || fDateFrom.value || fDateTo.value),
)

const totalPages = computed(() => Math.ceil(totalRecords.value / pageSize))

const PLATFORM_COLORS: Record<string, string> = {
  groq_whisper: '#f97316',
  openai_whisper: '#3b82f6',
  openai_llm: '#8b5cf6',
  anthropic_llm: '#ec4899',
  deepseek_llm: '#14b8a6',
  groq_llm: '#f59e0b',
  default: '#6b7280',
}

const OP_COLORS: Record<string, string> = {
  transcribe: '#3b82f6',
  rewrite: '#8b5cf6',
  agent: '#f59e0b',
}

function getFilterParams(): URLSearchParams {
  const p = new URLSearchParams()
  if (fEmail.value.trim()) p.set('user_email', fEmail.value.trim())
  if (fOperation.value) p.set('operation', fOperation.value)
  if (fClientPlatform.value) p.set('client_platform', fClientPlatform.value)
  if (fDateFrom.value) p.set('date_from', fDateFrom.value)
  if (fDateTo.value) p.set('date_to', fDateTo.value)
  return p
}

function resetFilter() {
  fEmail.value = ''
  fOperation.value = ''
  fClientPlatform.value = ''
  fDateFrom.value = ''
  fDateTo.value = ''
  applyFilter()
}

function applyFilter() {
  currentPage.value = 1
  loadSummary()
  loadCharts()
  loadLedger()
}

function openBd(item: LedgerItem) {
  bdItem.value = item
  bdModalVisible.value = true
}

function platformAbbr(platform: string): string {
  return platform.split('_').map((w) => w[0].toUpperCase()).join('')
}

async function loadSummary() {
  const p = getFilterParams()
  try {
    const data = await api<{ total_credits: number; total_records: number }>('GET', `/api/v1/ledger/summary?${p}`)
    summaryCredits.value = fmtNum(data.total_credits)
    summaryRecords.value = fmtNum(data.total_records)
  } catch (e) {
    console.error('loadSummary', e)
  }
}

async function loadCharts() {
  const p = getFilterParams()
  try {
    const [daily, platform, top] = await Promise.all([
      api<{ date: string; total_credits: number }[]>('GET', '/api/v1/ledger/daily?days=30'),
      api<{ platform: string; total_credits: number }[]>('GET', `/api/v1/ledger/platform-breakdown?${p}`),
      api<TopUser[]>('GET', `/api/v1/ledger/top-users?limit=10&${p}`),
    ])

    const sorted = [...daily].sort((a, b) => (a.date > b.date ? 1 : -1))
    dailyChart = destroyChart(dailyChart)
    if (chartDailyRef.value) {
      dailyChart = mkLineChart(
        chartDailyRef.value,
        sorted.map((d) => d.date),
        sorted.map((d) => d.total_credits),
        '积分消耗',
      )
    }

    platformChart = destroyChart(platformChart)
    if (chartPlatformRef.value && platform.length > 0) {
      platformChart = mkDoughnutChart(
        chartPlatformRef.value,
        platform.map((d) => d.platform),
        platform.map((d) => d.total_credits),
      )
    }

    topUsers.value = top
  } catch (e) {
    console.error('loadCharts', e)
  }
}

async function loadLedger(page?: number) {
  if (page) currentPage.value = page
  const p = getFilterParams()
  p.set('page', String(currentPage.value))
  p.set('page_size', String(pageSize))
  try {
    const data = await api<{ items: LedgerItem[]; total: number; page: number; page_size: number }>('GET', `/api/v1/ledger?${p}`)
    ledgerItems.value = data.items || []
    totalRecords.value = data.total || 0
  } catch (e) {
    console.error('loadLedger', e)
  }
}

function onEscKey(e: KeyboardEvent) {
  if (e.key === 'Escape' && bdModalVisible.value) bdModalVisible.value = false
}

onMounted(() => {
  loadSummary()
  loadCharts()
  loadLedger()
  document.addEventListener('keydown', onEscKey)
})

onUnmounted(() => {
  document.removeEventListener('keydown', onEscKey)
  dailyChart = destroyChart(dailyChart)
  platformChart = destroyChart(platformChart)
})
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">积分账本</div>
      <div class="page-subtitle">按用户、操作、客户端与日期追踪积分消耗，下钻到每条记录的各平台扣费明细。</div>
    </div>
    <div class="ph-actions" />
  </div>

  <div class="card" style="margin-bottom:16px;padding:16px 20px">
    <div class="search-bar" style="margin-bottom:0">
      <input v-model="fEmail" class="form-input" placeholder="用户邮箱" style="max-width:220px">
      <select v-model="fOperation" class="form-select" style="max-width:150px">
        <option value="">全部操作</option>
        <option value="transcribe">transcribe</option>
        <option value="rewrite">rewrite</option>
        <option value="agent">agent</option>
      </select>
      <select v-model="fClientPlatform" class="form-select" style="max-width:170px">
        <option value="">全部客户端</option>
        <option value="macos">macos</option>
        <option value="windows">windows</option>
        <option value="ios">ios</option>
        <option value="android">android</option>
      </select>
      <input v-model="fDateFrom" class="form-input" type="date" style="max-width:148px">
      <span style="color:var(--text-muted);line-height:36px">至</span>
      <input v-model="fDateTo" class="form-input" type="date" style="max-width:148px">
      <el-button type="primary" @click="applyFilter">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
    </div>
    <div v-if="hasFilter" class="filter-tip"><el-icon><Lightning /></el-icon>当前为筛选结果，平台占比和 Top 用户已按条件过滤；趋势图为全量数据</div>
  </div>

  <div class="stat-grid" style="grid-template-columns:repeat(2,1fr);max-width:480px;margin-bottom:16px">
    <div class="stat-card">
      <div class="stat-label">总积分消耗</div>
      <div class="stat-value" style="color:var(--danger)">{{ summaryCredits }}</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">总记录数</div>
      <div class="stat-value primary">{{ summaryRecords }}</div>
    </div>
  </div>

  <el-tabs v-model="activeTab">
    <el-tab-pane label="仪表盘" name="overview">
      <div class="chart-grid">
        <div class="card">
          <div class="card-title">近30天积分消耗趋势</div>
          <div class="chart-wrap"><canvas ref="chartDailyRef" /></div>
        </div>
        <div class="card">
          <div class="card-title">各平台积分占比</div>
          <div class="chart-wrap"><canvas ref="chartPlatformRef" /></div>
        </div>
      </div>
      <div class="card">
        <div class="card-title">Top 10 用户（按积分消耗）</div>
        <div class="table-wrap">
          <table>
            <thead><tr><th>邮箱</th><th>总积分消耗</th><th>请求次数</th></tr></thead>
            <tbody>
              <tr v-if="topUsers.length === 0">
                <td colspan="3">
                  <div class="empty-state">
                    <div class="empty-icon"><el-icon><Histogram /></el-icon></div>
                    <div class="empty-title">暂无消耗数据</div>
                    <div class="empty-hint">当前筛选条件下还没有积分消耗记录。</div>
                  </div>
                </td>
              </tr>
              <tr v-for="(u, i) in topUsers" :key="u.email">
                <td>
                  <span
                    style="display:inline-block;width:20px;height:20px;border-radius:50%;color:#fff;font-size:11px;text-align:center;line-height:20px;margin-right:6px"
                    :style="{ background: CHART_COLORS[i % CHART_COLORS.length] }"
                  >{{ i + 1 }}</span>
                  {{ u.email }}
                </td>
                <td><strong style="color:var(--danger)">{{ fmtNum(u.total_credits) }}</strong></td>
                <td>{{ fmtNum(u.record_count) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </el-tab-pane>

    <el-tab-pane label="明细查询" name="detail">
      <div class="card">
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>邮箱</th><th>日期</th><th>操作</th><th>客户端</th><th>总积分</th>
                <th style="width:80px;text-align:center">明细</th>
              </tr>
            </thead>
            <tbody>
              <tr v-if="ledgerItems.length === 0">
                <td colspan="6">
                  <div class="empty-state">
                    <div class="empty-icon"><el-icon><Histogram /></el-icon></div>
                    <div class="empty-title">暂无账本记录</div>
                    <div class="empty-hint">调整筛选条件后重试。</div>
                  </div>
                </td>
              </tr>
              <tr v-for="item in ledgerItems" :key="`${item.user_email}-${item.date}-${item.operation}`">
                <td>{{ item.user_email }}</td>
                <td>{{ item.date }}</td>
                <td><span class="badge badge-info">{{ item.operation }}</span></td>
                <td><span style="font-size:12px;color:var(--text-muted)">{{ item.client_platform || '-' }}</span></td>
                <td><strong style="color:var(--danger);font-size:15px">{{ fmtNum(item.total_credits) }}</strong></td>
                <td style="text-align:center">
                  <el-button size="small" @click="openBd(item)">查看 {{ (item.breakdown || []).length }} 项</el-button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div v-if="totalPages > 1" class="pager-row">
          <span style="color:var(--text-muted);font-size:13px">共 {{ totalRecords }} 条</span>
          <el-button v-if="currentPage > 1" size="small" @click="loadLedger(currentPage - 1)">上一页</el-button>
          <span style="font-size:13px;color:var(--text-muted)">{{ currentPage }} / {{ totalPages }}</span>
          <el-button v-if="currentPage < totalPages" size="small" @click="loadLedger(currentPage + 1)">下一页</el-button>
        </div>
      </div>
    </el-tab-pane>
  </el-tabs>

  <el-dialog v-model="bdModalVisible" title="平台消耗明细" width="520px" destroy-on-close>
    <template v-if="bdItem">
      <div class="bd-meta">
        <span class="bd-meta-item"><el-icon><Message /></el-icon>{{ bdItem.user_email }}</span>
        <span class="bd-meta-item"><el-icon><Calendar /></el-icon>{{ bdItem.date }}</span>
        <span
          class="bd-op-badge"
          :style="{ background: (OP_COLORS[bdItem.operation] || '#6b7280') + '22', color: OP_COLORS[bdItem.operation] || '#6b7280', borderColor: (OP_COLORS[bdItem.operation] || '#6b7280') + '44' }"
        >{{ bdItem.operation }}</span>
        <span class="bd-platform-tag">{{ bdItem.client_platform || '-' }}</span>
        <span class="bd-total">共扣 {{ fmtNum(bdItem.total_credits) }} 积分</span>
      </div>
      <div v-if="!(bdItem.breakdown || []).length" style="color:var(--text-muted);text-align:center;padding:32px 0">暂无明细数据</div>
      <div v-for="b in bdItem.breakdown" :key="b.platform" class="bd-row">
        <div
          class="bd-icon"
          :style="{ background: (PLATFORM_COLORS[b.platform] || PLATFORM_COLORS.default) + '22', borderColor: (PLATFORM_COLORS[b.platform] || PLATFORM_COLORS.default) + '55' }"
        >
          <span :style="{ color: PLATFORM_COLORS[b.platform] || PLATFORM_COLORS.default }">{{ platformAbbr(b.platform) }}</span>
        </div>
        <div class="bd-info">
          <div class="bd-name">{{ b.platform }}</div>
          <div class="bd-credits-wrap">
            <span class="bd-credits">{{ fmtNum(b.credits) }}</span>
            <span class="bd-credits-unit">积分</span>
            <span style="font-size:11px;color:var(--text-muted);margin-left:6px">(占比 {{ bdItem.total_credits > 0 ? Math.round(b.credits / bdItem.total_credits * 100) : 0 }}%)</span>
          </div>
          <div v-if="b.input_tokens || b.output_tokens || b.audio_duration_sec || b.audio_chars || b.search_count" class="bd-tags">
            <span v-if="b.input_tokens" class="bd-tag">输入 {{ fmtNum(b.input_tokens) }} tokens</span>
            <span v-if="b.output_tokens" class="bd-tag">输出 {{ fmtNum(b.output_tokens) }} tokens</span>
            <span v-if="b.audio_duration_sec" class="bd-tag">音频 {{ b.audio_duration_sec.toFixed(1) }}s</span>
            <span v-if="b.audio_chars" class="bd-tag">识别 {{ fmtNum(b.audio_chars) }} 字符</span>
            <span v-if="b.search_count" class="bd-tag">搜索 {{ b.search_count }} 次</span>
          </div>
        </div>
        <div class="bd-pct-bar-wrap">
          <div class="bd-pct-bar">
            <div
              class="bd-pct-fill"
              :style="{
                width: (bdItem.total_credits > 0 ? Math.round(b.credits / bdItem.total_credits * 100) : 0) + '%',
                background: PLATFORM_COLORS[b.platform] || PLATFORM_COLORS.default,
              }"
            />
          </div>
        </div>
      </div>
    </template>
  </el-dialog>
</template>

<style scoped>
.bd-meta {
  padding: 12px 0;
  background: var(--bg);
  border-bottom: 1px solid var(--border);
  font-size: 12px;
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  margin-bottom: 12px;
}
.bd-meta-item {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  color: var(--text-muted);
}
.bd-op-badge {
  border: 1px solid;
  border-radius: 4px;
  padding: 1px 8px;
  font-size: 11px;
  font-weight: 600;
}
.bd-platform-tag {
  background: var(--border);
  color: var(--text-muted);
  border-radius: 4px;
  padding: 1px 8px;
  font-size: 11px;
}
.bd-total {
  margin-left: auto;
  color: var(--danger);
  font-weight: 700;
  font-size: 13px;
}
.bd-row {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 14px 0;
  border-bottom: 1px solid var(--border);
}
.bd-row:last-child { border-bottom: none; }
.bd-icon {
  width: 42px;
  height: 42px;
  border-radius: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  border: 1.5px solid;
}
.bd-info { flex: 1; min-width: 0; }
.bd-name { font-size: 13px; font-weight: 600; margin-bottom: 3px; }
.bd-credits-wrap { display: flex; align-items: baseline; gap: 4px; }
.bd-credits { color: var(--danger); font-size: 22px; font-weight: 800; line-height: 1; }
.bd-credits-unit { font-size: 12px; color: var(--text-muted); }
.bd-tags { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 7px; }
.bd-tag {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: 5px;
  padding: 2px 8px;
  font-size: 11px;
  color: var(--text-muted);
}
.bd-pct-bar-wrap {
  flex-shrink: 0;
  width: 52px;
}
.bd-pct-bar {
  height: 4px;
  background: var(--border);
  border-radius: 2px;
  overflow: hidden;
}
.bd-pct-fill {
  height: 100%;
  border-radius: 2px;
  transition: width 0.4s;
}
</style>
