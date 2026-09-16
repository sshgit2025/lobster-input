<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { Plus, Ticket } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtNum, fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface InviteRow {
  code: string; owner_email: string; is_used: boolean
  used_by?: string; used_at?: string; created_at: string
}

const stats = ref({ total: '-', used: '-', unused: '-' })
const filters = ref({ owner: '', used: '' })
const invites = ref<InviteRow[]>([])
const page = ref(1)
const total = ref(0)
const createVisible = ref(false)
const createForm = ref({ owner: '', count: 3 })

async function loadStats() {
  try {
    const d = await api<{ total: number; used: number; unused: number }>('GET', '/api/v1/invites/stats')
    stats.value = { total: fmtNum(d.total), used: fmtNum(d.used), unused: fmtNum(d.unused) }
  } catch { /* ignore */ }
}

async function loadInvites(p = 1) {
  page.value = p
  const params = new URLSearchParams({ page: String(p), page_size: '20' })
  if (filters.value.owner.trim()) params.set('owner_email', filters.value.owner.trim())
  if (filters.value.used !== '') params.set('is_used', filters.value.used)
  try {
    const data = await api<{ items: InviteRow[]; total: number }>('GET', `/api/v1/invites?${params}`)
    invites.value = data.items
    total.value = data.total
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function resetFilter() {
  filters.value = { owner: '', used: '' }
  loadInvites(1)
}

function openCreateModal() {
  createForm.value = { owner: '', count: 3 }
  createVisible.value = true
}

async function doCreate() {
  const owner_email = createForm.value.owner.trim()
  const count = parseInt(String(createForm.value.count)) || 1
  if (!owner_email) return showToast('请输入所有者邮箱', 'error')
  try {
    const d = await api<{ codes: string[] }>('POST', '/api/v1/invites', { owner_email, count })
    showToast(`创建成功: ${d.codes.join(', ')}`)
    createVisible.value = false
    loadInvites(1)
    loadStats()
  } catch (e) {
    showToast(e instanceof Error ? e.message : '创建失败', 'error')
  }
}

async function doDelete(code: string) {
  try {
    await ElMessageBox.confirm(`确认删除邀请码 ${code}？`, '确认')
    await api('DELETE', `/api/v1/invites/${code}`)
    showToast('已删除')
    loadInvites(page.value)
    loadStats()
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? e.message : '删除失败', 'error')
  }
}

onMounted(() => { loadStats(); loadInvites(1) })
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">邀请码管理</div>
      <div class="page-subtitle">为指定用户批量生成邀请码,跟踪使用情况,并回收未使用的邀请码。</div>
    </div>
    <div class="ph-actions">
      <el-button type="primary" @click="openCreateModal">
        <el-icon><Plus /></el-icon>创建邀请码
      </el-button>
    </div>
  </div>

  <div class="stat-grid" style="grid-template-columns:repeat(3,1fr)">
    <div class="stat-card"><div class="stat-label">总邀请码</div><div class="stat-value info">{{ stats.total }}</div></div>
    <div class="stat-card"><div class="stat-label">已使用</div><div class="stat-value warning">{{ stats.used }}</div></div>
    <div class="stat-card"><div class="stat-label">未使用</div><div class="stat-value success">{{ stats.unused }}</div></div>
  </div>

  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.owner" placeholder="所有者邮箱" style="max-width:220px" clearable />
      <el-select v-model="filters.used" placeholder="全部状态" style="max-width:120px" clearable>
        <el-option label="全部状态" value="" />
        <el-option label="未使用" value="false" />
        <el-option label="已使用" value="true" />
      </el-select>
      <el-button type="primary" @click="loadInvites(1)">搜索</el-button>
      <el-button @click="resetFilter">重置</el-button>
    </div>

    <div v-if="!invites.length" class="empty-state">
      <div class="empty-icon"><el-icon><Ticket /></el-icon></div>
      <div class="empty-title">暂无邀请码</div>
      <div class="empty-hint">点击右上角"创建邀请码"为用户生成,或调整筛选条件。</div>
    </div>
    <el-table v-else :data="invites" stripe>
      <el-table-column label="邀请码" width="160"><template #default="{ row }"><code>{{ row.code }}</code></template></el-table-column>
      <el-table-column prop="owner_email" label="所有者" min-width="180" />
      <el-table-column label="状态" width="90">
        <template #default="{ row }">
          <el-tag :type="row.is_used ? 'warning' : 'success'" size="small">{{ row.is_used ? '已使用' : '未使用' }}</el-tag>
        </template>
      </el-table-column>
      <el-table-column prop="used_by" label="使用者" width="160"><template #default="{ row }">{{ row.used_by || '-' }}</template></el-table-column>
      <el-table-column label="使用时间" width="170"><template #default="{ row }">{{ fmtTime(row.used_at) }}</template></el-table-column>
      <el-table-column label="创建时间" width="170"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
      <el-table-column label="操作" width="90">
        <template #default="{ row }">
          <el-button v-if="!row.is_used" size="small" type="danger" @click="doDelete(row.code)">删除</el-button>
          <span v-else>-</span>
        </template>
      </el-table-column>
    </el-table>

    <div class="pager-row">
      <el-pagination
        v-model:current-page="page"
        :page-size="20"
        :total="total"
        layout="total, prev, pager, next"
        @current-change="loadInvites"
      />
    </div>
  </div>

  <el-dialog v-model="createVisible" title="创建邀请码" width="400px">
    <el-form label-width="100px">
      <el-form-item label="所有者邮箱">
        <el-input v-model="createForm.owner" placeholder="user@example.com" />
      </el-form-item>
      <el-form-item label="数量">
        <el-input v-model.number="createForm.count" type="number" :min="1" :max="20" />
      </el-form-item>
    </el-form>
    <template #footer>
      <el-button @click="createVisible = false">取消</el-button>
      <el-button type="primary" @click="doCreate">创建</el-button>
    </template>
  </el-dialog>
</template>
