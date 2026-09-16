<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { Search } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface TxRow {
  payment_event_id: string; event_type?: string; type?: string
  provider: string; payment_order_id?: string; provider_payment_id?: string
  created_at: string
}

const filters = ref({ email: '', provider: '' })
const rows = ref<TxRow[]>([])
const page = ref(1)
const total = ref(0)

async function loadRows(p = 1) {
  page.value = p
  const q = new URLSearchParams({ page: String(p), page_size: '20' })
  if (filters.value.email.trim()) q.set('email', filters.value.email.trim())
  if (filters.value.provider.trim()) q.set('provider', filters.value.provider.trim())
  try {
    const data = await api<{ items: TxRow[]; total: number }>('GET', `/api/v1/payment-provider-config/transactions?${q}`)
    rows.value = data.items || []
    total.value = data.total || 0
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

onMounted(() => loadRows(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">交易流水</div>
      <div class="page-subtitle">来自各支付渠道的原始事件回执，用于核对订单状态与异常排查。</div>
    </div>
  </div>

  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="按用户邮箱搜索" style="max-width:240px" clearable />
      <el-input v-model="filters.provider" placeholder="按渠道 provider 搜索" style="max-width:160px" clearable />
      <el-button type="primary" :icon="Search" @click="loadRows(1)">搜索</el-button>
    </div>

    <el-table :data="rows" stripe>
      <el-table-column label="事件 ID" min-width="180"><template #default="{ row }"><code>{{ row.payment_event_id }}</code></template></el-table-column>
      <el-table-column label="类型" width="120"><template #default="{ row }">{{ row.event_type || row.type }}</template></el-table-column>
      <el-table-column prop="provider" label="Provider" width="120" />
      <el-table-column label="订单" width="160"><template #default="{ row }">{{ row.payment_order_id || '-' }}</template></el-table-column>
      <el-table-column label="渠道流水" width="160"><template #default="{ row }">{{ row.provider_payment_id || '-' }}</template></el-table-column>
      <el-table-column label="创建时间" width="170"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
      <template #empty>
        <div class="empty-state">
          <div class="empty-title">暂无交易流水</div>
          <div class="empty-hint">调整邮箱或 provider 筛选条件后再试。</div>
        </div>
      </template>
    </el-table>

    <div class="pager-row">
      <el-pagination
        v-model:current-page="page"
        :page-size="20"
        :total="total"
        layout="total, prev, pager, next"
        @current-change="loadRows"
      />
    </div>
  </div>
</template>
