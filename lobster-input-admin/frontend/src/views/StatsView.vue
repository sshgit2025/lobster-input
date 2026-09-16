<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { api } from '@/api'
import { fmtNum, fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'
import { Lightning, TrendCharts, Histogram, Key } from '@element-plus/icons-vue'
import { destroyChart, mkDoughnutChart, mkLineChart } from '@/utils/chart'
import type { Chart } from 'chart.js/auto'

const CLIENT_PLATFORM_LABEL: Record<string, string> = {
  macos: 'macOS', windows: 'Windows', android: 'Android', ios: 'iOS', '': '未知',
}

interface FilterForm {
  email: string
  platform: string
  operation: string
  dateFrom: string
  dateTo: string
  apikey: string
}

const filters = ref<FilterForm>({ email: '', platform: '', operation: '', dateFrom: '', dateTo: '', apikey: '' })
const activeTab = ref('overview')
const summary = ref({ req: '-', input: '-', output: '-', audio: '-', search: '-' })
const topUsers = ref<{ email: string; total_requests: number; total_tokens: number }[]>([])
const detailItems = ref<Record<string, unknown>[]>([])
const detailPage = ref(1)
const detailTotal = ref(0)
const apiKeyItems = ref<Record<string, unknown>[]>([])
const apiKeyTotalText = ref('')

const chartDaily = ref<HTMLCanvasElement | null>(null)
const chartPlatform = ref<HTMLCanvasElement | null>(null)
let dailyChart: Chart | null = null
let platformChart: Chart | null = null

const hasFilter = computed(() => {
  const f = filters.value
  return !!(f.email || f.platform || f.operation || f.dateFrom || f.dateTo || f.apikey)
})

function buildFilterParams(): URLSearchParams {
  const p = new URLSearchParams()
  const f = filters.value
  if (f.email) p.set('user_email', f.email.trim())
  if (f.platform) p.set('platform', f.platform)
  if (f.operation) p.set('operation', f.operation)
  if (f.dateFrom) p.set('date_from', f.dateFrom)
  if (f.dateTo) p.set('date_to', f.dateTo)
  if (f.apikey) p.set('api_key_hint', f.apikey.trim())
  return p
}

function clientLabel(platform?: string): string {
  return CLIENT_PLATFORM_LABEL[platform || ''] || platform || '-'
}

async function loadSummary() {
  try {
    const d = await api<{
      total_requests: number; total_input_tokens: number; total_output_tokens: number
      total_audio_sec?: number; total_search: number
    }>('GET', `/api/v1/stats/summary?${buildFilterParams()}`)
    summary.value = {
      req: fmtNum(d.total_requests),
      input: fmtNum(d.total_input_tokens),
      output: fmtNum(d.total_output_tokens),
      audio: fmtNum(Math.round(d.total_audio_sec || 0)),
      search: fmtNum(d.total_search),
    }
  } catch { /* ignore */ }
}

async function loadCharts() {
  try {
    const [daily, platform] = await Promise.all([
      api<{ date: string; request_count: number }[]>('GET', '/api/v1/stats/daily?days=30'),
      api<{ platform: string; count: number }[]>('GET', '/api/v1/stats/platform-distribution'),
    ])
    const sorted = [...daily].sort((a, b) => (a.date > b.date ? 1 : -1))
    dailyChart = destroyChart(dailyChart)
    platformChart = destroyChart(platformChart)
    if (chartDaily.value) dailyChart = mkLineChart(chartDaily.value, sorted.map((d) => d.date), sorted.map((d) => d.request_count), '请求数')
    if (chartPlatform.value) platformChart = mkDoughnutChart(chartPlatform.value, platform.map((d) => d.platform), platform.map((d) => d.count))
  } catch { /* ignore */ }
}

async function loadTopUsers() {
  try {
    topUsers.value = await api('GET', '/api/v1/stats/top-users?limit=10')
  } catch { topUsers.value = [] }
}

async function loadStats(page = 1) {
  detailPage.value = page
  const p = buildFilterParams()
  p.set('page', String(page))
  p.set('page_size', '20')
  try {
    const data = await api<{ items: Record<string, unknown>[]; total: number }>('GET', `/api/v1/stats?${p}`)
    detailItems.value = data.items
    detailTotal.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

async function loadApiKeys() {
  try {
    const data = await api<{
      api_key_hint?: string; user_count: number; total_requests: number
      total_input_tokens: number; total_output_tokens: number; total_audio_sec?: number
      total_search: number; total_latency_ms: number
    }[]>('GET', `/api/v1/stats/api-keys?${buildFilterParams()}`)
    apiKeyItems.value = data as unknown as Record<string, unknown>[]
    if (!data.length) {
      apiKeyTotalText.value = ''
      return
    }
    const totalReq = data.reduce((s, k) => s + k.total_requests, 0)
    const totalIn = data.reduce((s, k) => s + k.total_input_tokens, 0)
    const totalOut = data.reduce((s, k) => s + k.total_output_tokens, 0)
    apiKeyTotalText.value = `共 ${data.length} 个 API Key · 合计请求 ${fmtNum(totalReq)} · 输入 Token ${fmtNum(totalIn)} · 输出 Token ${fmtNum(totalOut)}`
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function applyFilter() {
  loadSummary()
  loadStats(1)
  loadApiKeys()
}

function resetFilter() {
  filters.value = { email: '', platform: '', operation: '', dateFrom: '', dateTo: '', apikey: '' }
  applyFilter()
}

function onTabChange(name: string | number) {
  if (name === 'apikeys') loadApiKeys()
}

function avgLatency(row: Record<string, unknown>): number {
  const req = Number(row.total_requests) || 0
  return req > 0 ? Math.round(Number(row.total_latency_ms) / req) : 0
}

onMounted(() => {
  loadSummary()
  loadCharts()
  loadTopUsers()
  loadStats(1)
})

onUnmounted(() => {
  dailyChart = destroyChart(dailyChart)
  platformChart = destroyChart(platformChart)
})

watch(activeTab, (v) => { if (v === 'apikeys') loadApiKeys() })
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">用量统计</div>
      <div class="page-subtitle">监控请求量、Token 与音频用量,支持按平台、操作、日期及 API Key 维度下钻分析。</div>
    </div>
    <div class="ph-actions" />
  </div>

  <div class="card" style="margin-bottom:16px;padding:16px 20px">
    <div class="search-bar" style="margin-bottom:0;flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="用户邮箱" style="max-width:220px" clearable />
      <el-select v-model="filters.platform" placeholder="全部平台" style="max-width:150px" clearable>
        <el-option label="全部平台" value="" />
        <el-option label="dashscope_asr" value="dashscope_asr" />
        <el-option label="aliyun_llm" value="aliyun_llm" />
        <el-option label="openai_llm" value="openai_llm" />
        <el-option label="groq_llm" value="groq_llm" />
        <el-option label="anthropic_llm" value="anthropic_llm" />
        <el-option label="deepseek_llm" value="deepseek_llm" />
        <el-option label="tavily" value="tavily" />
      </el-select>
      <el-select v-model="filters.operation" placeholder="全部操作" style="max-width:150px" clearable>
        <el-option label="全部操作" value="" />
        <el-option label="transcribe" value="transcribe" />
        <el-option label="rewrite" value="rewrite" />
        <el-option label="agent" value="agent" />
        <el-option label="search" value="search" />
      </el-select>
      <el-date-picker v-model="filters.dateFrom" type="date" placeholder="开始日期" value-format="YYYY-MM-DD" style="max-width:148px" />
      <span style="color:var(--text-muted);line-height:32px">至</span>
      <el-date-picker v-model="filters.dateTo" type="date" placeholder="结束日期" value-format="YYYY-MM-DD" style="max-width:148px" />
      <el-input v-model="filters.apikey" placeholder="API Key (脱敏)" style="max-width:180px" clearable />
      <el-button type="primary" @click="applyFilter">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
    </div>
    <div v-if="hasFilter" class="filter-tip">
      <el-icon><Lightning /></el-icon>当前为筛选结果，指标卡和明细均已按条件过滤
    </div>
  </div>

  <div class="stat-grid">
    <div class="stat-card"><div class="stat-label">总请求数</div><div class="stat-value primary">{{ summary.req }}</div></div>
    <div class="stat-card"><div class="stat-label">输入 Token</div><div class="stat-value info">{{ summary.input }}</div></div>
    <div class="stat-card"><div class="stat-label">输出 Token</div><div class="stat-value warning">{{ summary.output }}</div></div>
    <div class="stat-card"><div class="stat-label">音频时长(秒)</div><div class="stat-value success">{{ summary.audio }}</div></div>
    <div class="stat-card"><div class="stat-label">搜索次数</div><div class="stat-value">{{ summary.search }}</div></div>
  </div>

  <el-tabs v-model="activeTab" @tab-change="onTabChange">
    <el-tab-pane label="总览图表" name="overview">
      <div class="chart-grid">
        <div class="card"><div class="card-title">近30天请求趋势</div><div class="chart-wrap"><canvas ref="chartDaily" /></div></div>
        <div class="card"><div class="card-title">平台分布</div><div class="chart-wrap"><canvas ref="chartPlatform" /></div></div>
      </div>
      <div class="card">
        <div class="card-title">Top 10 用户（按请求数）</div>
        <el-table :data="topUsers" stripe>
          <template #empty>
            <div class="empty-state">
              <div class="empty-icon"><el-icon><TrendCharts /></el-icon></div>
              <div class="empty-title">暂无用户用量</div>
              <div class="empty-hint">还没有可统计的请求记录。</div>
            </div>
          </template>
          <el-table-column prop="email" label="邮箱" />
          <el-table-column label="总请求数"><template #default="{ row }">{{ fmtNum(row.total_requests) }}</template></el-table-column>
          <el-table-column label="总 Token"><template #default="{ row }">{{ fmtNum(row.total_tokens) }}</template></el-table-column>
        </el-table>
      </div>
    </el-tab-pane>

    <el-tab-pane label="明细查询" name="detail">
      <div class="card">
        <el-table :data="detailItems" stripe>
          <template #empty>
            <div class="empty-state">
              <div class="empty-icon"><el-icon><Histogram /></el-icon></div>
              <div class="empty-title">暂无用量明细</div>
              <div class="empty-hint">调整筛选条件后重试。</div>
            </div>
          </template>
          <el-table-column prop="user_email" label="邮箱" min-width="140" show-overflow-tooltip />
          <el-table-column label="时间" width="170">
            <template #default="{ row }">{{ row.created_at ? fmtTime(String(row.created_at)) : row.date }}</template>
          </el-table-column>
          <el-table-column label="平台" width="130"><template #default="{ row }"><el-tag size="small">{{ row.platform }}</el-tag></template></el-table-column>
          <el-table-column prop="operation" label="操作" width="90" />
          <el-table-column label="API Key" width="120"><template #default="{ row }"><code>{{ row.api_key_hint || '-' }}</code></template></el-table-column>
          <el-table-column label="客户端" width="90"><template #default="{ row }">{{ clientLabel(String(row.client_platform || '')) }}</template></el-table-column>
          <el-table-column label="请求数" width="80"><template #default="{ row }">{{ fmtNum(Number(row.request_count)) }}</template></el-table-column>
          <el-table-column label="输入Token" width="90"><template #default="{ row }">{{ fmtNum(Number(row.input_tokens)) }}</template></el-table-column>
          <el-table-column label="输出Token" width="90"><template #default="{ row }">{{ fmtNum(Number(row.output_tokens)) }}</template></el-table-column>
          <el-table-column label="音频秒" width="80"><template #default="{ row }">{{ Number(row.audio_duration_sec || 0).toFixed(1) }}</template></el-table-column>
        </el-table>
        <el-pagination
          v-model:current-page="detailPage"
          :page-size="20"
          :total="detailTotal"
          layout="total, prev, pager, next"
          style="margin-top:16px;justify-content:flex-end"
          @current-change="loadStats"
        />
      </div>
    </el-tab-pane>

    <el-tab-pane label="API Key 用量" name="apikeys">
      <div class="card">
        <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
          API Key 用量汇总
          <span style="font-size:12px;color:var(--text-muted)">按 API Key 脱敏标识聚合，支持上方筛选条件过滤</span>
        </div>
        <el-table :data="apiKeyItems" stripe>
          <template #empty>
            <div class="empty-state">
              <div class="empty-icon"><el-icon><Key /></el-icon></div>
              <div class="empty-title">暂无 API Key 用量</div>
              <div class="empty-hint">还没有可聚合的 API Key 调用记录。</div>
            </div>
          </template>
          <el-table-column label="API Key (脱敏)" min-width="140"><template #default="{ row }"><code>{{ row.api_key_hint || '-' }}</code></template></el-table-column>
          <el-table-column label="涉及用户数" width="100"><template #default="{ row }">{{ fmtNum(Number(row.user_count)) }}</template></el-table-column>
          <el-table-column label="总请求数" width="100"><template #default="{ row }"><strong>{{ fmtNum(Number(row.total_requests)) }}</strong></template></el-table-column>
          <el-table-column label="输入Token" width="100"><template #default="{ row }">{{ fmtNum(Number(row.total_input_tokens)) }}</template></el-table-column>
          <el-table-column label="输出Token" width="100"><template #default="{ row }">{{ fmtNum(Number(row.total_output_tokens)) }}</template></el-table-column>
          <el-table-column label="音频时长(秒)" width="110"><template #default="{ row }">{{ Number(row.total_audio_sec || 0).toFixed(1) }}</template></el-table-column>
          <el-table-column label="搜索次数" width="90"><template #default="{ row }">{{ fmtNum(Number(row.total_search)) }}</template></el-table-column>
          <el-table-column label="平均延迟(ms)" width="110"><template #default="{ row }">{{ fmtNum(avgLatency(row)) }}</template></el-table-column>
        </el-table>
        <div v-if="apiKeyTotalText" style="padding:12px 0 0;font-size:13px;color:var(--text-muted)">{{ apiKeyTotalText }}</div>
      </div>
    </el-tab-pane>
  </el-tabs>
</template>
