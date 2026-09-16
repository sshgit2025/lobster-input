<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { Search, Histogram } from '@element-plus/icons-vue'
import { api } from '@/api'
import { CATEGORY_LABELS } from '@/constants'
import { fmtTime } from '@/utils/format'

interface UsageItem {
  created_at?: string
  category?: string
  platform_code?: string
  api_key_hint?: string
  api_key_id?: string
  api_key_name?: string
  tokens_used?: number
  seconds_used?: number
  requests_used?: number
  latency_ms?: number
  operation?: string
  success?: boolean
}

const categories = ref<string[]>([])
const platforms = ref<Array<{ category: string; code: string }>>([])
const items = ref<UsageItem[]>([])
const total = ref(0)
const page = ref(1)
const pageSize = 50
const filters = ref({
  category: '',
  platform_code: '',
  api_key_id: '',
  start_date: '',
  end_date: '',
})

async function loadFilters() {
  const [cats, plats] = await Promise.all([
    api<string[]>('/api/v1/keys/categories'),
    api<Array<{ category: string; code: string }>>('/api/v1/keys/platforms'),
  ])
  categories.value = cats
  platforms.value = plats
}

async function loadUsage(p = 1) {
  page.value = p
  const params = new URLSearchParams({
    category: filters.value.category,
    platform_code: filters.value.platform_code,
    group_id: '',
    api_key_id: filters.value.api_key_id,
    start_date: filters.value.start_date,
    end_date: filters.value.end_date,
    page: String(page.value),
    page_size: String(pageSize),
  })
  try {
    const data = await api<{ items: UsageItem[]; total: number }>(`/api/v1/stats/usage?${params}`)
    items.value = data.items
    total.value = data.total
  } catch (e) {
    ElMessage.error(e instanceof Error ? e.message : '加载失败')
  }
}

onMounted(async () => {
  try {
    await loadFilters()
    await loadUsage()
  } catch (e) {
    ElMessage.error(e instanceof Error ? e.message : '加载失败')
  }
})
</script>

<template>
  <div class="page-header">
    <div>
      <h1 class="page-title">消费明细</h1>
      <div class="page-subtitle">逐条调用流水:Token、时长、请求量与延迟,按平台与时间维度回溯排查。</div>
    </div>
  </div>
  <div class="search-bar">
    <select v-model="filters.category" class="form-select">
      <option value="">全部分类</option>
      <option v-for="c in categories" :key="c" :value="c">{{ CATEGORY_LABELS[c] || c }}</option>
    </select>
    <select v-model="filters.platform_code" class="form-select">
      <option value="">全部平台</option>
      <option v-for="p in platforms" :key="p.code" :value="p.code">{{ p.category }}/{{ p.code }}</option>
    </select>
    <input v-model="filters.api_key_id" class="form-input" placeholder="API Key ID">
    <input v-model="filters.start_date" class="form-input" type="date">
    <input v-model="filters.end_date" class="form-input" type="date">
    <button class="btn btn-ghost" @click="loadUsage(1)"><el-icon><Search /></el-icon> 搜索</button>
  </div>
  <div class="card">
    <div v-if="!items.length" class="empty-state">
      <el-icon class="empty-icon"><Histogram /></el-icon>
      <div class="empty-title">暂无消费记录</div>
      <div class="empty-hint">调整筛选条件或时间范围后重试。</div>
    </div>
    <el-table v-else :data="items" stripe>
      <el-table-column label="时间" width="170"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
      <el-table-column label="分类" width="120"><template #default="{ row }"><span class="badge badge-primary">{{ row.category || '-' }}</span></template></el-table-column>
      <el-table-column label="平台" width="100"><template #default="{ row }"><span class="badge badge-info">{{ row.platform_code || '-' }}</span></template></el-table-column>
      <el-table-column label="Key" width="120"><template #default="{ row }"><span class="key-mask">{{ row.api_key_hint || row.api_key_id?.slice(-8) || '-' }}</span></template></el-table-column>
      <el-table-column label="名称" prop="api_key_name" />
      <el-table-column label="Token" prop="tokens_used" width="80" />
      <el-table-column label="秒数" width="80"><template #default="{ row }">{{ (row.seconds_used || 0).toFixed(1) }}</template></el-table-column>
      <el-table-column label="请求" prop="requests_used" width="70" />
      <el-table-column label="延迟" width="80"><template #default="{ row }">{{ row.latency_ms || 0 }}ms</template></el-table-column>
      <el-table-column label="操作类型" prop="operation" width="100" />
      <el-table-column label="结果" width="80">
        <template #default="{ row }">
          <span :class="row.success ? 'badge badge-success' : 'badge badge-danger'">{{ row.success ? '成功' : '失败' }}</span>
        </template>
      </el-table-column>
    </el-table>
    <div v-if="items.length" class="pager-row">
      <el-pagination layout="total, prev, pager, next" :total="total" :page-size="pageSize" :current-page="page" @current-change="loadUsage" />
    </div>
  </div>
</template>
