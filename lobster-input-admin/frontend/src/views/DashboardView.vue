<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { User, UserFilled, DataLine, Coin, Ticket, Tickets } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtNum } from '@/utils/format'
import { destroyChart, mkDoughnutChart, mkLineChart } from '@/utils/chart'
import type { Chart } from 'chart.js/auto'

const stats = ref({ users: '-', active: '-', requests: '-', tokens: '-', invites: '-', invitesUsed: '-' })
const chartReg = ref<HTMLCanvasElement | null>(null)
const chartReq = ref<HTMLCanvasElement | null>(null)
const chartPlan = ref<HTMLCanvasElement | null>(null)
const chartPlatform = ref<HTMLCanvasElement | null>(null)
let c1: Chart | null = null
let c2: Chart | null = null
let c3: Chart | null = null
let c4: Chart | null = null

onMounted(async () => {
  try {
    const [userStats, activeStats, usageSummary, inviteStats, regData, reqData, planData, platformData] = await Promise.all([
      api<{ total: number }>('GET', '/api/v1/users?page_size=1'),
      api<{ total: number }>('GET', '/api/v1/users?is_active=true&page_size=1'),
      api<{ total_requests: number; total_input_tokens?: number; total_output_tokens?: number }>('GET', '/api/v1/stats/summary'),
      api<{ total: number; used: number }>('GET', '/api/v1/invites/stats'),
      api<{ date: string; count: number }[]>('GET', '/api/v1/users/stats/daily-registrations?days=30'),
      api<{ date: string; request_count: number }[]>('GET', '/api/v1/stats/daily?days=30'),
      api<{ plan_code: string; count: number }[]>('GET', '/api/v1/users/stats/plan-distribution'),
      api<{ platform: string; count: number }[]>('GET', '/api/v1/stats/platform-distribution'),
    ])
    stats.value = {
      users: fmtNum(userStats.total),
      active: fmtNum(activeStats.total),
      requests: fmtNum(usageSummary.total_requests),
      tokens: fmtNum((usageSummary.total_input_tokens || 0) + (usageSummary.total_output_tokens || 0)),
      invites: fmtNum(inviteStats.total),
      invitesUsed: fmtNum(inviteStats.used),
    }
    const regSorted = [...regData].sort((a, b) => (a.date > b.date ? 1 : -1))
    const reqSorted = [...reqData].sort((a, b) => (a.date > b.date ? 1 : -1))
    if (chartReg.value) c1 = mkLineChart(chartReg.value, regSorted.map((d) => d.date), regSorted.map((d) => d.count), '注册数')
    if (chartReq.value) c2 = mkLineChart(chartReq.value, reqSorted.map((d) => d.date), reqSorted.map((d) => d.request_count), '请求数')
    if (chartPlan.value) c3 = mkDoughnutChart(chartPlan.value, planData.map((d) => d.plan_code), planData.map((d) => d.count))
    if (chartPlatform.value) c4 = mkDoughnutChart(chartPlatform.value, platformData.map((d) => d.platform), platformData.map((d) => d.count))
  } catch (e) {
    console.error(e)
  }
})

onUnmounted(() => {
  c1 = destroyChart(c1)
  c2 = destroyChart(c2)
  c3 = destroyChart(c3)
  c4 = destroyChart(c4)
})
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">仪表盘</div>
      <div class="page-subtitle">核心运营指标总览,数据每次进入页面实时拉取。</div>
    </div>
  </div>
  <div class="stat-grid">
    <div class="stat-card"><div class="stat-label"><el-icon><User /></el-icon>总用户数</div><div class="stat-value primary">{{ stats.users }}</div></div>
    <div class="stat-card"><div class="stat-label"><el-icon><UserFilled /></el-icon>活跃用户</div><div class="stat-value success">{{ stats.active }}</div></div>
    <div class="stat-card"><div class="stat-label"><el-icon><DataLine /></el-icon>总请求数</div><div class="stat-value info">{{ stats.requests }}</div></div>
    <div class="stat-card"><div class="stat-label"><el-icon><Coin /></el-icon>总 Token 数</div><div class="stat-value warning">{{ stats.tokens }}</div></div>
    <div class="stat-card"><div class="stat-label"><el-icon><Ticket /></el-icon>邀请码总量</div><div class="stat-value">{{ stats.invites }}</div></div>
    <div class="stat-card"><div class="stat-label"><el-icon><Tickets /></el-icon>已用邀请码</div><div class="stat-value">{{ stats.invitesUsed }}</div></div>
  </div>
  <div class="chart-grid">
    <div class="card"><div class="card-title">近30天注册趋势</div><div class="chart-wrap"><canvas ref="chartReg" /></div></div>
    <div class="card"><div class="card-title">近30天请求趋势</div><div class="chart-wrap"><canvas ref="chartReq" /></div></div>
    <div class="card"><div class="card-title">套餐分布</div><div class="chart-wrap"><canvas ref="chartPlan" /></div></div>
    <div class="card"><div class="card-title">平台调用分布</div><div class="chart-wrap"><canvas ref="chartPlatform" /></div></div>
  </div>
</template>
