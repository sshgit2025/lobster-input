<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface DictRow {
  id: string; user_email: string; word: string; created_at: string
}

const filters = ref({ email: '' })
const items = ref<DictRow[]>([])
const page = ref(1)
const pageSize = 20
const total = ref(0)
const totalPages = ref(1)
const loading = ref(false)

async function loadList(p = 1) {
  page.value = p
  loading.value = true
  const params = new URLSearchParams({ page: String(p), page_size: String(pageSize) })
  if (filters.value.email.trim()) params.set('user_email', filters.value.email.trim())
  try {
    const data = await api<{ items: DictRow[]; total: number; total_pages: number; page: number }>('GET', `/api/v1/user-dict?${params}`)
    items.value = data.items || []
    total.value = data.total
    totalPages.value = data.total_pages || Math.ceil(data.total / pageSize) || 1
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
    items.value = []
    total.value = 0
  } finally {
    loading.value = false
  }
}

function resetFilter() {
  filters.value = { email: '' }
  loadList(1)
}

async function delItem(row: DictRow) {
  try {
    await ElMessageBox.confirm(`确认删除词汇「${row.word}」？此操作不可恢复。`, '确认')
    const params = new URLSearchParams({ user_email: row.user_email })
    await api('DELETE', `/api/v1/user-dict/${row.id}?${params}`)
    loadList(page.value)
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? `删除失败：${e.message}` : '删除失败', 'error')
  }
}

onMounted(() => loadList(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">用户级词典管理</div>
      <div class="page-subtitle">查看并清理用户自定义识别词典，按邮箱精准定位，删除操作不可恢复。</div>
    </div>
  </div>
  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="用户邮箱（精准筛选）" style="max-width:280px" clearable />
      <el-button type="primary" @click="loadList(1)">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
      <span style="margin-left:12px;color:var(--text-muted);font-size:13px">共 {{ total }} 条</span>
    </div>

    <el-table v-loading="loading" :data="items" stripe>
      <template #empty>
        <div class="empty-state">
          <div class="empty-title">暂无词典记录</div>
          <div class="empty-hint">尝试调整邮箱筛选条件，或确认该用户尚未添加自定义词汇。</div>
        </div>
      </template>
      <el-table-column prop="user_email" label="用户邮箱" width="220" />
      <el-table-column label="词汇" min-width="200">
        <template #default="{ row }">
          <span class="word-tag">{{ row.word }}</span>
        </template>
      </el-table-column>
      <el-table-column label="创建时间" width="180">
        <template #default="{ row }"><span style="font-size:12px;color:var(--text-muted)">{{ fmtTime(row.created_at) }}</span></template>
      </el-table-column>
      <el-table-column label="操作" width="80">
        <template #default="{ row }">
          <el-button size="small" type="danger" @click="delItem(row)">删除</el-button>
        </template>
      </el-table-column>
    </el-table>

    <el-pagination
      v-if="totalPages > 1"
      v-model:current-page="page"
      :page-size="pageSize"
      :total="total"
      layout="prev, pager, next"
      style="margin-top:16px;justify-content:center"
      @current-change="loadList"
    />
  </div>
</template>

<style scoped>
.word-tag {
  background: var(--bg-hover);
  padding: 2px 8px;
  border-radius: 4px;
  font-family: monospace;
  font-size: 13px;
}
</style>
