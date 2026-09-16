<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { ElMessageBox } from 'element-plus'
import { Search } from '@element-plus/icons-vue'
import { api } from '@/api'
import { fmtTime } from '@/utils/format'
import { showToast } from '@/utils/toast'
import { PAYMENT_ORDER_STATUS_LABELS, REFUND_STATUS_LABELS, zhLabel } from '@/utils/labels'

interface OrderRow {
  order_id: string; user_email: string; product_name?: string; product_code?: string
  paid_amount_cents?: number; amount_cents: number; currency?: string
  payment_method?: string; payment_channel?: string; status: string
  refunded_amount_cents?: number; created_at: string
  settlement_mode?: string; change_mode?: string
  list_price_cents?: number; upgrade_credit_cents?: number
}
interface RefundRow {
  refund_id: string; refund_mode?: string; reason_label?: string; reason?: string
  amount_cents: number; currency?: string; status: string; created_at: string
  business_result?: { status?: string }
}
interface OrderDetail {
  order: OrderRow & { provider?: string }
  refunds?: RefundRow[]
  attempts?: unknown[]
  transactions?: unknown[]
}

const filters = ref({ email: '', status: '' })
const rows = ref<OrderRow[]>([])
const page = ref(1)
const total = ref(0)

const detailVisible = ref(false)
const currentOrderId = ref('')
const currentDetail = ref<OrderDetail | null>(null)
const canRefund = ref(false)

const refundVisible = ref(false)
const refundForm = ref({
  mode: 'full', amount: '', revoke: false,
  reasonCode: 'customer_request', reasonNote: '',
})

const SETTLEMENT_MODE_LABELS: Record<string, string> = { full_price: '全价', prorated_difference: '补差价' }
const CHANGE_MODE_LABELS: Record<string, string> = { new: '新购', renew: '续费', cycle_upgrade: '账期升级', activate_now: '立即升级' }

function money(cents?: number, currency?: string): string {
  return `${currency || ''} ${((parseInt(String(cents)) || 0) / 100).toFixed(2)}`
}

async function loadRows(p = 1) {
  page.value = p
  const q = new URLSearchParams({ page: String(p), page_size: '20' })
  if (filters.value.email.trim()) q.set('email', filters.value.email.trim())
  if (filters.value.status) q.set('status', filters.value.status)
  try {
    const data = await api<{ items: OrderRow[]; total: number }>('GET', `/api/v1/payment-provider-config/orders?${q}`)
    rows.value = data.items || []
    total.value = data.total || 0
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

async function openOrder(id: string) {
  currentOrderId.value = id
  try {
    const data = await api<OrderDetail>('GET', `/api/v1/payment-provider-config/orders/${encodeURIComponent(id)}`)
    currentDetail.value = data
    canRefund.value = ['paid', 'partially_refunded'].includes(String(data.order?.status || ''))
    detailVisible.value = true
  } catch (e) {
    showToast(e instanceof Error ? e.message : '加载失败', 'error')
  }
}

function openRefundPanel() {
  if (!currentOrderId.value) return
  refundForm.value = { mode: 'full', amount: '', revoke: false, reasonCode: 'customer_request', reasonNote: '' }
  refundVisible.value = true
}

async function submitRefund() {
  if (!currentOrderId.value) return
  const { mode, amount, revoke, reasonCode, reasonNote } = refundForm.value
  const payload: Record<string, unknown> = {
    refund_mode: mode,
    reason_code: reasonCode || 'other',
    reason_note: reasonNote,
    revoke_entitlement: revoke,
  }
  if (mode === 'partial') {
    const amt = Number(amount)
    if (!amt || amt <= 0) return showToast('请填写有效退款金额', 'error')
    payload.amount_cents = Math.round(amt * 100)
  }
  try {
    await ElMessageBox.confirm('确认按原支付渠道发起退款？成功后会立即同步订单和套餐权益。', '确认退款')
    await api('POST', `/api/v1/payment-provider-config/orders/${encodeURIComponent(currentOrderId.value)}/refund`, payload)
    refundVisible.value = false
    showToast('退款已提交')
    await openOrder(currentOrderId.value)
    await loadRows(page.value)
  } catch (e) {
    if (e !== 'cancel') showToast(e instanceof Error ? e.message : '退款失败', 'error')
  }
}

onMounted(() => loadRows(1))
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">支付订单</div>
      <div class="page-subtitle">按订单追踪支付、渠道交易与退款状态；退款将调用原支付渠道并同步处理套餐权益。</div>
    </div>
  </div>

  <div class="card">
    <div class="search-bar" style="flex-wrap:wrap;gap:8px">
      <el-input v-model="filters.email" placeholder="按用户邮箱搜索" style="max-width:240px" clearable />
      <el-select v-model="filters.status" placeholder="全部状态" style="max-width:180px" clearable>
        <el-option label="全部状态" value="" />
        <el-option label="待支付" value="pending_payment" />
        <el-option label="已支付" value="paid" />
        <el-option label="失败" value="failed" />
        <el-option label="退款中" value="refunding" />
        <el-option label="部分退款" value="partially_refunded" />
        <el-option label="已退款" value="refunded" />
      </el-select>
      <el-button type="primary" :icon="Search" @click="loadRows(1)">搜索</el-button>
    </div>

    <el-table :data="rows" stripe>
      <el-table-column label="订单号" width="180"><template #default="{ row }"><code>{{ row.order_id }}</code></template></el-table-column>
      <el-table-column prop="user_email" label="用户" min-width="160" />
      <el-table-column label="商品" min-width="120"><template #default="{ row }">{{ row.product_name || row.product_code }}</template></el-table-column>
      <el-table-column label="金额" width="120" align="right"><template #default="{ row }"><span class="amount">{{ money(row.paid_amount_cents || row.amount_cents, row.currency) }}</span></template></el-table-column>
      <el-table-column label="方式/渠道" width="140"><template #default="{ row }">{{ row.payment_method || '-' }} / {{ row.payment_channel || '-' }}</template></el-table-column>
      <el-table-column label="结算方式" width="100"><template #default="{ row }"><el-tag v-if="row.settlement_mode" size="small" :type="row.settlement_mode === 'prorated_difference' ? 'warning' : 'info'">{{ SETTLEMENT_MODE_LABELS[row.settlement_mode] || row.settlement_mode }}</el-tag><span v-else>-</span></template></el-table-column>
      <el-table-column label="状态" width="120"><template #default="{ row }"><span class="badge" :class="`badge-${(({ paid: 'success', pending_payment: 'warning', refunding: 'warning', partially_refunded: 'info', failed: 'danger', refunded: 'muted' } as Record<string, string>)[row.status] || 'muted')}`">{{ zhLabel(PAYMENT_ORDER_STATUS_LABELS, row.status) }}</span></template></el-table-column>
      <el-table-column label="退款" width="100" align="right">
        <template #default="{ row }"><span class="amount">{{ parseInt(String(row.refunded_amount_cents || 0)) > 0 ? money(row.refunded_amount_cents, row.currency) : '-' }}</span></template>
      </el-table-column>
      <el-table-column label="创建时间" width="170"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
      <el-table-column label="操作" width="80" fixed="right">
        <template #default="{ row }"><el-button size="small" @click="openOrder(row.order_id)">详情</el-button></template>
      </el-table-column>
      <template #empty>
        <div class="empty-state">
          <div class="empty-title">暂无支付订单</div>
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

  <el-dialog v-model="detailVisible" title="订单详情" width="980px">
    <template v-if="currentDetail?.order">
      <div class="detail-section">
        <div class="card-title">基础信息</div>
        <div class="kv-grid">
          <div>订单号</div><strong><code>{{ currentDetail.order.order_id }}</code></strong>
          <div>用户</div><strong>{{ currentDetail.order.user_email }}</strong>
          <div>商品</div><strong>{{ currentDetail.order.product_name || currentDetail.order.product_code }}</strong>
          <div>订单金额</div><strong><span class="amount">{{ money(currentDetail.order.amount_cents, currentDetail.order.currency) }}</span></strong>
          <div>实付金额</div><strong><span class="amount">{{ money(currentDetail.order.paid_amount_cents || currentDetail.order.amount_cents, currentDetail.order.currency) }}</span></strong>
          <div>订单状态</div><strong><span class="badge" :class="`badge-${({ paid: 'success', pending_payment: 'warning', refunding: 'warning', partially_refunded: 'info', failed: 'danger', refunded: 'muted' }[currentDetail.order.status] || 'muted')}`">{{ zhLabel(PAYMENT_ORDER_STATUS_LABELS, currentDetail.order.status) }}</span></strong>
          <div>支付渠道</div><strong>{{ currentDetail.order.provider }} / {{ currentDetail.order.payment_channel || '-' }}</strong>
          <div>支付方式</div><strong>{{ currentDetail.order.payment_method || '-' }}</strong>
          <div>结算方式</div><strong>{{ currentDetail.order.settlement_mode ? (SETTLEMENT_MODE_LABELS[currentDetail.order.settlement_mode] || currentDetail.order.settlement_mode) : '-' }}</strong>
          <div>变更类型</div><strong>{{ currentDetail.order.change_mode ? (CHANGE_MODE_LABELS[currentDetail.order.change_mode] || currentDetail.order.change_mode) : '-' }}</strong>
          <template v-if="currentDetail.order.list_price_cents != null">
            <div>目录原价</div><strong><span class="amount">{{ money(currentDetail.order.list_price_cents, currentDetail.order.currency) }}</span></strong>
          </template>
          <template v-if="currentDetail.order.upgrade_credit_cents != null">
            <div>升级抵扣</div><strong><span class="amount">{{ money(currentDetail.order.upgrade_credit_cents, currentDetail.order.currency) }}</span></strong>
          </template>
        </div>
      </div>
      <div class="detail-section">
        <div class="card-title">退款记录</div>
        <el-table v-if="currentDetail.refunds?.length" :data="currentDetail.refunds" stripe size="small">
          <el-table-column label="退款号"><template #default="{ row }"><code>{{ row.refund_id }}</code></template></el-table-column>
          <el-table-column prop="refund_mode" label="方式" />
          <el-table-column label="原因"><template #default="{ row }">{{ row.reason_label || row.reason || '-' }}</template></el-table-column>
          <el-table-column label="金额" align="right"><template #default="{ row }"><span class="amount">{{ money(row.amount_cents, row.currency) }}</span></template></el-table-column>
          <el-table-column label="状态"><template #default="{ row }"><span class="badge" :class="`badge-${(({ refunded: 'success', processing: 'warning', refunding: 'warning', partially_refunded: 'info', failed: 'danger' } as Record<string, string>)[row.status] || 'muted')}`">{{ zhLabel(REFUND_STATUS_LABELS, row.status) }}</span></template></el-table-column>
          <el-table-column label="业务处理"><template #default="{ row }">{{ row.business_result?.status || '-' }}</template></el-table-column>
          <el-table-column label="时间"><template #default="{ row }">{{ fmtTime(row.created_at) }}</template></el-table-column>
        </el-table>
        <div v-else class="empty-hint">暂无退款</div>
      </div>
      <div class="detail-section">
        <div class="card-title">支付尝试</div>
        <pre class="code-block">{{ JSON.stringify(currentDetail.attempts || [], null, 2) }}</pre>
      </div>
      <div class="detail-section">
        <div class="card-title">支付事件</div>
        <pre class="code-block">{{ JSON.stringify(currentDetail.transactions || [], null, 2) }}</pre>
      </div>
    </template>
    <template #footer>
      <el-button type="danger" :disabled="!canRefund" @click="openRefundPanel">发起退款</el-button>
      <el-button @click="detailVisible = false">关闭</el-button>
    </template>
  </el-dialog>

  <el-dialog v-model="refundVisible" title="发起原渠道退款" width="620px">
    <el-form label-width="100px">
      <el-form-item label="退款方式">
        <el-select v-model="refundForm.mode" style="width:100%">
          <el-option label="全额退款" value="full" />
          <el-option label="按剩余价值比例退款" value="prorated" />
          <el-option label="固定金额退款" value="partial" />
        </el-select>
      </el-form-item>
      <el-form-item label="固定金额">
        <el-input v-model="refundForm.amount" :disabled="refundForm.mode !== 'partial'" placeholder="仅固定金额退款填写，例如 9.99" />
      </el-form-item>
      <el-form-item label="业务处理">
        <el-checkbox v-model="refundForm.revoke">退款成功后取消当前套餐权益并重置积分</el-checkbox>
      </el-form-item>
      <el-form-item label="退款原因">
        <el-select v-model="refundForm.reasonCode" style="width:100%">
          <el-option label="用户主动申请" value="customer_request" />
          <el-option label="重复购买" value="duplicate_purchase" />
          <el-option label="支付异常" value="payment_error" />
          <el-option label="服务不可用或体验问题" value="service_issue" />
          <el-option label="风控或异常订单" value="fraud_risk" />
          <el-option label="管理员调整" value="admin_adjustment" />
          <el-option label="其他" value="other" />
        </el-select>
      </el-form-item>
      <el-form-item label="原因备注">
        <el-input v-model="refundForm.reasonNote" type="textarea" :rows="3" placeholder="补充具体退款原因，便于审计和客服追踪" />
      </el-form-item>
    </el-form>
    <div class="hint-box">按比例退款采用"剩余时长比例"和"剩余套餐积分比例"中的较小值计算，避免用户已消耗大量积分但仍按时间高额退款。</div>
    <template #footer>
      <el-button type="danger" @click="submitRefund">确认退款</el-button>
      <el-button @click="refundVisible = false">取消</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.page-subtitle { color: var(--text-muted); font-size: 13px; margin-bottom: 16px; }
.code-block { max-height: 260px; overflow: auto; background: rgba(0,0,0,.22); border: 1px solid var(--border); border-radius: 8px; padding: 12px; color: var(--text-muted); font-size: 12px; }
.detail-section { margin-top: 14px; }
.kv-grid { display: grid; grid-template-columns: 120px 1fr; gap: 8px 14px; font-size: 13px; color: var(--text-muted); }
.kv-grid strong { color: var(--text); }
.hint-box { margin-top: 12px; color: var(--text-muted); font-size: 12px; line-height: 1.6; }
.empty-hint { color: var(--text-muted); font-size: 13px; padding: 10px 0; }
.amount { font-variant-numeric: tabular-nums; font-weight: 600; }
</style>
