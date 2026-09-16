<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { Search, RefreshLeft, View, Delete, DocumentRemove } from '@element-plus/icons-vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

interface LogRow {
  id?: string; created_at?: string; user_email?: string; app_version?: string
  os_version?: string; level?: string; tag?: string; message?: string
}

const LEVEL_COLORS: Record<string, string> = {
  debug: '#666', info: '#2196F3', warn: '#FF9800', error: '#F44336', fatal: '#B71C1C',
}

const filters = ref({ email: '', level: '', tag: '' })
const items = ref<LogRow[]>([])
const page = ref(1)
const total = ref(0)
const detailVisible = ref(false)
const detailContent = ref('')

function formatTs(ts?: string): string {
  if (!ts) return '-'
  return ts.replace('T', ' ').substring(0, 19)
}

function levelType(level?: string): '' | 'info' | 'warning' | 'danger' | 'success' {
  if (level === 'error' || level === 'fatal') return 'danger'
  if (level === 'warn') return 'warning'
  if (level === 'info') return 'info'
  return ''
}

function levelStyle(level?: string): Record<string, string> {
  const color = LEVEL_COLORS[level || ''] || '#888'
  return { background: color, color: '#fff' }
}

async function loadLogs(p = 1) {
  page.value = p
  const params = new URLSearchParams({ page: String(p), page_size: '50' })
  if (filters.value.email.trim()) params.set('email', filters.value.email.trim())
  if (filters.value.level) params.set('level', filters.value.level)
  if (filters.value.tag.trim()) params.set('tag', filters.value.tag.trim())
  try {
    const data = await api<{ items: LogRow[]; total: number }>('GET', `/api/v1/logs?${params}`)
    items.value = data.items
    total.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
    items.value = []
    total.value = 0
  }
}

function resetFilter() {
  filters.value = { email: '', level: '', tag: '' }
  loadLogs(1)
}

function showDetail(row: LogRow) {
  detailContent.value = JSON.stringify(row, null, 2)
  detailVisible.value = true
}

async function deleteLog(id?: string) {
  if (!id) return showToast('日志ID缺失，无法删除', 'error')
  try {
    await ElMessageBox.confirm('确认删除这条日志？', '确认')
    await api('DELETE', `/api/v1/logs/${encodeURIComponent(id)}`)
    showToast('日志已删除')
    loadLogs(page.value)
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? `删除失败: ${e.message}` : '删除失败', 'error')
  }
}

onMounted(() => loadLogs(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">客户端日志</div>
      <div class="page-subtitle">汇总各端上报的运行日志，按邮箱、级别与 Tag 定位问题现场。</div>
    </div>
  </div>
  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="邮箱筛选" style="max-width:220px" clearable />
      <el-select v-model="filters.level" placeholder="全部级别" style="max-width:120px" clearable>
        <el-option label="全部级别" value="" />
        <el-option label="debug" value="debug" />
        <el-option label="info" value="info" />
        <el-option label="warn" value="warn" />
        <el-option label="error" value="error" />
        <el-option label="fatal" value="fatal" />
      </el-select>
      <el-input v-model="filters.tag" placeholder="Tag筛选（如 Permission）" style="max-width:180px" clearable />
      <el-button type="primary" @click="loadLogs(1)"><el-icon><Search /></el-icon>搜索</el-button>
      <el-button @click="resetFilter"><el-icon><RefreshLeft /></el-icon>重置</el-button>
    </div>

    <el-table :data="items" stripe>
      <el-table-column label="时间" width="160"><template #default="{ row }"><span style="font-size:12px">{{ formatTs(row.created_at) }}</span></template></el-table-column>
      <el-table-column prop="user_email" label="用户" width="160"><template #default="{ row }"><span style="font-size:12px">{{ row.user_email || '-' }}</span></template></el-table-column>
      <el-table-column prop="app_version" label="版本" width="90"><template #default="{ row }">{{ row.app_version || '-' }}</template></el-table-column>
      <el-table-column prop="os_version" label="系统" width="120"><template #default="{ row }"><span style="font-size:12px">{{ row.os_version || '-' }}</span></template></el-table-column>
      <el-table-column label="级别" width="80">
        <template #default="{ row }">
          <el-tag :type="levelType(row.level)" size="small" :style="levelStyle(row.level)">{{ row.level || '-' }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column label="Tag" width="120"><template #default="{ row }"><code style="font-size:12px">{{ row.tag || '-' }}</code></template></el-table-column>
      <el-table-column label="内容" min-width="200">
        <template #default="{ row }">{{ (row.message || '').substring(0, 60) }}{{ (row.message || '').length > 60 ? '…' : '' }}</template>
      </el-table-column>
      <el-table-column label="操作" width="140" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="showDetail(row)"><el-icon><View /></el-icon>详情</el-button>
          <el-button size="small" type="danger" @click="deleteLog(row.id)"><el-icon><Delete /></el-icon>删除</el-button>
        </template>
      </el-table-column>
      <template #empty>
        <div class="empty-state">
          <div class="empty-icon"><el-icon><DocumentRemove /></el-icon></div>
          <div class="empty-title">暂无日志</div>
          <div class="empty-hint">当前筛选条件下没有匹配的客户端日志</div>
        </div>
      </template>
    </el-table>

    <el-pagination
      v-model:current-page="page"
      :page-size="50"
      :total="total"
      layout="total, prev, pager, next"
      style="margin-top:16px;justify-content:flex-end"
      @current-change="loadLogs"
    />
  </div>

  <el-dialog v-model="detailVisible" title="日志详情" width="640px">
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
