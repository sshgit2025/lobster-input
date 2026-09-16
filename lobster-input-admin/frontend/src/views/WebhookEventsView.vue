<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { Refresh, Search } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'

interface EventRow {
  provider: string
  event_id: string
  status: string
  signature_ok?: boolean
  error?: string | null
  received_at?: string
  processed_at?: string
  raw_summary?: string
}

interface EventDetail extends EventRow {
  raw?: unknown
  result?: unknown
}

const STATUS_LABELS: Record<string, string> = {
  received: '已接收',
  processing: '处理中',
  done: '已处理',
  failed: '失败',
}
const STATUS_BADGES: Record<string, string> = {
  received: 'info',
  processing: 'warning',
  done: 'success',
  failed: 'danger',
}

const filters = ref({ provider: '', status: '' })
const rows = ref<EventRow[]>([])
const page = ref(1)
const total = ref(0)
const loading = ref(false)

const detailVisible = ref(false)
const detailLoading = ref(false)
const currentDetail = ref<EventDetail | null>(null)
const replaying = ref(false)

function errMsg(e: unknown, fallback: string): string {
  return e instanceof Error ? e.message : fallback
}

async function loadRows(p = 1) {
  page.value = p
  loading.value = true
  const q = new URLSearchParams({ page: String(p), page_size: '20' })
  if (filters.value.provider) q.set('provider', filters.value.provider)
  if (filters.value.status) q.set('status', filters.value.status)
  try {
    const data = await api<{ items: EventRow[]; total: number }>('GET', `/api/v1/webhook-events?${q}`)
    rows.value = data.items || []
    total.value = data.total || 0
  } catch (e) {
    showToast(errMsg(e, '加载 webhook 事件失败'), 'error')
  } finally {
    loading.value = false
  }
}

async function openDetail(row: EventRow) {
  detailVisible.value = true
  detailLoading.value = true
  currentDetail.value = null
  try {
    const data = await api<{ event: EventDetail }>(
      'GET',
      `/api/v1/webhook-events/${encodeURIComponent(row.provider)}/${encodeURIComponent(row.event_id)}`,
    )
    currentDetail.value = data.event
  } catch (e) {
    showToast(errMsg(e, '加载事件详情失败'), 'error')
    detailVisible.value = false
  } finally {
    detailLoading.value = false
  }
}

async function replayEvent(row: EventRow) {
  try {
    await ElMessageBox.confirm(
      `确认重放事件 ${row.provider} / ${row.event_id}?将按原始事件体重新执行业务处理,成功后事件状态置为 done。`,
      '确认重放',
      { type: 'warning' },
    )
  } catch {
    return
  }
  replaying.value = true
  try {
    await api(
      'POST',
      `/api/v1/webhook-events/${encodeURIComponent(row.provider)}/${encodeURIComponent(row.event_id)}/replay`,
    )
    showToast('重放成功')
    await loadRows(page.value)
    if (detailVisible.value && currentDetail.value?.event_id === row.event_id) {
      await openDetail(row)
    }
  } catch (e) {
    showToast(errMsg(e, '重放失败'), 'error')
    await loadRows(page.value)
  } finally {
    replaying.value = false
  }
}

onMounted(() => loadRows(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">Webhook 事件</div>
      <div class="page-subtitle">支付渠道回调事件台账:验签 → 落库 → 幂等处理;failed 事件可在核对后重放。</div>
    </div>
    <div class="ph-actions">
      <el-button :icon="Refresh" @click="loadRows(page)">刷新</el-button>
    </div>
  </div>

  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-select v-model="filters.provider" placeholder="全部渠道" style="max-width:170px" clearable>
        <el-option label="全部渠道" value="" />
        <el-option label="creem" value="creem" />
        <el-option label="zpay" value="zpay" />
        <el-option label="apple" value="apple" />
      </el-select>
      <el-select v-model="filters.status" placeholder="全部状态" style="max-width:170px" clearable>
        <el-option label="全部状态" value="" />
        <el-option label="已接收" value="received" />
        <el-option label="处理中" value="processing" />
        <el-option label="已处理" value="done" />
        <el-option label="失败" value="failed" />
      </el-select>
      <el-button type="primary" :icon="Search" @click="loadRows(1)">搜索</el-button>
    </div>

    <el-table v-loading="loading" :data="rows" stripe>
      <el-table-column prop="provider" label="渠道" width="90" />
      <el-table-column label="事件 ID" min-width="220"><template #default="{ row }"><code>{{ row.event_id }}</code></template></el-table-column>
      <el-table-column label="状态" width="100">
        <template #default="{ row }">
          <span class="badge" :class="`badge-${STATUS_BADGES[row.status] || 'muted'}`">{{ STATUS_LABELS[row.status] || row.status }}</span>
        </template>
      </el-table-column>
      <el-table-column label="验签" width="80">
        <template #default="{ row }">
          <span class="badge" :class="row.signature_ok ? 'badge-success' : 'badge-danger'">{{ row.signature_ok ? '通过' : '失败' }}</span>
        </template>
      </el-table-column>
      <el-table-column label="接收时间" width="170"><template #default="{ row }">{{ fmtTime(row.received_at) }}</template></el-table-column>
      <el-table-column label="错误摘要" min-width="220">
        <template #default="{ row }"><span class="error-text">{{ row.error || '-' }}</span></template>
      </el-table-column>
      <el-table-column label="操作" width="150" fixed="right">
        <template #default="{ row }">
          <el-button size="small" @click="openDetail(row)">详情</el-button>
          <el-button v-if="row.status === 'failed'" size="small" type="danger" plain :loading="replaying" @click="replayEvent(row)">重放</el-button>
        </template>
      </el-table-column>
      <template #empty>
        <div class="empty-state">
          <div class="empty-title">暂无 webhook 事件</div>
          <div class="empty-hint">调整渠道或状态筛选条件后再试。</div>
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

  <el-drawer v-model="detailVisible" title="Webhook 事件详情" size="56%">
    <div v-loading="detailLoading">
      <template v-if="currentDetail">
        <div class="kv-grid">
          <div>渠道</div><strong>{{ currentDetail.provider }}</strong>
          <div>事件 ID</div><strong><code>{{ currentDetail.event_id }}</code></strong>
          <div>状态</div>
          <strong><span class="badge" :class="`badge-${STATUS_BADGES[currentDetail.status] || 'muted'}`">{{ STATUS_LABELS[currentDetail.status] || currentDetail.status }}</span></strong>
          <div>验签</div>
          <strong><span class="badge" :class="currentDetail.signature_ok ? 'badge-success' : 'badge-danger'">{{ currentDetail.signature_ok ? '通过' : '失败' }}</span></strong>
          <div>接收时间</div><strong>{{ fmtTime(currentDetail.received_at) }}</strong>
          <div>处理时间</div><strong>{{ fmtTime(currentDetail.processed_at) }}</strong>
        </div>

        <template v-if="currentDetail.error">
          <div class="card-title" style="margin-top:16px">错误信息</div>
          <pre class="code-block error-block">{{ currentDetail.error }}</pre>
        </template>

        <div class="card-title" style="margin-top:16px">原始事件体 raw</div>
        <pre class="code-block">{{ JSON.stringify(currentDetail.raw ?? {}, null, 2) }}</pre>

        <template v-if="currentDetail.result">
          <div class="card-title" style="margin-top:16px">处理结果 result</div>
          <pre class="code-block">{{ JSON.stringify(currentDetail.result, null, 2) }}</pre>
        </template>

        <div v-if="currentDetail.status === 'failed'" style="margin-top:18px">
          <el-button type="danger" :loading="replaying" @click="replayEvent(currentDetail)">重放该事件</el-button>
        </div>
      </template>
    </div>
  </el-drawer>
</template>

<style scoped>
.page-subtitle { color: var(--text-muted); font-size: 13px; margin-bottom: 16px; }
.error-text {
  display: inline-block;
  max-width: 100%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--danger);
  font-size: 12px;
  vertical-align: middle;
}
.kv-grid { display: grid; grid-template-columns: 100px 1fr; gap: 8px 14px; font-size: 13px; color: var(--text-muted); }
.kv-grid strong { color: var(--text); word-break: break-all; }
.code-block { max-height: 360px; overflow: auto; background: rgba(0,0,0,.22); border: 1px solid var(--border); border-radius: 8px; padding: 12px; color: var(--text-muted); font-size: 12px; white-space: pre-wrap; word-break: break-all; }
.error-block { color: var(--danger); }
</style>
