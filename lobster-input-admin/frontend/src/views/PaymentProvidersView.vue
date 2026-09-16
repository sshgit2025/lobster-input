<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { api } from '@/api'
import { showToast } from '@/utils/toast'

const PROVIDERS = {
  creem: { code: 'creem', provider_code: 'creem', name: 'Creem', defaultMode: 'external_product', supports: ['card'], settlement: 'USD', dashboard: 'https://creem.io' },
  zpay: { code: 'zpay', provider_code: 'zpay', name: 'ZPay', defaultMode: 'amount_order', supports: ['wechat'], settlement: 'CNY', dashboard: 'https://zpayz.cn' },
} as const

const METHOD_PRESETS: Record<string, PaymentMethod> = {
  card: { code: 'card', name: '银行卡', description: 'Visa / Mastercard', channel_code: 'creem', currencies: ['USD'], sort_order: 10, enabled: true },
  wechat: { code: 'wechat', name: '微信支付', description: '中国大陆用户推荐', channel_code: 'zpay', currencies: ['CNY'], sort_order: 20, enabled: true },
}

const CURRENCY_PRESETS: Record<string, Currency> = {
  USD: { code: 'USD', name: '美元', symbol: '$', rate_to_usd: 1, rate_source: 'fixed', auto_update: false, enabled: true },
  CNY: { code: 'CNY', name: '人民币', symbol: '¥', rate_to_usd: 0.138, rate_source: 'manual', auto_update: false, enabled: true },
  HKD: { code: 'HKD', name: '港币', symbol: 'HK$', rate_to_usd: 0.128, rate_source: 'manual', auto_update: false, enabled: true },
  KRW: { code: 'KRW', name: '韩元', symbol: '₩', rate_to_usd: 0.00073, rate_source: 'manual', auto_update: false, enabled: true },
  RUB: { code: 'RUB', name: '卢布', symbol: '₽', rate_to_usd: 0.011, rate_source: 'manual', auto_update: false, enabled: true },
  EUR: { code: 'EUR', name: '欧元', symbol: '€', rate_to_usd: 1.08, rate_source: 'manual', auto_update: false, enabled: true },
}

const BILLING_LABELS: Record<string, string> = { weekly: '周付', monthly: '月付', quarterly: '季付', yearly: '年付', annual: '年付' }

interface PlanConfig {
  code: string
  name?: string
  paid?: boolean
  self_checkout_enabled?: boolean
  enabled?: boolean
  sort_order?: number
  billing_options?: Record<string, { enabled?: boolean }>
}

interface Product {
  code: string
  type: string
  name?: string
  description?: string
  plan_code?: string
  billing_cycle?: string
  topup_credits?: number
  enabled?: boolean
  sort_order?: number
}

interface Currency {
  code: string
  name?: string
  symbol?: string
  rate_to_usd?: number
  rate_source?: string
  auto_update?: boolean
  enabled?: boolean
  updated_at?: string
}

interface ChannelAccount {
  code: string
  name?: string
  enabled?: boolean
  environment?: string
  merchant_id?: string
  api_base_url?: string
  api_key?: string
  webhook_secret?: string
  dashboard_url?: string
  settlement_currency?: string
  api_key_configured?: boolean
  webhook_secret_configured?: boolean
}

interface Channel {
  code: string
  provider_code: string
  name?: string
  enabled?: boolean
  active_account_code?: string
  accounts?: ChannelAccount[]
}

interface PaymentMethod {
  code: string
  name?: string
  description?: string
  enabled?: boolean
  sort_order?: number
  channel_code?: string
  currencies?: string[]
}

interface ChannelPrice {
  product_code: string
  payment_method?: string
  channel_code?: string
  account_code?: string
  currency?: string
  amount_cents?: number
  mode?: string
  external_product_id?: string
  external_price_id?: string
  discount_mode?: string
  discount_code?: string
  pricing_strategy?: string
  base_currency?: string
  base_amount_cents?: number
  enabled?: boolean
}

interface ExchangeRateProvider {
  provider?: string
  api_key?: string
  base_currency?: string
  refresh_hour?: number
  enabled?: boolean
  last_refreshed_at?: string
}

interface PaymentConfig {
  products: Product[]
  currencies: Currency[]
  payment_methods: PaymentMethod[]
  channels: Channel[]
  channel_prices: ChannelPrice[]
  exchange_rate_provider?: ExchangeRateProvider
}

interface DiscountStatus {
  product_code?: string
  channel_code?: string
  account_code?: string
  configured?: boolean
  expired?: boolean
  valid?: boolean
  expires_at?: string
  reason?: string
}

const activeTab = ref('products')
const cfg = ref<PaymentConfig>({
  products: [],
  currencies: [],
  payment_methods: [],
  channels: [],
  channel_prices: [],
  exchange_rate_provider: {},
})
const plans = ref<Record<string, PlanConfig>>({})
const discountStatuses = ref<Record<string, DiscountStatus>>({})

const currencyAddSelect = ref('')
const channelAddSelect = ref('')
const methodAddSelect = ref('')
const priceFilterProduct = ref('')
const priceFilterChannel = ref('')

const fxProvider = ref('manual')
const fxApiKey = ref('')
const fxBase = ref('USD')
const fxHour = ref(3)

const summaryCards = computed(() => {
  const activeChannels = cfg.value.channels.filter((c) => c.enabled !== false && c.active_account_code).length
  const activePrices = cfg.value.channel_prices.filter((p) => p.enabled !== false).length
  const methods = cfg.value.payment_methods.filter((m) => m.enabled !== false).length
  const currencies = cfg.value.currencies.filter((c) => c.enabled !== false).length
  return [
    { title: '商品', value: cfg.value.products.length, desc: '订阅商品与加购包' },
    { title: '启用渠道', value: activeChannels, desc: '当前可用于下单的渠道账号' },
    { title: '支付方式', value: methods, desc: '客户端中转页可展示入口' },
    { title: '价格绑定', value: activePrices, desc: `${currencies} 个启用币种` },
  ]
})

const unusedCurrencies = computed(() =>
  Object.values(CURRENCY_PRESETS).filter((c) => !cfg.value.currencies.some((row) => row.code === c.code)),
)
const unusedChannels = computed(() =>
  Object.values(PROVIDERS).filter((p) => !cfg.value.channels.some((row) => row.code === p.code)),
)
const unusedMethods = computed(() =>
  Object.values(METHOD_PRESETS).filter((p) => !cfg.value.payment_methods.some((row) => row.code === p.code)),
)

const filteredPrices = computed(() => {
  let rows = cfg.value.channel_prices.map((p, i) => ({ p, i }))
  if (priceFilterProduct.value) rows = rows.filter((x) => x.p.product_code === priceFilterProduct.value)
  if (priceFilterChannel.value) rows = rows.filter((x) => x.p.channel_code === priceFilterChannel.value)
  return rows
})

function byCode<T extends { code: string }>(items: T[]): Record<string, T> {
  return Object.fromEntries(items.filter((x) => x?.code).map((x) => [x.code, x]))
}

function money(cents?: number, currency?: string): string {
  return `${currency || ''} ${((parseInt(String(cents)) || 0) / 100).toFixed(2)}`
}

function cycleLabel(cycle?: string): string {
  return BILLING_LABELS[cycle || ''] || cycle || ''
}

function subscriptionProductCode(planCode?: string, cycle?: string): string {
  return `${String(planCode || '').trim().toLowerCase()}_${String(cycle || '').trim().toLowerCase()}`
}

function planOptions() {
  return Object.values(plans.value)
    .filter((p) => p.paid && p.self_checkout_enabled !== false && p.enabled !== false)
    .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0))
}

function cycleOptions(planCode?: string) {
  const plan = plans.value[planCode || ''] || {}
  return Object.entries(plan.billing_options || {})
    .filter(([, v]) => v.enabled !== false)
    .map(([code]) => ({ value: code, label: cycleLabel(code) }))
}

function currencyRows() {
  return cfg.value.currencies.filter((c) => c.enabled !== false)
}

function enabledChannels() {
  return cfg.value.channels.filter((c) => c.enabled !== false)
}

function enabledMethods() {
  return cfg.value.payment_methods.filter((m) => m.enabled !== false)
}

function channelAccounts(channelCode?: string) {
  return byCode(cfg.value.channels)[channelCode || '']?.accounts || []
}

function methodsForChannel(channelCode?: string) {
  return cfg.value.payment_methods.filter((m) => m.channel_code === channelCode)
}

function discountKey(productCode?: string, channelCode?: string, accountCode?: string) {
  return `${productCode || ''}:${channelCode || ''}:${accountCode || ''}`
}

function discountStatus(productCode?: string, channelCode?: string, accountCode?: string) {
  return discountStatuses.value[discountKey(productCode, channelCode, accountCode)] || null
}

function formatDateTime(value?: string): string {
  if (!value) return '-'
  const d = new Date(value)
  return Number.isNaN(d.getTime()) ? String(value) : d.toLocaleString()
}

function defaultProductName(planCode?: string, cycle?: string): string {
  const p = plans.value[planCode || ''] || {}
  return `${p.name || planCode} ${cycleLabel(cycle)}`.trim()
}

function defaultApiBase(provider?: string): string {
  if (provider === 'zpay') return 'https://zpayz.cn'
  if (provider === 'creem') return 'https://api.creem.io'
  return ''
}

function defaultDashboard(provider?: string): string {
  if (provider === 'zpay') return 'https://zpayz.cn'
  if (provider === 'creem') return 'https://creem.io'
  return ''
}

function defaultSettlement(provider?: string): string {
  return provider === 'zpay' ? 'CNY' : 'USD'
}

function productName(code?: string): string {
  return byCode(cfg.value.products)[code || '']?.name || code || '-'
}

function normalizeConfig() {
  if (!cfg.value.currencies.some((c) => c.code === 'USD')) {
    cfg.value.currencies.unshift({ ...CURRENCY_PRESETS.USD })
  }
  cfg.value.products.forEach((p) => {
    if (p.type === 'subscription') {
      p.code = subscriptionProductCode(p.plan_code, p.billing_cycle)
    }
  })
  cfg.value.channels.forEach((ch) => {
    ch.accounts = Array.isArray(ch.accounts) ? ch.accounts : []
    if (ch.accounts.length && !ch.accounts.some((a) => a.code === ch.active_account_code)) {
      ch.active_account_code = ch.accounts.find((a) => a.enabled !== false)?.code || ch.accounts[0]?.code || ''
    }
  })
}

function syncExchangeFromCfg() {
  const fx = cfg.value.exchange_rate_provider || {}
  fxProvider.value = fx.provider || 'manual'
  fxBase.value = fx.base_currency || 'USD'
  fxHour.value = fx.refresh_hour ?? 3
  fxApiKey.value = ''
}

async function loadConfig() {
  const [billing, planResp, discountResp] = await Promise.all([
    api<PaymentConfig>('GET', '/api/v1/payment-provider-config'),
    api<{ plan_configs?: Record<string, PlanConfig> }>('GET', '/api/v1/plans/config'),
    api<{ items?: DiscountStatus[] }>('GET', '/api/v1/payment-provider-config/discounts/status').catch(() => ({ items: [] })),
  ])
  cfg.value = billing || cfg.value
  plans.value = planResp.plan_configs || {}
  discountStatuses.value = Object.fromEntries(
    (discountResp.items || []).map((row) => [discountKey(row.product_code, row.channel_code, row.account_code), row]),
  )
  ;['products', 'currencies', 'payment_methods', 'channels', 'channel_prices'].forEach((k) => {
    const key = k as keyof PaymentConfig
    if (!Array.isArray(cfg.value[key])) (cfg.value as Record<string, unknown>)[k] = []
  })
  cfg.value.exchange_rate_provider = cfg.value.exchange_rate_provider || {}
  normalizeConfig()
  syncExchangeFromCfg()
  if (unusedCurrencies.value.length) currencyAddSelect.value = unusedCurrencies.value[0]?.code || ''
  if (unusedChannels.value.length) channelAddSelect.value = unusedChannels.value[0]?.code || ''
  if (unusedMethods.value.length) methodAddSelect.value = unusedMethods.value[0]?.code || ''
}

function applyPriceChannelDefaults(p: ChannelPrice) {
  const channel = byCode(cfg.value.channels)[p.channel_code || ''] || {}
  const provider = PROVIDERS[channel.provider_code as keyof typeof PROVIDERS] || PROVIDERS[p.channel_code as keyof typeof PROVIDERS]
  const method = byCode(cfg.value.payment_methods)[p.payment_method || ''] || {}
  if (method.channel_code && method.channel_code !== p.channel_code) {
    p.channel_code = method.channel_code
  }
  const channelMethods = methodsForChannel(p.channel_code)
  if (!channelMethods.some((m) => m.code === p.payment_method)) {
    p.payment_method = channelMethods[0]?.code || p.payment_method || ''
  }
  const activeMethod = byCode(cfg.value.payment_methods)[p.payment_method || ''] || {}
  p.account_code = channelAccounts(p.channel_code).some((a) => a.code === p.account_code)
    ? p.account_code
    : (channelAccounts(p.channel_code)[0]?.code || '')
  p.currency = (activeMethod.currencies || []).includes(p.currency || '')
    ? p.currency
    : ((activeMethod.currencies || [])[0] || defaultSettlement(provider?.code) || p.currency || 'USD')
  p.mode = provider?.defaultMode || p.mode || 'amount_order'
  if ((byCode(cfg.value.channels)[p.channel_code || ''] || {}).provider_code !== 'creem') {
    p.discount_mode = 'none'
    p.discount_code = ''
  }
}

function onProductTypeChange(p: Product) {
  if (p.type === 'subscription') {
    const plan = planOptions()[0]?.code || ''
    const cycle = cycleOptions(plan)[0]?.value || 'monthly'
    p.plan_code = plan
    p.billing_cycle = cycle
    p.code = subscriptionProductCode(plan, cycle)
    p.name = defaultProductName(plan, cycle)
    delete p.topup_credits
  } else {
    p.code = p.code || 'credits_topup'
    p.name = p.name || '积分加购包'
    p.topup_credits = p.topup_credits || 10000
    delete p.plan_code
    delete p.billing_cycle
  }
}

function onProductPlanChange(p: Product) {
  p.billing_cycle = cycleOptions(p.plan_code)[0]?.value || 'monthly'
  p.code = subscriptionProductCode(p.plan_code, p.billing_cycle)
  p.name = defaultProductName(p.plan_code, p.billing_cycle)
}

function onProductCycleChange(p: Product) {
  p.code = subscriptionProductCode(p.plan_code, p.billing_cycle)
  p.name = p.name || defaultProductName(p.plan_code, p.billing_cycle)
}

function onChannelProviderChange(ch: Channel) {
  const p = PROVIDERS[ch.provider_code as keyof typeof PROVIDERS] || PROVIDERS.creem
  ch.code = p.code
  ch.name = p.name
  ;(ch.accounts || []).forEach((a) => {
    a.settlement_currency = a.settlement_currency || p.settlement
    a.api_base_url = a.api_base_url || defaultApiBase(ch.provider_code)
    a.dashboard_url = a.dashboard_url || defaultDashboard(ch.provider_code)
  })
}

function onMethodCodeChange(m: PaymentMethod) {
  const preset = METHOD_PRESETS[m.code]
  if (preset) Object.assign(m, { ...m, ...preset })
}

function onPriceMethodChange(p: ChannelPrice) {
  applyPriceChannelDefaults(p)
}

function onPriceChannelChange(p: ChannelPrice) {
  const channelMethods = methodsForChannel(p.channel_code)
  if (!channelMethods.some((m) => m.code === p.payment_method)) {
    p.payment_method = channelMethods[0]?.code || p.payment_method
  }
  applyPriceChannelDefaults(p)
}

function addSubscriptionProduct() {
  const plan = planOptions()[0]?.code || ''
  const cycle = cycleOptions(plan)[0]?.value || 'monthly'
  cfg.value.products.push({
    code: subscriptionProductCode(plan, cycle),
    type: 'subscription',
    name: defaultProductName(plan, cycle),
    plan_code: plan,
    billing_cycle: cycle,
    enabled: true,
    sort_order: cfg.value.products.length * 10 + 10,
  })
}

function addTopupProduct() {
  cfg.value.products.push({
    code: 'credits_topup',
    type: 'credits_topup',
    name: '积分加购包',
    topup_credits: 10000,
    enabled: true,
    sort_order: 900,
  })
}

function addCurrencyFromPreset() {
  const code = currencyAddSelect.value
  if (!code) return
  cfg.value.currencies.push({ ...CURRENCY_PRESETS[code] })
}

function addChannelFromPreset() {
  const code = channelAddSelect.value
  if (!code) return
  const p = PROVIDERS[code as keyof typeof PROVIDERS]
  cfg.value.channels.push({
    code: p.code,
    provider_code: p.provider_code,
    name: p.name,
    enabled: code === 'creem',
    active_account_code: '',
    accounts: [],
  })
}

function addMethodFromPreset() {
  const code = methodAddSelect.value
  if (!code) return
  cfg.value.payment_methods.push({ ...METHOD_PRESETS[code] })
}

function addAccount(ch: Channel) {
  const provider = PROVIDERS[ch.provider_code as keyof typeof PROVIDERS] || PROVIDERS.creem
  const env = (ch.accounts || []).some((a) => a.environment === 'test') ? 'live' : 'test'
  const code = `${ch.code}_${env}`
  ch.accounts = ch.accounts || []
  ch.accounts.push({
    code,
    name: `${ch.name || provider.name || ch.code} ${env === 'test' ? '测试' : '生产'}`,
    environment: env,
    merchant_id: '',
    api_base_url: defaultApiBase(ch.provider_code),
    api_key: '',
    webhook_secret: '',
    dashboard_url: defaultDashboard(ch.provider_code),
    settlement_currency: defaultSettlement(ch.provider_code),
    enabled: true,
  })
  if (!ch.active_account_code) ch.active_account_code = code
}

function addChannelPrice() {
  const product = cfg.value.products[0]?.code || ''
  const method = enabledMethods()[0] || {}
  const channel = method.channel_code || enabledChannels()[0]?.code || ''
  const account = channelAccounts(channel)[0]?.code || ''
  const provider = PROVIDERS[byCode(cfg.value.channels)[channel]?.provider_code as keyof typeof PROVIDERS] || PROVIDERS.creem
  const currency = (method.currencies || [])[0] || defaultSettlement(provider.code) || 'USD'
  cfg.value.channel_prices.push({
    product_code: product,
    payment_method: method.code || '',
    channel_code: channel,
    account_code: account,
    currency,
    amount_cents: 0,
    mode: provider.defaultMode || 'amount_order',
    external_product_id: '',
    discount_mode: 'none',
    discount_code: '',
    pricing_strategy: 'fixed',
    base_currency: 'USD',
    base_amount_cents: 0,
    enabled: true,
  })
}

function removeProduct(i: number) {
  const code = cfg.value.products[i]?.code
  cfg.value.products.splice(i, 1)
  cfg.value.channel_prices = cfg.value.channel_prices.filter((p) => cfg.value.products.some((x) => x.code === p.product_code))
  if (priceFilterProduct.value === code) priceFilterProduct.value = ''
}

function removeCurrency(i: number) {
  const code = cfg.value.currencies[i]?.code
  if (code === 'USD') return
  cfg.value.currencies.splice(i, 1)
  cfg.value.channel_prices = cfg.value.channel_prices.filter((p) => p.currency !== code)
}

function removeChannel(i: number) {
  const code = cfg.value.channels[i]?.code
  cfg.value.channels.splice(i, 1)
  cfg.value.payment_methods.forEach((m) => { if (m.channel_code === code) m.channel_code = '' })
  cfg.value.channel_prices = cfg.value.channel_prices.filter((p) => p.channel_code !== code)
  if (priceFilterChannel.value === code) priceFilterChannel.value = ''
}

function removeMethod(i: number) {
  const code = cfg.value.payment_methods[i]?.code
  cfg.value.payment_methods.splice(i, 1)
  cfg.value.channel_prices = cfg.value.channel_prices.filter((p) => p.payment_method !== code)
}

function removePrice(i: number) {
  cfg.value.channel_prices.splice(i, 1)
}

function removeAccount(ch: Channel, j: number) {
  const code = ch.accounts?.[j]?.code
  ch.accounts?.splice(j, 1)
  if (ch.active_account_code === code) ch.active_account_code = ch.accounts?.[0]?.code || ''
  cfg.value.channel_prices = cfg.value.channel_prices.filter((p) => p.account_code !== code)
}

function syncExchangeToCfg() {
  cfg.value.exchange_rate_provider = {
    ...(cfg.value.exchange_rate_provider || {}),
    provider: fxProvider.value || 'manual',
    api_key: fxApiKey.value || undefined,
    base_currency: fxBase.value || 'USD',
    refresh_hour: Math.min(23, Math.max(0, parseInt(String(fxHour.value)) || 0)),
    enabled: fxProvider.value !== 'manual',
  }
}

function validateConfig() {
  const errors: string[] = []
  const productCodes = new Set<string>()
  const currencyCodes = new Set(cfg.value.currencies.map((c) => c.code))
  const channelCodes = new Set(cfg.value.channels.map((c) => c.code))
  const methodCodes = new Set(cfg.value.payment_methods.map((m) => m.code))

  cfg.value.products.forEach((p) => {
    if (!p.code) errors.push('商品代码不能为空')
    if (productCodes.has(p.code)) errors.push(`商品代码重复：${p.code}`)
    productCodes.add(p.code)
    if (p.type === 'subscription' && (!p.plan_code || !p.billing_cycle)) errors.push(`订阅商品 ${p.code} 必须选择套餐和账期`)
    if (p.type === 'credits_topup' && (p.topup_credits || 0) <= 0) errors.push(`加购商品 ${p.code} 必须配置大于 0 的积分`)
  })
  cfg.value.currencies.forEach((c) => {
    if (c.enabled !== false && (c.rate_to_usd || 0) <= 0) errors.push(`${c.code} 汇率必须大于 0`)
  })
  cfg.value.channels.forEach((ch) => {
    if (!ch.provider_code) errors.push(`${ch.code} 必须选择平台`)
    if (ch.enabled !== false && ch.accounts?.length && !ch.active_account_code) errors.push(`${ch.name || ch.code} 必须选择当前激活账号`)
  })
  cfg.value.payment_methods.forEach((m) => {
    if (!channelCodes.has(m.channel_code || '')) errors.push(`支付方式 ${m.code} 未绑定有效渠道`)
    if (m.enabled !== false && !(m.currencies || []).length) errors.push(`支付方式 ${m.code} 至少选择一个币种`)
  })
  const priceKeys = new Set<string>()
  cfg.value.channel_prices.forEach((p) => {
    const method = byCode(cfg.value.payment_methods)[p.payment_method || ''] || {}
    const channel = byCode(cfg.value.channels)[p.channel_code || ''] || {}
    const key = [p.product_code, p.payment_method, p.channel_code, p.account_code, p.currency].join('|')
    if (priceKeys.has(key)) errors.push(`${p.product_code} 存在重复的同渠道同币种价格绑定`)
    priceKeys.add(key)
    if (!productCodes.has(p.product_code || '')) errors.push('价格绑定引用了不存在的商品')
    if (!methodCodes.has(p.payment_method || '')) errors.push(`${p.product_code} 引用了不存在的支付方式`)
    if (!channelCodes.has(p.channel_code || '')) errors.push(`${p.product_code} 引用了不存在的渠道`)
    if (method.channel_code && method.channel_code !== p.channel_code) errors.push(`${p.product_code} 的支付方式和渠道不匹配`)
    if (!currencyCodes.has(p.currency || '')) errors.push(`${p.product_code} 引用了不存在的币种`)
    if (method.enabled !== false && !(method.currencies || []).includes(p.currency || '')) errors.push(`${p.product_code} 的支付方式不支持 ${p.currency}`)
    if (p.enabled !== false && channel.provider_code === 'creem' && p.mode === 'external_product' && !p.external_product_id) errors.push(`${p.product_code} 的 Creem 平台商品模式必须填写外部商品 ID`)
    if (p.enabled !== false && channel.provider_code === 'creem' && p.discount_mode === 'auto_apply' && !p.discount_code) errors.push(`${p.product_code} 自动填充优惠券时必须填写券码`)
    if (p.enabled !== false && p.pricing_strategy === 'exchange_rate' && (!p.base_currency || (p.base_amount_cents || 0) <= 0)) errors.push(`${p.product_code} 跟随汇率必须填写基准币种和基准金额`)
  })
  if (errors.length) throw new Error(errors.slice(0, 6).join('\n'))
}

async function saveConfig() {
  try {
    normalizeConfig()
    syncExchangeToCfg()
    validateConfig()
    cfg.value = await api<PaymentConfig>('POST', '/api/v1/payment-provider-config', cfg.value)
    showToast('支付配置已保存')
    normalizeConfig()
    syncExchangeFromCfg()
  } catch (e) {
    showToast(e instanceof Error ? e.message : '保存失败', 'error')
  }
}

onMounted(() => {
  loadConfig().catch((e) => showToast(e instanceof Error ? e.message : '加载失败', 'error'))
})
</script>

<template>
  <div class="page-header">
    <div>
      <div class="page-title">支付配置</div>
      <div class="page-subtitle">按"商品、币种、渠道账号、支付方式、价格绑定"维护支付域配置，订阅权益仍由套餐配置管理。</div>
    </div>
    <div class="ph-actions">
      <el-button type="primary" @click="saveConfig">保存配置</el-button>
    </div>
  </div>

  <div class="ops-grid">
    <div v-for="card in summaryCards" :key="card.title" class="ops-card">
      <div class="ops-label">{{ card.title }}</div>
      <div class="ops-value">{{ card.value }}</div>
      <div class="ops-desc">{{ card.desc }}</div>
    </div>
  </div>

  <div class="payment-shell">
    <aside class="payment-nav">
      <button
        v-for="tab in [
          { id: 'products', num: '1', title: '商品目录', desc: '套餐账期与加购包' },
          { id: 'currencies', num: '2', title: '币种汇率', desc: '币种清单与刷新源' },
          { id: 'channels', num: '3', title: '渠道账号', desc: 'Creem / ZPay 多账号' },
          { id: 'methods', num: '4', title: '支付方式', desc: '客户端展示入口' },
          { id: 'prices', num: '5', title: '价格绑定', desc: '商品到渠道价格' },
        ]"
        :key="tab.id"
        class="flow-tab"
        :class="{ active: activeTab === tab.id }"
        @click="activeTab = tab.id"
      >
        <span>{{ tab.num }}</span>
        <b>{{ tab.title }}</b>
        <small>{{ tab.desc }}</small>
      </button>
    </aside>

    <section class="payment-workspace">
      <!-- 商品目录 -->
      <div v-show="activeTab === 'products'" class="tab-panel">
        <div class="panel-head">
          <div>
            <h2>商品目录</h2>
            <p>订阅商品只能选择已启用自助购买的套餐和账期，代码自动生成；只有加购商品允许填写加购积分。</p>
          </div>
          <div class="action-row">
            <el-button size="small" @click="addSubscriptionProduct">新增订阅商品</el-button>
            <el-button size="small" @click="addTopupProduct">新增加购商品</el-button>
          </div>
        </div>
        <div v-if="cfg.products.length === 0" class="empty-state">还没有商品。请先从套餐生成订阅商品，或创建积分加购包。</div>
        <div v-for="(p, i) in cfg.products" :key="i" class="object-row">
          <div class="row-main">
            <div class="row-title">{{ p.name || p.code || '未命名商品' }} <code>{{ p.code || '-' }}</code></div>
            <div class="row-meta">{{ p.type === 'subscription' ? '订阅商品：权益、积分、周期来自套餐配置' : '加购商品：仅这里配置加购积分包' }}</div>
          </div>
          <div class="row-fields product-grid">
            <label class="form-group">
              <span class="form-label">类型</span>
              <select v-model="p.type" class="form-select" @change="onProductTypeChange(p)">
                <option value="subscription">订阅商品</option>
                <option value="credits_topup">加购积分包</option>
              </select>
            </label>
            <label class="form-group"><span class="form-label">商品名</span><input v-model="p.name" class="form-input"></label>
            <template v-if="p.type === 'subscription'">
              <label class="form-group">
                <span class="form-label">套餐</span>
                <select v-model="p.plan_code" class="form-select" @change="onProductPlanChange(p)">
                  <option v-for="pl in planOptions()" :key="pl.code" :value="pl.code">{{ pl.name || pl.code }} ({{ pl.code }})</option>
                </select>
              </label>
              <label class="form-group">
                <span class="form-label">账期</span>
                <select v-model="p.billing_cycle" class="form-select" @change="onProductCycleChange(p)">
                  <option v-for="c in cycleOptions(p.plan_code)" :key="c.value" :value="c.value">{{ c.label }}</option>
                </select>
              </label>
            </template>
            <template v-else>
              <label class="form-group"><span class="form-label">商品代码</span><input v-model="p.code" class="form-input"></label>
              <label class="form-group"><span class="form-label">加购积分</span><input v-model.number="p.topup_credits" class="form-input" type="number" min="0"></label>
            </template>
            <label class="form-group inline-control"><input v-model="p.enabled" type="checkbox"> 启用</label>
          </div>
          <el-button type="danger" size="small" @click="removeProduct(i)">删除</el-button>
        </div>
      </div>

      <!-- 币种汇率 -->
      <div v-show="activeTab === 'currencies'" class="tab-panel">
        <div class="panel-head">
          <div>
            <h2>币种汇率</h2>
            <p>币种只能从预置清单追加。客户端套餐展示仍统一使用 USD，渠道价格可以按币种独立配置。</p>
          </div>
          <div class="action-row">
            <select v-model="currencyAddSelect" class="form-select compact">
              <option v-for="c in unusedCurrencies" :key="c.code" :value="c.code">{{ c.code }} {{ c.name }}</option>
            </select>
            <el-button size="small" @click="addCurrencyFromPreset">新增币种</el-button>
          </div>
        </div>
        <div class="section-band">
          <div class="section-title">汇率刷新源</div>
          <div class="form-grid">
            <label class="form-group">
              <span class="form-label">供应商</span>
              <select v-model="fxProvider" class="form-select">
                <option value="manual">手动维护</option>
                <option value="tianapi">天聚数行</option>
                <option value="jisuapi">极速数据</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">API Key</span>
              <input v-model="fxApiKey" class="form-input" type="password" placeholder="已配置则留空不修改">
            </label>
            <label class="form-group">
              <span class="form-label">基准币种</span>
              <select v-model="fxBase" class="form-select">
                <option v-for="c in currencyRows()" :key="c.code" :value="c.code">{{ c.code }} {{ c.name }}</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">每日刷新小时</span>
              <input v-model.number="fxHour" class="form-input" type="number" min="0" max="23">
            </label>
          </div>
        </div>
        <div v-for="(c, i) in cfg.currencies" :key="c.code" class="object-row">
          <div class="row-main">
            <div class="row-title">{{ c.code }} {{ c.name }} <span class="pill">{{ c.symbol }}</span></div>
            <div class="row-meta">1 {{ c.code }} = {{ c.rate_to_usd }} USD，来源：{{ c.rate_source || 'manual' }}</div>
          </div>
          <div class="row-fields currency-grid">
            <label class="form-group"><span class="form-label">币种</span><input class="form-input" :value="c.code" disabled></label>
            <label class="form-group"><span class="form-label">名称</span><input v-model="c.name" class="form-input"></label>
            <label class="form-group"><span class="form-label">符号</span><input v-model="c.symbol" class="form-input"></label>
            <label class="form-group"><span class="form-label">兑 USD 汇率</span><input v-model.number="c.rate_to_usd" class="form-input" type="number" min="0"></label>
            <label class="form-group">
              <span class="form-label">来源</span>
              <select v-model="c.rate_source" class="form-select">
                <option value="fixed">固定</option><option value="manual">手动</option>
                <option value="tianapi">天聚数行</option><option value="jisuapi">极速数据</option>
              </select>
            </label>
            <label class="form-group inline-control"><input v-model="c.auto_update" type="checkbox"> 自动更新</label>
            <label class="form-group inline-control"><input v-model="c.enabled" type="checkbox"> 启用</label>
          </div>
          <el-button type="danger" size="small" :disabled="c.code === 'USD'" @click="removeCurrency(i)">删除</el-button>
        </div>
      </div>

      <!-- 渠道账号 -->
      <div v-show="activeTab === 'channels'" class="tab-panel">
        <div class="panel-head">
          <div>
            <h2>渠道账号</h2>
            <p>每个渠道可以维护测试和生产等多套账号，并选择当前激活账号。密钥只在支付服务配置表保存。</p>
          </div>
          <div class="action-row">
            <select v-model="channelAddSelect" class="form-select compact">
              <option v-for="p in unusedChannels" :key="p.code" :value="p.code">{{ p.name }}</option>
            </select>
            <el-button size="small" @click="addChannelFromPreset">新增渠道</el-button>
          </div>
        </div>
        <div v-if="cfg.channels.length === 0" class="empty-state">还没有支付渠道。请选择 Creem 或 ZPay 创建渠道。</div>
        <div v-for="(ch, i) in cfg.channels" :key="ch.code" class="channel-block">
          <div class="object-row channel-summary">
            <div class="row-main">
              <div class="row-title">{{ ch.name || (PROVIDERS[ch.provider_code as keyof typeof PROVIDERS] || {}).name || ch.code }} <code>{{ ch.code }}</code></div>
              <div class="row-meta">平台：{{ ch.provider_code }}，激活账号：{{ ch.active_account_code || '未选择' }}</div>
            </div>
            <div class="row-fields channel-grid">
              <label class="form-group">
                <span class="form-label">平台</span>
                <select v-model="ch.provider_code" class="form-select" @change="onChannelProviderChange(ch)">
                  <option v-for="p in Object.values(PROVIDERS)" :key="p.provider_code" :value="p.provider_code">{{ p.name }}</option>
                </select>
              </label>
              <label class="form-group"><span class="form-label">名称</span><input v-model="ch.name" class="form-input"></label>
              <label class="form-group">
                <span class="form-label">当前激活账号</span>
                <select v-model="ch.active_account_code" class="form-select">
                  <option v-for="a in ch.accounts" :key="a.code" :value="a.code">{{ a.name || a.code }} ({{ a.environment || 'live' }}{{ a.enabled === false ? '，停用' : '' }})</option>
                </select>
              </label>
              <label class="form-group inline-control"><input v-model="ch.enabled" type="checkbox"> 启用渠道</label>
            </div>
            <el-button type="danger" size="small" @click="removeChannel(i)">删除</el-button>
          </div>
          <div class="account-list">
            <div class="sub-head"><b>账号配置</b><el-button size="small" @click="addAccount(ch)">新增账号</el-button></div>
            <div v-if="!(ch.accounts || []).length" class="empty-state slim">还没有账号。至少配置一个测试或生产账号。</div>
            <div v-for="(a, j) in ch.accounts" :key="a.code" class="account-row">
              <div class="row-fields account-grid">
                <label class="form-group"><span class="form-label">账号代码</span><input v-model="a.code" class="form-input"></label>
                <label class="form-group"><span class="form-label">账号名称</span><input v-model="a.name" class="form-input"></label>
                <label class="form-group">
                  <span class="form-label">环境</span>
                  <select v-model="a.environment" class="form-select"><option value="test">测试</option><option value="live">生产</option></select>
                </label>
                <label class="form-group"><span class="form-label">商户/PID</span><input v-model="a.merchant_id" class="form-input"></label>
                <label class="form-group"><span class="form-label">API Base</span><input v-model="a.api_base_url" class="form-input"></label>
                <label class="form-group">
                  <span class="form-label">结算币种</span>
                  <select v-model="a.settlement_currency" class="form-select">
                    <option v-for="c in currencyRows()" :key="c.code" :value="c.code">{{ c.code }} {{ c.name }}</option>
                  </select>
                </label>
                <label class="form-group"><span class="form-label">Dashboard</span><input v-model="a.dashboard_url" class="form-input"></label>
                <label class="form-group">
                  <span class="form-label">API Key</span>
                  <input v-model="a.api_key" class="form-input" type="password" :placeholder="a.api_key_configured ? '已配置，留空不修改' : '未配置'">
                </label>
                <label class="form-group">
                  <span class="form-label">Webhook Secret</span>
                  <input v-model="a.webhook_secret" class="form-input" type="password" :placeholder="a.webhook_secret_configured ? '已配置，留空不修改' : '未配置'">
                </label>
                <label class="form-group inline-control"><input v-model="a.enabled" type="checkbox"> 启用账号</label>
              </div>
              <el-button type="danger" size="small" @click="removeAccount(ch, j)">删除账号</el-button>
            </div>
          </div>
        </div>
      </div>

      <!-- 支付方式 -->
      <div v-show="activeTab === 'methods'" class="tab-panel">
        <div class="panel-head">
          <div>
            <h2>支付方式</h2>
            <p>支付方式是给用户看的入口，必须绑定一个支付渠道，并限制可用币种。</p>
          </div>
          <div class="action-row">
            <select v-model="methodAddSelect" class="form-select compact">
              <option v-for="p in unusedMethods" :key="p.code" :value="p.code">{{ p.name }}</option>
            </select>
            <el-button size="small" @click="addMethodFromPreset">新增方式</el-button>
          </div>
        </div>
        <div v-if="cfg.payment_methods.length === 0" class="empty-state">还没有支付方式。请从银行卡或微信支付开始配置。</div>
        <div v-for="(m, i) in cfg.payment_methods" :key="m.code" class="object-row">
          <div class="row-main">
            <div class="row-title">{{ m.name || m.code }} <code>{{ m.code }}</code></div>
            <div class="row-meta">{{ m.description }}，渠道：{{ m.channel_code || '-' }}</div>
          </div>
          <div class="row-fields method-grid">
            <label class="form-group">
              <span class="form-label">支付方式</span>
              <select v-model="m.code" class="form-select" @change="onMethodCodeChange(m)">
                <option v-for="x in Object.values(METHOD_PRESETS)" :key="x.code" :value="x.code">{{ x.name }}</option>
              </select>
            </label>
            <label class="form-group"><span class="form-label">名称</span><input v-model="m.name" class="form-input"></label>
            <label class="form-group"><span class="form-label">说明</span><input v-model="m.description" class="form-input"></label>
            <label class="form-group">
              <span class="form-label">渠道</span>
              <select v-model="m.channel_code" class="form-select">
                <option v-for="c in cfg.channels" :key="c.code" :value="c.code">{{ c.name || c.code }} ({{ c.code }}{{ c.enabled === false ? '，停用' : '' }})</option>
              </select>
            </label>
            <label class="form-group"><span class="form-label">排序</span><input v-model.number="m.sort_order" class="form-input" type="number"></label>
            <label class="form-group inline-control"><input v-model="m.enabled" type="checkbox"> 启用</label>
          </div>
          <div class="currency-checks">
            <label v-for="c in currencyRows()" :key="c.code">
              <input
                type="checkbox"
                :checked="(m.currencies || []).includes(c.code)"
                @change="(e) => {
                  const checked = (e.target as HTMLInputElement).checked
                  if (!m.currencies) m.currencies = []
                  if (checked && !m.currencies.includes(c.code)) m.currencies.push(c.code)
                  else if (!checked) m.currencies = m.currencies.filter(x => x !== c.code)
                }"
              > {{ c.code }}
            </label>
          </div>
          <el-button type="danger" size="small" @click="removeMethod(i)">删除</el-button>
        </div>
      </div>

      <!-- 价格绑定 -->
      <div v-show="activeTab === 'prices'" class="tab-panel">
        <div class="panel-head">
          <div>
            <h2>价格绑定</h2>
            <p>把本地商品绑定到具体支付方式、渠道账号和币种。Creem 使用平台商品，ZPay 使用金额下单。</p>
          </div>
          <el-button size="small" @click="addChannelPrice">新增价格绑定</el-button>
        </div>
        <div class="filter-row">
          <label class="form-group">
            <span class="form-label">商品筛选</span>
            <select v-model="priceFilterProduct" class="form-select">
              <option value="">全部商品</option>
              <option v-for="p in cfg.products" :key="p.code" :value="p.code">{{ p.name || p.code }} ({{ p.code }})</option>
            </select>
          </label>
          <label class="form-group">
            <span class="form-label">渠道筛选</span>
            <select v-model="priceFilterChannel" class="form-select">
              <option value="">全部渠道</option>
              <option v-for="c in cfg.channels" :key="c.code" :value="c.code">{{ c.name || c.code }} ({{ c.code }})</option>
            </select>
          </label>
        </div>
        <div v-if="filteredPrices.length === 0" class="empty-state">没有符合筛选条件的价格绑定。</div>
        <div v-for="{ p, i } in filteredPrices" :key="i" class="object-row price-row">
          <div class="row-main">
            <div class="row-title">
              {{ productName(p.product_code) }}
              <span class="pill">{{ p.payment_method || '-' }}</span>
            </div>
            <div class="row-meta">
              {{ money(p.amount_cents, p.currency) }}，
              {{ (PROVIDERS[(byCode(cfg.channels)[p.channel_code || ''] || {}).provider_code as keyof typeof PROVIDERS] || {}).name || p.channel_code }}
              / {{ p.account_code || '-' }}
            </div>
          </div>
          <div class="row-fields price-grid">
            <label class="form-group">
              <span class="form-label">商品</span>
              <select v-model="p.product_code" class="form-select">
                <option v-for="pr in cfg.products" :key="pr.code" :value="pr.code">{{ pr.name || pr.code }} ({{ pr.code }})</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">支付方式</span>
              <select v-model="p.payment_method" class="form-select" @change="onPriceMethodChange(p)">
                <option v-for="m in cfg.payment_methods" :key="m.code" :value="m.code">{{ m.name || m.code }} ({{ m.code }})</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">渠道</span>
              <select v-model="p.channel_code" class="form-select" @change="onPriceChannelChange(p)">
                <option v-for="c in cfg.channels" :key="c.code" :value="c.code">{{ c.name || c.code }} ({{ c.code }})</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">账号</span>
              <select v-model="p.account_code" class="form-select">
                <option v-for="a in channelAccounts(p.channel_code)" :key="a.code" :value="a.code">{{ a.name || a.code }} ({{ a.environment || 'live' }})</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">币种</span>
              <select v-model="p.currency" class="form-select">
                <option v-for="c in currencyRows()" :key="c.code" :value="c.code">{{ c.code }} {{ c.name }}</option>
              </select>
            </label>
            <label class="form-group"><span class="form-label">金额（分）</span><input v-model.number="p.amount_cents" class="form-input" type="number" min="0"></label>
            <label class="form-group">
              <span class="form-label">模式</span>
              <select v-model="p.mode" class="form-select">
                <option value="external_product">平台商品</option>
                <option value="amount_order">金额下单</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">外部商品 ID</span>
              <input v-model="p.external_product_id" class="form-input" :disabled="p.mode === 'amount_order'">
            </label>
            <template v-if="(byCode(cfg.channels)[p.channel_code || ''] || {}).provider_code === 'creem'">
              <label class="form-group">
                <span class="form-label">优惠券策略</span>
                <select v-model="p.discount_mode" class="form-select">
                  <option value="none">不自动填充</option>
                  <option value="auto_apply">自动填充此商品优惠券</option>
                </select>
              </label>
              <label class="form-group"><span class="form-label">优惠券码</span><input v-model="p.discount_code" class="form-input"></label>
              <label class="form-group">
                <span class="form-label">优惠券状态</span>
                <div class="status-line">
                  <template v-if="!discountStatus(p.product_code, p.channel_code, p.account_code)">
                    <span class="pill muted">未查询</span>
                  </template>
                  <template v-else-if="!discountStatus(p.product_code, p.channel_code, p.account_code)!.configured">
                    <span class="pill muted">未配置券码</span>
                  </template>
                  <template v-else>
                    <span
                      :class="['pill', discountStatus(p.product_code, p.channel_code, p.account_code)!.expired || !discountStatus(p.product_code, p.channel_code, p.account_code)!.valid ? 'danger' : 'success']"
                    >{{ discountStatus(p.product_code, p.channel_code, p.account_code)!.expired ? '已过期' : discountStatus(p.product_code, p.channel_code, p.account_code)!.valid ? '有效' : '异常' }}</span>
                    <small>{{ discountStatus(p.product_code, p.channel_code, p.account_code)!.reason }}{{ discountStatus(p.product_code, p.channel_code, p.account_code)!.expires_at ? `，到期：${formatDateTime(discountStatus(p.product_code, p.channel_code, p.account_code)!.expires_at)}` : '' }}</small>
                  </template>
                </div>
              </label>
            </template>
            <label class="form-group">
              <span class="form-label">价格策略</span>
              <select v-model="p.pricing_strategy" class="form-select">
                <option value="fixed">固定价格</option>
                <option value="exchange_rate">跟随汇率</option>
              </select>
            </label>
            <label class="form-group">
              <span class="form-label">基准币种</span>
              <select v-model="p.base_currency" class="form-select">
                <option v-for="c in currencyRows()" :key="c.code" :value="c.code">{{ c.code }} {{ c.name }}</option>
              </select>
            </label>
            <label class="form-group"><span class="form-label">基准金额（分）</span><input v-model.number="p.base_amount_cents" class="form-input" type="number" min="0"></label>
            <label class="form-group inline-control"><input v-model="p.enabled" type="checkbox"> 启用</label>
          </div>
          <el-button type="danger" size="small" @click="removePrice(i)">删除</el-button>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.page-subtitle { color: var(--text-muted); font-size: 13px; }
.ops-grid { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-bottom: 16px; }
.ops-card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; padding: 14px; }
.ops-label { color: var(--text-muted); font-size: 12px; }
.ops-value { font-size: 26px; font-weight: 800; margin: 4px 0; }
.ops-desc { color: var(--text-muted); font-size: 12px; }
.payment-shell { align-items: flex-start; display: grid; gap: 16px; grid-template-columns: 240px minmax(0, 1fr); }
.payment-nav { background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; display: flex; flex-direction: column; gap: 4px; padding: 8px; position: sticky; top: 20px; }
.flow-tab { align-items: center; background: transparent; border: 0; border-radius: 6px; color: var(--text-muted); cursor: pointer; display: grid; gap: 2px 10px; grid-template-columns: 28px 1fr; padding: 10px; text-align: left; }
.flow-tab span { align-items: center; background: var(--bg-hover); border-radius: 50%; display: flex; font-size: 12px; font-weight: 700; height: 24px; justify-content: center; width: 24px; }
.flow-tab b { color: var(--text); font-size: 13px; }
.flow-tab small { font-size: 11px; grid-column: 2; }
.flow-tab.active, .flow-tab:hover { background: var(--bg-hover); }
.flow-tab.active span { background: var(--primary); color: #fff; }
.payment-workspace { min-width: 0; }
.tab-panel { background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; padding: 18px; }
.panel-head { align-items: flex-start; border-bottom: 1px solid var(--border); display: flex; gap: 16px; justify-content: space-between; margin-bottom: 16px; padding-bottom: 14px; }
.panel-head h2 { font-size: 18px; margin: 0 0 4px; }
.panel-head p { color: var(--text-muted); font-size: 12px; line-height: 1.6; margin: 0; max-width: 760px; }
.compact { min-width: 160px; }
.object-row { align-items: flex-start; background: rgba(255,255,255,.02); border: 1px solid var(--border); border-radius: 8px; display: grid; gap: 12px; grid-template-columns: minmax(180px, 260px) minmax(0, 1fr) auto; padding: 14px; margin-bottom: 12px; }
.row-title { font-weight: 700; }
.row-title code { color: var(--text-muted); font-size: 12px; font-weight: 500; margin-left: 6px; }
.row-meta { color: var(--text-muted); font-size: 12px; line-height: 1.6; margin-top: 4px; }
.row-fields { display: grid; gap: 10px; }
.product-grid { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }
.currency-grid { grid-template-columns: repeat(auto-fit, minmax(128px, 1fr)); }
.channel-grid { grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); }
.method-grid { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }
.account-grid { grid-template-columns: repeat(auto-fit, minmax(155px, 1fr)); }
.price-grid { grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); }
.inline-control { align-items: center; display: flex; gap: 8px; min-height: 36px; }
.pill { background: var(--bg-hover); border: 1px solid var(--border); border-radius: 999px; color: var(--text-muted); font-size: 11px; padding: 2px 8px; }
.pill.success { background: rgba(34,197,94,.15); border-color: rgba(34,197,94,.35); color: var(--success); }
.pill.danger { background: rgba(239,68,68,.15); border-color: rgba(239,68,68,.35); color: var(--danger); }
.pill.muted { color: var(--text-muted); }
.status-line { align-items: center; display: flex; flex-wrap: wrap; gap: 6px; min-height: 36px; }
.status-line small { color: var(--text-muted); font-size: 11px; }
.section-band { background: rgba(255,255,255,.02); border: 1px solid var(--border); border-radius: 8px; margin-bottom: 12px; padding: 14px; }
.section-title, .sub-head { font-weight: 700; margin-bottom: 10px; }
.form-grid, .filter-row { display: grid; gap: 12px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); }
.channel-block { border: 1px solid var(--border); border-radius: 8px; overflow: hidden; margin-bottom: 12px; }
.channel-summary { border: 0; border-bottom: 1px solid var(--border); border-radius: 0; }
.account-list { display: flex; flex-direction: column; gap: 10px; padding: 14px; }
.sub-head { align-items: center; display: flex; justify-content: space-between; }
.account-row { background: rgba(255,255,255,.02); border: 1px solid var(--border); border-radius: 8px; display: grid; gap: 12px; grid-template-columns: minmax(0, 1fr) auto; padding: 12px; }
.currency-checks { align-content: center; display: flex; flex-wrap: wrap; gap: 8px; grid-column: 1 / -1; }
.currency-checks label { background: var(--bg-hover); border: 1px solid var(--border); border-radius: 999px; color: var(--text-muted); font-size: 12px; padding: 6px 10px; }
.empty-state { border: 1px dashed var(--border); border-radius: 8px; color: var(--text-muted); font-size: 13px; padding: 22px; text-align: center; margin-bottom: 12px; }
.empty-state.slim { padding: 14px; }
.filter-row { margin-bottom: 12px; }
@media (max-width: 1000px) {
  .payment-shell { grid-template-columns: 1fr; }
  .payment-nav { position: static; }
  .object-row, .account-row { grid-template-columns: 1fr; }
  .panel-head { display: block; }
}
</style>
