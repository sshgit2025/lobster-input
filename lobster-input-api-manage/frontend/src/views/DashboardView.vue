<script setup lang="ts">
import { onMounted, onUnmounted, ref } from 'vue'
import { Chart, registerables } from 'chart.js'
import { ElMessage } from 'element-plus'
import { api } from '@/api'
import { CATEGORY_LABELS } from '@/constants'
import { fmtNum } from '@/utils/format'

Chart.register(...registerables)

const dash = ref<Record<string, number>>({})
const categories = ref<Array<{ _id: string; total_keys: number; active_keys: number; total_requests: number }>>([])
let categoryChart: Chart | null = null
let platformChart: Chart | null = null

onMounted(async () => {
  try {
    const [d, cats, platforms] = await Promise.all([
      api<Record<string, number>>('/api/v1/stats/dashboard'),
      api<Array<{ _id: string; total_keys: number; active_keys: number; total_requests: number }>>('/api/v1/stats/categories'),
      api<Array<{ _id: { category: string; platform_code: string }; total_keys: number }>>('/api/v1/stats/platforms'),
    ])
    dash.value = d
    categories.value = cats
    const colors = ['#6366f1', '#22c55e', '#f59e0b', '#ef4444', '#3b82f6', '#8b5cf6', '#ec4899', '#14b8a6']
    if (cats.length) {
      categoryChart = new Chart(document.getElementById('categoryChart') as HTMLCanvasElement, {
        type: 'doughnut',
        data: {
          labels: cats.map((s) => CATEGORY_LABELS[s._id] || s._id),
          datasets: [{ data: cats.map((s) => s.total_keys), backgroundColor: colors, borderColor: '#141823', borderWidth: 2 }],
        },
        options: { responsive: true, maintainAspectRatio: false, cutout: '62%', plugins: { legend: { labels: { color: '#93a0b6', usePointStyle: true, pointStyle: 'circle' } } } },
      })
    }
    if (platforms.length) {
      platformChart = new Chart(document.getElementById('platformChart') as HTMLCanvasElement, {
        type: 'doughnut',
        data: {
          labels: platforms.map((p) => `${p._id.category}/${p._id.platform_code}`),
          datasets: [{ data: platforms.map((p) => p.total_keys), backgroundColor: colors, borderColor: '#141823', borderWidth: 2 }],
        },
        options: { responsive: true, maintainAspectRatio: false, cutout: '62%', plugins: { legend: { labels: { color: '#93a0b6', usePointStyle: true, pointStyle: 'circle' } } } },
      })
    }
  } catch (e) {
    ElMessage.error(e instanceof Error ? e.message : '加载失败')
  }
})

onUnmounted(() => {
  categoryChart?.destroy()
  platformChart?.destroy()
})
</script>

<template>
  <div class="page-header">
    <div>
      <h1 class="page-title">仪表盘</h1>
      <div class="page-subtitle">号池 Key 健康度与各 Provider 分布总览。</div>
    </div>
  </div>
  <div class="stat-grid">
    <div class="stat-card"><div class="stat-label">总 Key 数</div><div class="stat-value primary">{{ fmtNum(dash.total_keys) }}</div></div>
    <div class="stat-card"><div class="stat-label">活跃</div><div class="stat-value success">{{ fmtNum(dash.active_keys) }}</div></div>
    <div class="stat-card"><div class="stat-label">耗尽</div><div class="stat-value warning">{{ fmtNum(dash.exhausted_keys) }}</div></div>
    <div class="stat-card"><div class="stat-label">异常</div><div class="stat-value danger">{{ fmtNum(dash.error_keys) }}</div></div>
    <div class="stat-card"><div class="stat-label">冷却中</div><div class="stat-value info">{{ fmtNum(dash.cooldown_keys) }}</div></div>
    <div class="stat-card"><div class="stat-label">已禁用</div><div class="stat-value">{{ fmtNum(dash.disabled_keys) }}</div></div>
    <div class="stat-card"><div class="stat-label">已过期</div><div class="stat-value">{{ fmtNum(dash.expired_keys) }}</div></div>
    <div class="stat-card"><div class="stat-label">消费记录</div><div class="stat-value info">{{ fmtNum(dash.total_usage_records) }}</div></div>
  </div>
  <div class="chart-grid">
    <div class="card">
      <div class="card-title">Provider 分类 Key 分布</div>
      <div class="chart-wrap"><canvas id="categoryChart" /></div>
    </div>
    <div class="card">
      <div class="card-title">平台 Key 分布</div>
      <div class="chart-wrap"><canvas id="platformChart" /></div>
    </div>
  </div>
  <div class="card">
    <div class="card-title">各 Provider 分类统计</div>
    <el-table :data="categories" stripe>
      <el-table-column label="分类">
        <template #default="{ row }"><span class="badge badge-primary">{{ CATEGORY_LABELS[row._id] || row._id }}</span></template>
      </el-table-column>
      <el-table-column label="总Key数" prop="total_keys" />
      <el-table-column label="活跃" prop="active_keys" />
      <el-table-column label="总请求" prop="total_requests" />
    </el-table>
  </div>
</template>
