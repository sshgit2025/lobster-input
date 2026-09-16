<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ChatDotRound } from '@element-plus/icons-vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

interface FeedbackRow {
  id: string; created_at?: string; user_email?: string; client_platform?: string
  app_variant?: string; app_version?: string; os_version?: string; client_ip?: string
  phone?: string; email?: string; content?: string; status: string
}

const STATUSES = ['未处理', '挂起', '忽略', '实现中', '已实现'] as const
const filters = ref({ email: '', status: '', platform: '' })
const items = ref<FeedbackRow[]>([])
const page = ref(1)
const total = ref(0)
const detailVisible = ref(false)
const detailContent = ref('')

function formatTs(ts?: string): string {
  if (!ts) return '-'
  return ts.replace('T', ' ').substring(0, 19)
}

function clientInfo(row: FeedbackRow): string {
  return [row.client_platform, row.app_variant, row.app_version, row.os_version, row.client_ip].filter(Boolean).join('\n') || '-'
}

function contactInfo(row: FeedbackRow): string {
  return [row.phone, row.email].filter(Boolean).join('\n') || '-'
}

async function loadFeedback(p = 1) {
  page.value = p
  const params = new URLSearchParams({ page: String(p), page_size: '50' })
  if (filters.value.email.trim()) params.set('email', filters.value.email.trim())
  if (filters.value.status) params.set('status', filters.value.status)
  if (filters.value.platform) params.set('platform', filters.value.platform)
  try {
    const data = await api<{ items: FeedbackRow[]; total: number }>('GET', `/api/v1/feedback?${params}`)
    items.value = data.items
    total.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
    items.value = []
    total.value = 0
  }
}

function resetFilter() {
  filters.value = { email: '', status: '', platform: '' }
  loadFeedback(1)
}

async function updateStatus(row: FeedbackRow, status: string) {
  try {
    await api('POST', `/api/v1/feedback/${row.id}/status`, { status })
    row.status = status
    showToast('状态已更新')
  } catch (e) {
    showToast(e instanceof Error ? e.message : '更新失败', 'error')
    loadFeedback(page.value)
  }
}

function showDetail(row: FeedbackRow) {
  detailContent.value = JSON.stringify(row, null, 2)
  detailVisible.value = true
}

onMounted(() => loadFeedback(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">反馈意见</div>
      <div class="page-subtitle">汇总各端用户提交的反馈与建议,按状态流转跟进处理,可查看完整设备与上下文信息。</div>
    </div>
  </div>
  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="邮箱筛选" style="max-width:220px" clearable />
      <el-select v-model="filters.status" placeholder="全部状态" style="max-width:140px" clearable>
        <el-option label="全部状态" value="" />
        <el-option v-for="s in STATUSES" :key="s" :label="s" :value="s" />
      </el-select>
      <el-select v-model="filters.platform" placeholder="全部客户端" style="max-width:140px" clearable>
        <el-option label="全部客户端" value="" />
        <el-option label="Mac" value="macos" />
        <el-option label="Windows" value="windows" />
        <el-option label="iOS" value="ios" />
        <el-option label="Android" value="android" />
      </el-select>
      <el-button type="primary" @click="loadFeedback(1)">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
    </div>

    <div v-if="!items.length" class="empty-state">
      <div class="empty-icon"><el-icon><ChatDotRound /></el-icon></div>
      <div class="empty-title">暂无反馈</div>
      <div class="empty-hint">调整邮箱、状态或客户端筛选条件后重试。</div>
    </div>
    <el-table v-else :data="items" stripe>
      <el-table-column label="时间" width="160"><template #default="{ row }"><span style="font-size:12px">{{ formatTs(row.created_at) }}</span></template></el-table-column>
      <el-table-column prop="user_email" label="用户" width="160"><template #default="{ row }"><span style="font-size:12px">{{ row.user_email || '-' }}</span></template></el-table-column>
      <el-table-column label="客户端" width="180">
        <template #default="{ row }"><span style="font-size:12px;white-space:pre-line">{{ clientInfo(row) }}</span></template>
      </el-table-column>
      <el-table-column label="联系方式" width="140">
        <template #default="{ row }"><span style="font-size:12px;white-space:pre-line">{{ contactInfo(row) }}</span></template>
      </el-table-column>
      <el-table-column label="内容" min-width="200">
        <template #default="{ row }">{{ (row.content || '').substring(0, 80) }}{{ (row.content || '').length > 80 ? '…' : '' }}</template>
      </el-table-column>
      <el-table-column label="状态" width="120">
        <template #default="{ row }">
          <el-select :model-value="row.status" size="small" @change="(v: string) => updateStatus(row, v)">
            <el-option v-for="s in STATUSES" :key="s" :label="s" :value="s" />
          </el-select>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="80">
        <template #default="{ row }">
          <el-button size="small" @click="showDetail(row)">详情</el-button>
        </template>
      </el-table-column>
    </el-table>

    <div class="pager-row">
      <el-pagination
        v-model:current-page="page"
        :page-size="50"
        :total="total"
        layout="total, prev, pager, next"
        @current-change="loadFeedback"
      />
    </div>
  </div>

  <el-dialog v-model="detailVisible" title="反馈详情" width="680px">
    <pre class="detail-pre">{{ detailContent }}</pre>
  </el-dialog>
</template>

<style scoped>
.detail-pre {
  background: #1a1a2e;
  color: #e0e0e0;
  padding: 16px;
  border-radius: 8px;
  overflow: auto;
  font-size: 13px;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 480px;
}
</style>
