<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { Filter, RefreshLeft, Select, BellFilled } from '@element-plus/icons-vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

interface AlertRow {
  id: string; created_at?: string; source?: string; level: string
  title?: string; message?: string; status: string; resolve_note?: string
}

const LEVEL_COLOR: Record<string, string> = { info: '#3b82f6', warning: '#f59e0b', critical: '#ef4444' }
const LEVEL_LABEL: Record<string, string> = { info: '信息', warning: '警告', critical: '严重' }
const SOURCE_LABEL: Record<string, string> = { backup: '备份', system: '系统', manual: '手动' }

const filters = ref({ status: '' })
const items = ref<AlertRow[]>([])
const page = ref(1)
const total = ref(0)
const resolveVisible = ref(false)
const resolveId = ref('')
const resolveNote = ref('')

function formatTs(ts?: string): string {
  if (!ts) return ''
  return ts.replace('T', ' ').substring(0, 19)
}

function levelStyle(level: string): Record<string, string> {
  const c = LEVEL_COLOR[level] || '#888'
  return { background: c, color: '#fff' }
}

function levelLabel(level: string): string {
  return LEVEL_LABEL[level] || level
}

function sourceLabel(source?: string): string {
  return SOURCE_LABEL[source || ''] || source || ''
}

async function loadAlerts(p = 1) {
  page.value = p
  const params = new URLSearchParams({ page: String(p), page_size: '20' })
  if (filters.value.status) params.set('status', filters.value.status)
  try {
    const data = await api<{ items: AlertRow[]; total: number }>('GET', `/api/v1/alerts?${params}`)
    items.value = data.items
    total.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
    items.value = []
    total.value = 0
  }
}

function resetFilter() {
  filters.value = { status: '' }
  loadAlerts(1)
}

function openResolve(id: string) {
  resolveId.value = id
  resolveNote.value = ''
  resolveVisible.value = true
}

async function submitResolve() {
  try {
    await api('POST', `/api/v1/alerts/${resolveId.value}/resolve`, { note: resolveNote.value.trim() })
    resolveVisible.value = false
    loadAlerts(page.value)
  } catch (e) {
    showToast(e instanceof Error ? `处理失败: ${e.message}` : '处理失败', 'error')
  }
}

onMounted(() => loadAlerts(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">告警管理</div>
      <div class="page-subtitle">集中处理系统、备份与人工告警，优先跟进严重级别的未处理事件。</div>
    </div>
  </div>
  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-select v-model="filters.status" placeholder="全部状态" style="max-width:140px" clearable>
        <el-option label="全部状态" value="" />
        <el-option label="未处理" value="pending" />
        <el-option label="已处理" value="resolved" />
      </el-select>
      <el-button type="primary" @click="loadAlerts(1)"><el-icon><Filter /></el-icon>筛选</el-button>
      <el-button @click="resetFilter"><el-icon><RefreshLeft /></el-icon>重置</el-button>
    </div>

    <el-table :data="items" stripe>
      <el-table-column label="时间" width="160"><template #default="{ row }"><span style="font-size:12px">{{ formatTs(row.created_at) }}</span></template></el-table-column>
      <el-table-column label="来源" width="80"><template #default="{ row }"><span style="font-size:12px">{{ sourceLabel(row.source) }}</span></template></el-table-column>
      <el-table-column label="级别" width="80">
        <template #default="{ row }">
          <el-tag size="small" :style="levelStyle(row.level)">{{ levelLabel(row.level) }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="title" label="标题" min-width="140"><template #default="{ row }"><span style="font-size:13px;font-weight:500">{{ row.title || '' }}</span></template></el-table-column>
      <el-table-column label="内容" min-width="200">
        <template #default="{ row }"><span style="font-size:12px;color:#8892a4">{{ (row.message || '').substring(0, 80) }}{{ (row.message || '').length > 80 ? '…' : '' }}</span></template>
      </el-table-column>
      <el-table-column label="状态" width="90">
        <template #default="{ row }">
          <el-tag :type="row.status === 'pending' ? 'warning' : 'success'" size="small">{{ row.status === 'pending' ? '未处理' : '已处理' }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="操作" width="120">
        <template #default="{ row }">
          <el-button v-if="row.status === 'pending'" size="small" type="primary" @click="openResolve(row.id)"><el-icon><Select /></el-icon>处理</el-button>
          <span v-else style="color:#8892a4;font-size:12px">{{ (row.resolve_note || '已处理').substring(0, 20) }}</span>
        </template>
      </el-table-column>
      <template #empty>
        <div class="empty-state">
          <div class="empty-icon"><el-icon><BellFilled /></el-icon></div>
          <div class="empty-title">暂无告警</div>
          <div class="empty-hint">当前筛选条件下没有需要关注的告警事件</div>
        </div>
      </template>
    </el-table>

    <el-pagination
      v-model:current-page="page"
      :page-size="20"
      :total="total"
      layout="total, prev, pager, next"
      style="margin-top:16px;justify-content:flex-end"
      @current-change="loadAlerts"
    />
  </div>

  <el-dialog v-model="resolveVisible" title="标记为已处理" width="480px">
    <el-form label-position="top">
      <el-form-item label="处理备注（可选）">
        <el-input v-model="resolveNote" type="textarea" :rows="3" placeholder="说明处理方式或原因..." />
      </el-form-item>
    </el-form>
    <template #footer>
      <el-button @click="resolveVisible = false">取消</el-button>
      <el-button type="primary" @click="submitResolve">确认处理</el-button>
    </template>
  </el-dialog>
</template>
