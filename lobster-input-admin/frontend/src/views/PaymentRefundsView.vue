<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { Search } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'
import { PAYMENT_ORDER_STATUS_LABELS, REFUND_STATUS_LABELS, zhLabel } from '@/utils/labels'

interface RefundRow {
  refund_id: string; order_id: string; user_email: string
  refund_mode?: string; reason_label?: string; reason?: string
  amount_cents: number; currency?: string; status: string
  provider_refund_id?: string; created_at: string
}
interface RefundDetail {
  refund: Record<string, unknown>
  order: Record<string, unknown>
  payment_event: Record<string, unknown>
}

const filters = ref({ email: '', status: '' })
const rows = ref<RefundRow[]>([])
const page = ref(1)
const total = ref(0)
const detailVisible = ref(false)
const detailData = ref<RefundDetail | null>(null)

const SETTLEMENT_MODE_LABELS: Record<string, string> = { full_price: '全价', prorated_difference: '补差价' }

function money(cents?: number, currency?: string): string {
  return `${currency || ''} ${((parseInt(String(cents)) || 0) / 100).toFixed(2)}`
}

async function loadRows(p = 1) {
  page.value = p
  const q = new URLSearchParams({ page: String(p), page_size: '20' })
  if (filters.value.email.trim()) q.set('email', filters.value.email.trim())
  if (filters.value.status) q.set('status', filters.value.status)
  try {
    const data = await api<{ items: RefundRow[]; total: number }>('GET', `/api/v1/payment-provider-config/refunds?${q}`)
    rows.value = data.items || []
    total.value = data.total || 0
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

async function openRefund(id: string) {
  try {
    detailData.value = await api<RefundDetail>('GET', `/api/v1/payment-provider-config/refunds/${encodeURIComponent(id)}`)
    detailVisible.value = true
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

onMounted(() => loadRows(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">退款管理</div>
      <div class="page-subtitle">查看退款原因、渠道退款结果、金额计算与业务权益处理明细。</div>
    </div>
  </div>

  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="按用户邮箱搜索" style="max-width:240px" clearable />
      <el-select v-model="filters.status" placeholder="全部状态" style="max-width:180px" clearable>
        <el-option label="全部状态" value="" />
        <el-option label="处理中" value="processing" />
        <el-option label="部分退款" value="partially_refunded" />
        <el-option label="已退款" value="refunded" />
        <el-option label="失败" value="failed" />
      </el-select>
      <el-button type="primary" :icon="Search" @click="loadRows(1)">搜索</el-button>
    </div>

    <el-table :data="rows" stripe>
      <el-table-column label="退款号" width="160"><template #default="{ row }"><code>{{ row.refund_id }}</code></template></el-table-column>
      <el-table-column label="订单号" width="160"><template #default="{ row }"><code>{{ row.order_id }}</code></template></el-table-column>
      <el-table-column prop="user_email" label="用户" min-width="160" />
      <el-table-column prop="refund_mode" label="方式" width="100"><template #default="{ row }">{{ row.refund_mode || '-' }}</template></el-table-column>
      <el-table-column label="原因" width="140"><template #default="{ row }">{{ row.reason_label || row.reason || '-' }}</template></el-table-column>
      <el-table-column label="金额" width="120" align="right"><template #default="{ row }"><span class="amount">{{ money(row.amount_cents, row.currency) }}</span></template></el-table-column>
      <el-table-column label="状态" width="100"><template #default="{ row }"><span class="badge" :class="`badge-${(({ refunded: 'success', processing: 'warning', refunding: 'warning', partially_refunded: 'info', failed: 'danger' } as Record<string, string>)[row.status] || 'muted')}`">{{ zhLabel(REFUND_STATUS_LABELS, row.status) }}</span></template></el-table-column>
      <el-table-column label="渠道退款号" width="140"><template #default="{ row }">{{ row.provider_refund_id || '-' }}</template></el-table-column>
      <el-table-column label="创建时间" width="170"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
      <el-table-column label="操作" width="80" fixed="right">
        <template #default="{ row }"><el-button size="small" @click="openRefund(row.refund_id)">明细</el-button></template>
      </el-table-column>
      <template #empty>
        <div class="empty-state">
          <div class="empty-title">暂无退款记录</div>
          <div class="empty-hint">调整邮箱或状态筛选条件后再试。</div>
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

  <el-dialog v-model="detailVisible" title="退款明细" width="980px">
    <template v-if="detailData">
      <div class="detail-section">
        <div class="card-title">退款信息</div>
        <div class="kv-grid">
          <div>退款号</div><strong><code>{{ detailData.refund.refund_id }}</code></strong>
          <div>订单号</div><strong><code>{{ detailData.refund.order_id }}</code></strong>
          <div>用户</div><strong>{{ detailData.refund.user_email }}</strong>
          <div>退款方式</div><strong>{{ detailData.refund.refund_mode }}</strong>
          <div>退款金额</div><strong><span class="amount">{{ money(Number(detailData.refund.amount_cents), String(detailData.refund.currency || '')) }}</span></strong>
          <div>状态</div><strong><span class="badge" :class="`badge-${({ refunded: 'success', processing: 'warning', refunding: 'warning', partially_refunded: 'info', failed: 'danger' }[String(detailData.refund.status)] || 'muted')}`">{{ zhLabel(REFUND_STATUS_LABELS, detailData.refund.status) }}</span></strong>
          <div>标准原因</div><strong>{{ detailData.refund.reason_label || detailData.refund.reason_code || '-' }}</strong>
          <div>原因备注</div><strong>{{ detailData.refund.reason_note || '-' }}</strong>
          <div>渠道退款号</div><strong>{{ detailData.refund.provider_refund_id || '-' }}</strong>
          <div>权益处理</div><strong>{{ (detailData.refund.business_result as { status?: string })?.status || '-' }}</strong>
        </div>
      </div>
      <div class="detail-section">
        <div class="card-title">订单摘要</div>
        <div class="kv-grid">
          <div>商品</div><strong>{{ detailData.order.product_name || detailData.order.product_code || '-' }}</strong>
          <div>订单金额</div><strong><span class="amount">{{ money(Number(detailData.order.amount_cents), String(detailData.order.currency || '')) }}</span></strong>
          <div>实付金额</div><strong><span class="amount">{{ money(Number(detailData.order.paid_amount_cents || detailData.order.amount_cents), String(detailData.order.currency || '')) }}</span></strong>
          <div>订单状态</div><strong><span class="badge" :class="`badge-${({ paid: 'success', pending_payment: 'warning', refunding: 'warning', partially_refunded: 'info', failed: 'danger', refunded: 'muted' }[String(detailData.order.status)] || 'muted')}`">{{ zhLabel(PAYMENT_ORDER_STATUS_LABELS, detailData.order.status) }}</span></strong>
          <div>支付渠道</div><strong>{{ detailData.order.provider || '-' }} / {{ detailData.order.payment_channel || '-' }}</strong>
          <div>支付方式</div><strong>{{ detailData.order.payment_method || '-' }}</strong>
          <template v-if="detailData.order.settlement_mode">
            <div>结算方式</div><strong>{{ SETTLEMENT_MODE_LABELS[String(detailData.order.settlement_mode)] || detailData.order.settlement_mode }}</strong>
          </template>
          <template v-if="detailData.order.upgrade_credit_cents != null">
            <div>升级抵扣</div><strong><span class="amount">{{ money(Number(detailData.order.upgrade_credit_cents), String(detailData.order.currency || '')) }}</span></strong>
          </template>
        </div>
      </div>
      <div class="detail-section">
        <div class="card-title">金额计算</div>
        <pre class="code-block">{{ JSON.stringify(detailData.refund.calculation || {}, null, 2) }}</pre>
      </div>
      <div class="detail-section">
        <div class="card-title">渠道退款结果</div>
        <pre class="code-block">{{ JSON.stringify(detailData.refund.provider_refund_result || {}, null, 2) }}</pre>
      </div>
      <div class="detail-section">
        <div class="card-title">业务处理结果</div>
        <pre class="code-block">{{ JSON.stringify(detailData.refund.business_result || {}, null, 2) }}</pre>
      </div>
      <div class="detail-section">
        <div class="card-title">失败原因</div>
        <pre class="code-block">{{ JSON.stringify(detailData.refund.error || {}, null, 2) }}</pre>
      </div>
      <div class="detail-section">
        <div class="card-title">原支付事件</div>
        <pre class="code-block">{{ JSON.stringify(detailData.payment_event || {}, null, 2) }}</pre>
      </div>
    </template>
  </el-dialog>
</template>

<style scoped>
.page-subtitle { color: var(--text-muted); font-size: 13px; margin-bottom: 16px; }
.code-block { max-height: 260px; overflow: auto; background: rgba(0,0,0,.22); border: 1px solid var(--border); border-radius: 8px; padding: 12px; color: var(--text-muted); font-size: 12px; }
.detail-section { margin-top: 14px; }
.kv-grid { display: grid; grid-template-columns: 120px 1fr; gap: 8px 14px; font-size: 13px; color: var(--text-muted); }
.kv-grid strong { color: var(--text); }
.amount { font-variant-numeric: tabular-nums; font-weight: 600; }
</style>
