<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { Refresh, Upload } from '@element-plus/icons-vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

// ---------------------------------------------------------------------------
// 类型(与业务后端 /api/v1/config/billing-* 计费重构后契约一致,
// 见 lobster-input-backend/docs/billing-plan-refactor-design.md "附:阶段A")
// ---------------------------------------------------------------------------

// 节点单价规则:ASR/LLM 按业务节点单一价(无 provider),web_search 保留 provider 作为特例。
interface BillingRule {
  node_id: string
  category: string
  provider_id?: string | null
  unit: string
  credits: number
  enabled: boolean
}

// 全局策略(阈值仅用于毛利监控着色,不做保存拦截)。
interface PricingPolicy {
  image_surcharge_credits: number
  margin_target_ratio: number
  margin_alert_ratio: number
}

// 上游参考成本表(仅供毛利监控,不参与扣费)。
interface ProviderCost {
  node_id: string
  provider_id: string
  platform_code?: string
  model?: string
  unit: string
  upstream_cost_cny: number | null
  cost_source?: string
  updated_at?: string
}

// 只读毛利监控报表。
type CellStatus = 'green' | 'yellow' | 'red' | 'unknown'

interface ReportProvider {
  provider_id: string
  platform_code?: string
  upstream_cost_cny: number | null
  credits: number
  margin: number | null
  status: CellStatus
}

interface ReportNode {
  node_id: string
  unit: string
  credits: number
  providers: ReportProvider[]
}

interface GlobalMinPrice {
  plan_code: string
  cycle: string
  credit_sale_price_cny: number
}

interface MarginReport {
  nodes?: ReportNode[]
  global_min_credit_sale_price?: GlobalMinPrice | null
  policy?: Partial<PricingPolicy>
}

interface RulesResponse {
  rules?: unknown
  policy?: Partial<PricingPolicy>
}

interface ProviderCostsResponse {
  costs?: unknown
}

interface SaveResponse {
  saved?: boolean
}

// ---------------------------------------------------------------------------
// 常量 / 默认策略
// ---------------------------------------------------------------------------

const UNITS = ['minute', '1k_tokens', 'request']

function defaultPolicy(): PricingPolicy {
  return {
    image_surcharge_credits: 15,
    margin_target_ratio: 0.75,
    margin_alert_ratio: 0.3,
  }
}

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------

const loading = ref(false)
const savingRules = ref(false)
const savingCosts = ref(false)
const rules = ref<BillingRule[]>([])
const policy = ref<PricingPolicy>(defaultPolicy())
const costs = ref<ProviderCost[]>([])
const report = ref<MarginReport>({})
const rulesDirty = ref(false)
const costsDirty = ref(false)

// ---------------------------------------------------------------------------
// 加载 / 归一化
// ---------------------------------------------------------------------------

function normalizeRules(raw: unknown): BillingRule[] {
  const arr = Array.isArray(raw) ? raw : []
  return (arr as Record<string, unknown>[]).map((r) => ({
    node_id: String(r.node_id ?? ''),
    category: String(r.category ?? ''),
    provider_id: r.provider_id == null || r.provider_id === '' ? null : String(r.provider_id),
    unit: String(r.unit ?? ''),
    credits: Number(r.credits ?? 0),
    enabled: r.enabled !== false,
  }))
}

function normalizePolicy(raw: Partial<PricingPolicy> | undefined | null): PricingPolicy {
  const d = defaultPolicy()
  if (!raw || typeof raw !== 'object') return d
  return {
    image_surcharge_credits: Number(raw.image_surcharge_credits ?? d.image_surcharge_credits),
    margin_target_ratio: Number(raw.margin_target_ratio ?? d.margin_target_ratio),
    margin_alert_ratio: Number(raw.margin_alert_ratio ?? d.margin_alert_ratio),
  }
}

function normalizeCosts(raw: unknown): ProviderCost[] {
  const arr = Array.isArray(raw) ? raw : []
  return (arr as Record<string, unknown>[]).map((c) => ({
    node_id: String(c.node_id ?? ''),
    provider_id: String(c.provider_id ?? ''),
    platform_code: c.platform_code == null ? '' : String(c.platform_code),
    model: c.model == null ? '' : String(c.model),
    unit: String(c.unit ?? ''),
    upstream_cost_cny: c.upstream_cost_cny == null ? null : Number(c.upstream_cost_cny),
    cost_source: c.cost_source == null ? '' : String(c.cost_source),
    updated_at: c.updated_at == null ? '' : String(c.updated_at),
  }))
}

async function loadAll(): Promise<void> {
  loading.value = true
  try {
    const [rulesRes, costsRes, reportRes] = await Promise.all([
      api<RulesResponse>('GET', '/api/v1/billing-margin/rules'),
      api<ProviderCostsResponse>('GET', '/api/v1/billing-margin/provider-costs').catch(
        () => ({}) as ProviderCostsResponse,
      ),
      api<MarginReport>('GET', '/api/v1/billing-margin/report').catch(() => ({}) as MarginReport),
    ])
    rules.value = normalizeRules(rulesRes?.rules)
    policy.value = normalizePolicy(rulesRes?.policy ?? reportRes?.policy)
    costs.value = normalizeCosts(costsRes?.costs)
    report.value = reportRes || {}
    rulesDirty.value = false
    costsDirty.value = false
  } catch (e) {
    showToast((e as Error).message, 'error')
  } finally {
    loading.value = false
  }
}

// ---------------------------------------------------------------------------
// 只读毛利监控(直接渲染 report.nodes,每 provider 的 margin 按 status 着色)
// ---------------------------------------------------------------------------

const reportNodes = computed<ReportNode[]>(() => report.value.nodes || [])
const globalMin = computed<GlobalMinPrice | null>(
  () => report.value.global_min_credit_sale_price ?? null,
)

function statusClass(status: CellStatus | undefined): string {
  switch (status) {
    case 'green':
      return 'mg-green'
    case 'yellow':
      return 'mg-yellow'
    case 'red':
      return 'mg-red'
    default:
      return 'mg-na'
  }
}

function fmtPct(v: number | null | undefined): string {
  if (v == null || !isFinite(v)) return '—'
  return `${(v * 100).toFixed(1)}%`
}

function fmtPrice(v: number | null | undefined, digits = 4): string {
  if (v == null || !isFinite(v)) return '—'
  return `¥${v.toFixed(digits)}`
}

// ---------------------------------------------------------------------------
// 节点单价编辑 / 成本表编辑
// ---------------------------------------------------------------------------

function markRulesDirty(): void {
  rulesDirty.value = true
}

function markCostsDirty(): void {
  costsDirty.value = true
}

function buildRulesPayload(): BillingRule[] {
  return rules.value.map((r) => ({
    ...r,
    provider_id: r.provider_id == null || r.provider_id === '' ? null : r.provider_id,
    credits: Math.max(0, Math.round(Number(r.credits) || 0)),
  }))
}

async function saveRules(): Promise<void> {
  savingRules.value = true
  try {
    const res = await api<SaveResponse>('POST', '/api/v1/billing-margin/rules', {
      rules: buildRulesPayload(),
      policy: { ...policy.value },
    })
    if (res?.saved === false) {
      showToast('保存未生效,请重试', 'error')
      return
    }
    showToast('节点单价与策略已保存')
    rulesDirty.value = false
    await loadAll()
  } catch (e) {
    showToast((e as Error).message, 'error')
  } finally {
    savingRules.value = false
  }
}

function buildCostsPayload(): ProviderCost[] {
  return costs.value.map((c) => ({
    ...c,
    upstream_cost_cny:
      c.upstream_cost_cny == null || (c.upstream_cost_cny as unknown) === ''
        ? null
        : Number(c.upstream_cost_cny),
  }))
}

async function saveCosts(): Promise<void> {
  savingCosts.value = true
  try {
    const res = await api<SaveResponse>('POST', '/api/v1/billing-margin/provider-costs', {
      costs: buildCostsPayload(),
    })
    if (res?.saved === false) {
      showToast('保存未生效,请重试', 'error')
      return
    }
    showToast('上游成本表已保存')
    costsDirty.value = false
    await loadAll()
  } catch (e) {
    showToast((e as Error).message, 'error')
  } finally {
    savingCosts.value = false
  }
}

onMounted(loadAll)
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">计费经济性</div>
      <div class="page-subtitle">
        每业务节点一个稳定单价(同节点无论走哪个 provider 用户扣费一致);上游成本与毛利仅内部只读监控,不参与扣费、不拦截保存。
      </div>
    </div>
    <div class="ph-actions">
      <el-button :icon="Refresh" @click="loadAll">刷新</el-button>
    </div>
  </div>

  <div v-loading="loading">
    <!-- 1. 只读毛利监控 -->
    <div class="card">
      <div class="section-head">
        <span class="section-title">毛利监控(只读)</span>
        <div class="kpis">
          <span class="kpi">
            全局最低每积分售价
            <b>{{ fmtPrice(globalMin?.credit_sale_price_cny, 6) }}</b>
            <small v-if="globalMin">（{{ globalMin.plan_code }}/{{ globalMin.cycle }}）</small>
          </span>
          <span class="kpi">
            目标毛利
            <b>{{ fmtPct(policy.margin_target_ratio) }}</b>
          </span>
          <span class="kpi">
            告警阈值
            <b>{{ fmtPct(policy.margin_alert_ratio) }}</b>
          </span>
        </div>
      </div>
      <div class="section-hint">
        毛利 = 1 − 上游成本 ÷（积分 × 全局最低每积分售价）。红绿灯为顾问性提示,不阻断任何配置、不影响用户扣费。
      </div>

      <div v-if="!reportNodes.length" class="empty-hint" style="padding: 16px 0">
        暂无毛利报表数据(需先录入各 provider 上游成本并保存)。
      </div>

      <div v-else class="matrix-scroll">
        <table class="matrix">
          <thead>
            <tr>
              <th class="sticky-col">节点</th>
              <th>计量</th>
              <th>积分</th>
              <th>Provider</th>
              <th>上游成本</th>
              <th>毛利</th>
              <th>状态</th>
            </tr>
          </thead>
          <tbody>
            <template v-for="node in reportNodes" :key="node.node_id">
              <tr v-if="!node.providers.length">
                <td class="sticky-col">
                  <div class="node-name">{{ node.node_id }}</div>
                </td>
                <td>{{ node.unit }}</td>
                <td>{{ node.credits }}</td>
                <td colspan="4" class="mg-na">未录入 provider 成本</td>
              </tr>
              <tr
                v-for="(p, i) in node.providers"
                :key="node.node_id + '/' + p.provider_id"
              >
                <td class="sticky-col">
                  <div v-if="i === 0" class="node-name">{{ node.node_id }}</div>
                </td>
                <td>{{ i === 0 ? node.unit : '' }}</td>
                <td>{{ i === 0 ? node.credits : '' }}</td>
                <td>
                  {{ p.provider_id }}
                  <small v-if="p.platform_code">· {{ p.platform_code }}</small>
                </td>
                <td>{{ p.upstream_cost_cny == null ? '未录入' : fmtPrice(p.upstream_cost_cny) }}</td>
                <td :class="statusClass(p.status)">{{ fmtPct(p.margin) }}</td>
                <td :class="statusClass(p.status)">
                  <span class="dot" :class="statusClass(p.status)"></span>
                </td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>

      <div class="legend">
        <span class="lg mg-green">绿:达标(≥{{ fmtPct(policy.margin_target_ratio) }})</span>
        <span class="lg mg-yellow">黄:偏低</span>
        <span class="lg mg-red">红:告警(&lt;{{ fmtPct(policy.margin_alert_ratio) }})</span>
        <span class="lg mg-na">无数据</span>
      </div>
    </div>

    <!-- 2. 节点单价编辑 + 全局策略 -->
    <div class="card">
      <div class="section-head">
        <span class="section-title">节点单价</span>
        <el-button
          type="primary"
          :icon="Upload"
          :loading="savingRules"
          :disabled="!rulesDirty"
          @click="saveRules"
        >
          保存单价与策略
        </el-button>
      </div>
      <div class="section-hint">
        每业务节点一行、一个稳定 credits。ASR/LLM 无 provider 维度;web_search 保留 provider 作为特例。保存不做毛利拦截。
      </div>

      <el-table :data="rules" size="small" border style="margin-top: 8px">
        <el-table-column label="节点" prop="node_id" min-width="200" fixed />
        <el-table-column label="分类" prop="category" width="130" />
        <el-table-column label="Provider(仅 web_search)" min-width="150">
          <template #default="{ row }">
            <span v-if="row.provider_id">{{ row.provider_id }}</span>
            <span v-else class="mg-na">—</span>
          </template>
        </el-table-column>
        <el-table-column label="计量" width="130">
          <template #default="{ row }">
            <el-select v-model="row.unit" size="small" @change="markRulesDirty">
              <el-option v-for="u in UNITS" :key="u" :label="u" :value="u" />
            </el-select>
          </template>
        </el-table-column>
        <el-table-column label="扣费积分" width="150" align="right">
          <template #default="{ row }">
            <el-input-number
              v-model="row.credits"
              :min="0"
              :step="10"
              size="small"
              controls-position="right"
              @change="markRulesDirty"
            />
          </template>
        </el-table-column>
        <el-table-column label="启用" width="80" align="center" fixed="right">
          <template #default="{ row }">
            <el-switch v-model="row.enabled" @change="markRulesDirty" />
          </template>
        </el-table-column>
      </el-table>

      <div class="policy-grid">
        <div class="policy-item">
          <span class="policy-label">每图附加积分</span>
          <el-input-number
            v-model="policy.image_surcharge_credits"
            :min="0"
            :step="1"
            size="small"
            controls-position="right"
            @change="markRulesDirty"
          />
        </div>
        <div class="policy-item">
          <span class="policy-label">目标毛利(监控着色)</span>
          <el-input-number
            v-model="policy.margin_target_ratio"
            :min="0"
            :max="0.99"
            :step="0.05"
            :precision="2"
            size="small"
            controls-position="right"
            @change="markRulesDirty"
          />
        </div>
        <div class="policy-item">
          <span class="policy-label">告警阈值(监控着色)</span>
          <el-input-number
            v-model="policy.margin_alert_ratio"
            :min="0"
            :max="0.99"
            :step="0.05"
            :precision="2"
            size="small"
            controls-position="right"
            @change="markRulesDirty"
          />
        </div>
      </div>
    </div>

    <!-- 3. 上游参考成本表 -->
    <div class="card">
      <div class="section-head">
        <span class="section-title">上游参考成本(仅供毛利监控)</span>
        <el-button
          type="primary"
          :icon="Upload"
          :loading="savingCosts"
          :disabled="!costsDirty"
          @click="saveCosts"
        >
          保存成本表
        </el-button>
      </div>
      <div class="section-hint">
        每节点可多条(一条一个 provider)。成本仅用于上方毛利监控着色,不参与用户扣费、不拦截任何保存。
      </div>

      <div v-if="!costs.length" class="empty-hint" style="padding: 12px 0">暂无成本记录。</div>

      <el-table v-else :data="costs" size="small" border style="margin-top: 8px">
        <el-table-column label="节点" prop="node_id" min-width="180" fixed />
        <el-table-column label="Provider" prop="provider_id" min-width="140" />
        <el-table-column label="平台" prop="platform_code" width="130" />
        <el-table-column label="模型" prop="model" min-width="130" />
        <el-table-column label="计量" width="120">
          <template #default="{ row }">
            <el-select v-model="row.unit" size="small" @change="markCostsDirty">
              <el-option v-for="u in UNITS" :key="u" :label="u" :value="u" />
            </el-select>
          </template>
        </el-table-column>
        <el-table-column label="上游成本(¥/单位)" width="170" align="right">
          <template #default="{ row }">
            <el-input-number
              v-model="row.upstream_cost_cny"
              :min="0"
              :step="0.001"
              :precision="4"
              size="small"
              controls-position="right"
              placeholder="未录入"
              @change="markCostsDirty"
            />
          </template>
        </el-table-column>
        <el-table-column label="成本来源" min-width="150">
          <template #default="{ row }">
            <el-input
              v-model="row.cost_source"
              size="small"
              placeholder="如 官方定价/账单"
              @input="markCostsDirty"
            />
          </template>
        </el-table-column>
      </el-table>
    </div>
  </div>
</template>

<style scoped>
.section-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px;
  margin-bottom: 8px;
}
.section-title {
  font-size: 15px;
  font-weight: 600;
}
.section-hint {
  color: var(--text-muted);
  font-size: 12px;
  margin-bottom: 4px;
}
.kpis {
  display: flex;
  gap: 20px;
  flex-wrap: wrap;
}
.kpi {
  font-size: 13px;
  color: var(--text-muted);
}
.kpi b {
  margin-left: 6px;
  font-size: 15px;
  color: var(--text-main, #303133);
}
.policy-grid {
  display: flex;
  gap: 24px;
  flex-wrap: wrap;
  margin-top: 14px;
}
.policy-item {
  display: flex;
  align-items: center;
  gap: 8px;
}
.policy-label {
  font-size: 13px;
  color: var(--text-muted);
}
.matrix-scroll {
  overflow-x: auto;
  margin-top: 8px;
}
.matrix {
  border-collapse: collapse;
  width: 100%;
  font-size: 13px;
}
.matrix th,
.matrix td {
  border: 1px solid var(--el-border-color, #ebeef5);
  padding: 6px 10px;
  text-align: center;
  white-space: nowrap;
}
.matrix thead th {
  background: var(--el-fill-color-light, #f5f7fa);
  font-weight: 600;
}
.matrix .sticky-col {
  position: sticky;
  left: 0;
  z-index: 1;
  background: var(--el-bg-color, #fff);
  text-align: left;
}
.matrix thead .sticky-col {
  background: var(--el-fill-color-light, #f5f7fa);
}
.node-name {
  font-weight: 600;
}
.dot {
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 50%;
}
.dot.mg-green {
  background: #16a34a;
}
.dot.mg-yellow {
  background: #d97706;
}
.dot.mg-red {
  background: #dc2626;
}
.dot.mg-na {
  background: #cbd5e1;
}
.mg-green {
  color: #15803d;
  font-weight: 600;
}
.mg-yellow {
  color: #b45309;
  font-weight: 600;
}
.mg-red {
  color: #b91c1c;
  font-weight: 700;
}
.mg-na {
  color: var(--text-muted);
}
.legend {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
  margin-top: 10px;
}
.legend .lg {
  font-size: 12px;
  padding: 2px 10px;
  border-radius: 4px;
}
.legend .mg-green {
  background: rgba(22, 163, 74, 0.14);
}
.legend .mg-yellow {
  background: rgba(217, 119, 6, 0.16);
}
.legend .mg-red {
  background: rgba(220, 38, 38, 0.16);
}
.empty-hint {
  color: var(--text-muted);
  font-size: 13px;
  text-align: center;
}
</style>
