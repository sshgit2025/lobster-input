<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { Plus, Delete } from '@element-plus/icons-vue'
import { api } from '@/api'

interface AppleProduct {
  apple_product_id: string
  type: 'subscription' | 'credits_topup'
  name: string
  enabled: boolean
  sort_order: number
  plan_code?: string
  billing_cycle?: string
  topup_credits?: number
}

interface AppleIapConfig {
  enabled: boolean
  bundle_id: string
  app_apple_id: number | null
  allow_sandbox: boolean
  enable_online_checks: boolean
  api_issuer_id: string
  api_key_id: string
  api_private_key: string
  api_private_key_configured?: boolean
  products: AppleProduct[]
}

interface PlanConfig {
  name?: string
  paid?: boolean
  enabled?: boolean
  billing_options?: Record<string, { enabled?: boolean }>
}

const SECRET_PLACEHOLDER = '__configured__'
const BILLING_CYCLES = [
  { value: 'monthly', label: '月付 monthly' },
  { value: 'quarterly', label: '季付 quarterly' },
  { value: 'yearly', label: '年付 yearly' },
]

const loading = ref(false)
const saving = ref(false)
const config = ref<AppleIapConfig>({
  enabled: false,
  bundle_id: '',
  app_apple_id: null,
  allow_sandbox: true,
  enable_online_checks: false,
  api_issuer_id: '',
  api_key_id: '',
  api_private_key: '',
  products: [],
})
const planConfigs = ref<Record<string, PlanConfig>>({})

const paidPlanOptions = computed(() =>
  Object.entries(planConfigs.value)
    .filter(([, plan]) => plan?.paid && plan?.enabled !== false)
    .map(([code, plan]) => ({ value: code, label: `${plan?.name || code} (${code})` })),
)

async function loadAll() {
  loading.value = true
  try {
    const [cfg, plans] = await Promise.all([
      api<AppleIapConfig>('GET', '/api/v1/apple-iap-config'),
      api<{ plan_configs?: Record<string, PlanConfig> }>('GET', '/api/v1/plans/config'),
    ])
    config.value = { ...config.value, ...cfg, products: cfg.products || [] }
    planConfigs.value = plans.plan_configs || {}
  } catch (e) {
    ElMessage.error((e as Error).message)
  } finally {
    loading.value = false
  }
}

function addProduct(type: 'subscription' | 'credits_topup') {
  config.value.products.push({
    apple_product_id: '',
    type,
    name: '',
    enabled: true,
    sort_order: config.value.products.length * 10,
    ...(type === 'subscription'
      ? { plan_code: paidPlanOptions.value[0]?.value || '', billing_cycle: 'monthly' }
      : { topup_credits: 0 }),
  })
}

function removeProduct(index: number) {
  config.value.products.splice(index, 1)
}

function validate(): string {
  if (config.value.enabled && !config.value.bundle_id.trim()) return '启用后必须填写 Bundle ID'
  for (const row of config.value.products) {
    if (!row.apple_product_id.trim()) return '存在未填写 Apple 商品 ID 的行'
    if (row.type === 'subscription' && !row.plan_code) return `商品 ${row.apple_product_id} 未选择套餐`
    if (row.type === 'credits_topup' && (!row.topup_credits || row.topup_credits <= 0)) return `商品 ${row.apple_product_id} 的加购积分必须大于 0`
  }
  const ids = config.value.products.map((row) => row.apple_product_id.trim())
  if (new Set(ids).size !== ids.length) return 'Apple 商品 ID 不允许重复'
  return ''
}

async function save() {
  const error = validate()
  if (error) {
    ElMessage.warning(error)
    return
  }
  saving.value = true
  try {
    const payload = {
      ...config.value,
      app_apple_id: config.value.app_apple_id || null,
      api_private_key: config.value.api_private_key === SECRET_PLACEHOLDER ? SECRET_PLACEHOLDER : config.value.api_private_key,
    }
    const saved = await api<AppleIapConfig & { message?: string }>('POST', '/api/v1/apple-iap-config', payload)
    config.value = { ...config.value, ...saved, products: saved.products || [] }
    ElMessage.success(saved.message || '已保存')
  } catch (e) {
    ElMessage.error((e as Error).message)
  } finally {
    saving.value = false
  }
}

onMounted(loadAll)
</script>

<template>
  <div v-loading="loading" class="apple-iap-view">
    <el-alert type="info" :closable="false" class="tips">
      <p>iOS 端应用内购买(Apple IAP)独立配置,与「支付配置」中的 web 支付渠道互不影响。</p>
      <p>用户在苹果收银台可用绑定 Apple ID 的支付宝/微信(中国区)或国际信用卡(海外区)付款。</p>
      <p>服务器通知 V2 回调地址(需在 App Store Connect 配置):<code>https://example.com/lobster/payment/api/v1/payments/apple/notifications</code></p>
    </el-alert>

    <el-card shadow="never" class="section">
      <template #header><b>基础配置</b></template>
      <el-form label-width="180px">
        <el-form-item label="启用 iOS 内购">
          <el-switch v-model="config.enabled" />
        </el-form-item>
        <el-form-item label="Bundle ID">
          <el-input v-model="config.bundle_id" placeholder="ssh2026.lobster-input-ios" style="max-width: 360px" />
        </el-form-item>
        <el-form-item label="App Apple ID">
          <el-input-number v-model="config.app_apple_id" :min="0" :controls="false" placeholder="App Store Connect 的 App 数字 ID" style="width: 360px" />
          <div class="hint">生产环境验签必填(App Store Connect → App 信息 → Apple ID)</div>
        </el-form-item>
        <el-form-item label="允许沙盒交易">
          <el-switch v-model="config.allow_sandbox" />
          <div class="hint">苹果审核走沙盒环境,上架期间必须保持开启</div>
        </el-form-item>
        <el-form-item label="在线证书吊销检查">
          <el-switch v-model="config.enable_online_checks" />
          <div class="hint">开启后验签会请求苹果 OCSP 服务,境内服务器建议关闭</div>
        </el-form-item>
      </el-form>
    </el-card>

    <el-card shadow="never" class="section">
      <template #header><b>App Store Server API 凭证(可选,预留主动查询能力)</b></template>
      <el-form label-width="180px">
        <el-form-item label="Issuer ID">
          <el-input v-model="config.api_issuer_id" style="max-width: 360px" />
        </el-form-item>
        <el-form-item label="Key ID">
          <el-input v-model="config.api_key_id" style="max-width: 360px" />
        </el-form-item>
        <el-form-item label="私钥 (.p8 内容)">
          <el-input
            v-model="config.api_private_key"
            type="textarea"
            :rows="4"
            :placeholder="config.api_private_key_configured ? '已配置,留空或保持占位符则不修改' : '-----BEGIN PRIVATE KEY-----'"
            style="max-width: 560px"
          />
        </el-form-item>
      </el-form>
    </el-card>

    <el-card shadow="never" class="section">
      <template #header>
        <div class="products-header">
          <b>商品映射(Apple 商品 ID ↔ 套餐 / 积分加购)</b>
          <div>
            <el-button :icon="Plus" size="small" @click="addProduct('subscription')">加订阅商品</el-button>
            <el-button :icon="Plus" size="small" @click="addProduct('credits_topup')">加积分商品</el-button>
          </div>
        </div>
      </template>
      <el-table :data="config.products" size="small">
        <el-table-column label="Apple 商品 ID" min-width="230">
          <template #default="{ row }">
            <el-input v-model="row.apple_product_id" placeholder="如 lobster.plan.standard.monthly" />
          </template>
        </el-table-column>
        <el-table-column label="类型" width="130">
          <template #default="{ row }">
            <el-tag :type="row.type === 'subscription' ? 'primary' : 'success'">
              {{ row.type === 'subscription' ? '订阅套餐' : '积分加购' }}
            </el-tag>
          </template>
        </el-table-column>
        <el-table-column label="套餐 / 积分" min-width="230">
          <template #default="{ row }">
            <template v-if="row.type === 'subscription'">
              <el-select v-model="row.plan_code" placeholder="选择套餐" style="width: 130px">
                <el-option v-for="opt in paidPlanOptions" :key="opt.value" :label="opt.label" :value="opt.value" />
              </el-select>
              <el-select v-model="row.billing_cycle" style="width: 130px; margin-left: 6px">
                <el-option v-for="cycle in BILLING_CYCLES" :key="cycle.value" :label="cycle.label" :value="cycle.value" />
              </el-select>
            </template>
            <el-input-number v-else v-model="row.topup_credits" :min="0" :step="1000" style="width: 160px" />
          </template>
        </el-table-column>
        <el-table-column label="展示名" min-width="140">
          <template #default="{ row }">
            <el-input v-model="row.name" placeholder="留空则用商品 ID" />
          </template>
        </el-table-column>
        <el-table-column label="排序" width="100">
          <template #default="{ row }">
            <el-input-number v-model="row.sort_order" :min="0" :controls="false" style="width: 72px" />
          </template>
        </el-table-column>
        <el-table-column label="启用" width="70">
          <template #default="{ row }">
            <el-switch v-model="row.enabled" />
          </template>
        </el-table-column>
        <el-table-column width="60">
          <template #default="{ $index }">
            <el-button :icon="Delete" size="small" text type="danger" @click="removeProduct($index)" />
          </template>
        </el-table-column>
        <template #empty>尚未配置商品。请先在 App Store Connect 创建内购商品,再在此绑定套餐。</template>
      </el-table>
    </el-card>

    <div class="actions">
      <el-button type="primary" :loading="saving" @click="save">保存配置</el-button>
      <el-button :disabled="loading" @click="loadAll">重新加载</el-button>
    </div>
  </div>
</template>

<style scoped>
.apple-iap-view { display: flex; flex-direction: column; gap: 16px; }
.tips :deep(p) { margin: 2px 0; }
.tips code { word-break: break-all; }
.section :deep(.el-card__header) { padding: 12px 16px; }
.products-header { display: flex; justify-content: space-between; align-items: center; }
.hint { font-size: 12px; color: var(--el-text-color-secondary); margin-left: 10px; }
.actions { display: flex; gap: 12px; }
</style>
