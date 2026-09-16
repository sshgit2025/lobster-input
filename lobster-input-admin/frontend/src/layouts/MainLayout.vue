<script setup lang="ts">
import { computed, markRaw, onMounted, onUnmounted, ref, watch, type Component } from 'vue'
import { useRoute } from 'vue-router'
import {
  Odometer, TrendCharts, User, Ticket, Present, ChatDotRound,
  Medal, Tickets, Wallet, OfficeBuilding, Box, Refresh, RefreshLeft,
  Document, Bell, Lock, Setting, Connection, Notebook, Avatar,
  SwitchButton, Key, ArrowRight, Iphone, PriceTag, Message, Histogram,
} from '@element-plus/icons-vue'
import { api, logout } from '@/api'
import { fmtTime } from '@/utils/format'

interface NavItem {
  path: string
  icon: Component
  label: string
  active: string
  badge?: boolean
}

interface NavGroup {
  title: string
  actives: string[]
  items: NavItem[]
}

const route = useRoute()
const active = computed(() => (route.meta.active as string) || '')
const username = ref(sessionStorage.getItem('admin_username') || '管理员')
const alertBadge = ref(false)
const pendingAlert = ref<{ id: string; level: string; title: string; created_at?: string } | null>(null)
const bannerDismissed = ref(false)
let pollTimer: ReturnType<typeof setInterval> | null = null

const navGroups: NavGroup[] = [
  {
    title: '总览',
    actives: ['dashboard', 'stats'],
    items: [
      { path: '/dashboard', icon: markRaw(Odometer), label: '仪表盘', active: 'dashboard' },
      { path: '/stats', icon: markRaw(TrendCharts), label: '用量统计', active: 'stats' },
    ],
  },
  {
    title: '用户运营',
    actives: ['users', 'invites', 'rewards', 'feedback'],
    items: [
      { path: '/users', icon: markRaw(User), label: '用户管理', active: 'users' },
      { path: '/invites', icon: markRaw(Ticket), label: '邀请码管理', active: 'invites' },
      { path: '/rewards', icon: markRaw(Present), label: '积分奖励明细', active: 'rewards' },
      { path: '/feedback', icon: markRaw(ChatDotRound), label: '反馈意见', active: 'feedback' },
    ],
  },
  {
    title: '套餐计费',
    actives: ['plans', 'billing_catalog', 'billing_margin', 'plan_accounts', 'ledger', 'payment_providers', 'apple_iap', 'payment_orders', 'payment_transactions', 'payment_refunds', 'webhook_events'],
    items: [
      { path: '/plans', icon: markRaw(Medal), label: '套餐配置', active: 'plans' },
      { path: '/billing-catalog', icon: markRaw(PriceTag), label: '计费目录', active: 'billing_catalog' },
      { path: '/billing-margin', icon: markRaw(Histogram), label: '计费经济性', active: 'billing_margin' },
      { path: '/plan-accounts', icon: markRaw(Tickets), label: '套餐账号', active: 'plan_accounts' },
      { path: '/ledger', icon: markRaw(Wallet), label: '积分账本', active: 'ledger' },
      { path: '/payment-providers', icon: markRaw(OfficeBuilding), label: '支付配置', active: 'payment_providers' },
      { path: '/apple-iap', icon: markRaw(Iphone), label: 'iOS 内购', active: 'apple_iap' },
      { path: '/payment-orders', icon: markRaw(Box), label: '支付订单', active: 'payment_orders' },
      { path: '/payment-transactions', icon: markRaw(Refresh), label: '交易流水', active: 'payment_transactions' },
      { path: '/payment-refunds', icon: markRaw(RefreshLeft), label: '退款管理', active: 'payment_refunds' },
      { path: '/webhook-events', icon: markRaw(Message), label: 'Webhook 事件', active: 'webhook_events' },
    ],
  },
  {
    title: '系统运维',
    actives: ['logs', 'alerts', 'security'],
    items: [
      { path: '/logs', icon: markRaw(Document), label: '客户端日志', active: 'logs' },
      { path: '/alerts', icon: markRaw(Bell), label: '告警管理', active: 'alerts', badge: true },
      { path: '/security', icon: markRaw(Lock), label: '安全风控', active: 'security' },
    ],
  },
  {
    title: '内容配置',
    actives: ['config', 'provider_config', 'user_dict', 'personas', 'agreements'],
    items: [
      { path: '/config', icon: markRaw(Setting), label: '系统配置', active: 'config' },
      { path: '/provider-config', icon: markRaw(Connection), label: 'Provider 配置', active: 'provider_config' },
      { path: '/user-dict', icon: markRaw(Notebook), label: '用户词典', active: 'user_dict' },
      { path: '/personas', icon: markRaw(Avatar), label: '内置人设', active: 'personas' },
      { path: '/agreements', icon: markRaw(Document), label: '协议管理', active: 'agreements' },
    ],
  },
]

const crumb = computed(() => {
  for (const g of navGroups) {
    const item = g.items.find((i) => i.active === active.value)
    if (item) return { group: g.title, page: item.label }
  }
  if (active.value === 'account') return { group: '账户', page: '账号安全' }
  return { group: '', page: '' }
})

function isGroupOpen(group: NavGroup): boolean {
  return group.actives.includes(active.value)
}

function levelLabel(level: string): string {
  if (level === 'critical') return '严重'
  if (level === 'warning') return '警告'
  return '信息'
}

async function checkPendingAlert() {
  try {
    const data = await api<{ alert: typeof pendingAlert.value }>('GET', '/api/v1/alerts/latest-pending')
    pendingAlert.value = data.alert
    alertBadge.value = !!data.alert
    if (data.alert && sessionStorage.getItem('alert_banner_dismissed') === data.alert.id) {
      bannerDismissed.value = true
    }
  } catch {
    /* ignore */
  }
}

function dismissBanner() {
  if (pendingAlert.value) {
    sessionStorage.setItem('alert_banner_dismissed', pendingAlert.value.id)
  }
  bannerDismissed.value = true
}

const showBanner = computed(() => pendingAlert.value && !bannerDismissed.value)

watch(() => route.path, () => {
  if (route.path === '/alerts') bannerDismissed.value = true
})

onMounted(() => {
  checkPendingAlert()
  pollTimer = setInterval(checkPendingAlert, 60000)
})

onUnmounted(() => {
  if (pollTimer) clearInterval(pollTimer)
})

async function doLogout() {
  await logout()
}
</script>

<template>
  <div :class="{ 'has-banner': showBanner }">
    <div v-if="showBanner && pendingAlert" class="global-alert-banner">
      <el-icon class="banner-icon"><Bell /></el-icon>
      <span class="banner-label">未处理告警</span>
      <span class="banner-title">[{{ levelLabel(pendingAlert.level) }}] {{ pendingAlert.title }}</span>
      <span class="banner-time">{{ fmtTime(pendingAlert.created_at) }}</span>
      <router-link to="/alerts" class="banner-link">查看全部告警 →</router-link>
      <button class="banner-close" aria-label="关闭" @click="dismissBanner">✕</button>
    </div>

    <div class="layout">
      <aside class="sidebar">
        <div class="sidebar-logo">
          <span class="logo-mark">🦞</span>
          <span class="logo-text">
            Lobster
            <small>管理后台</small>
          </span>
        </div>
        <nav class="sidebar-nav">
          <details v-for="group in navGroups" :key="group.title" class="nav-section" :open="isGroupOpen(group)">
            <summary class="nav-section-title">{{ group.title }}</summary>
            <router-link
              v-for="item in group.items"
              :key="item.path"
              :to="item.path"
              class="nav-item"
              :class="{ active: active === item.active }"
            >
              <span class="nav-icon"><el-icon><component :is="item.icon" /></el-icon></span>
              <span>{{ item.label }}</span>
              <span v-if="item.badge && alertBadge" class="nav-alert-badge">!</span>
            </router-link>
          </details>
        </nav>
        <div class="sidebar-footer">
          <span class="brand-version">v1 · Admin Console</span>
        </div>
      </aside>

      <main class="main">
        <header class="topbar">
          <div class="topbar-title">
            <span v-if="crumb.group" class="crumb">{{ crumb.group }}</span>
            <el-icon v-if="crumb.group" class="crumb-sep"><ArrowRight /></el-icon>
            <span>{{ crumb.page }}</span>
          </div>
          <div class="topbar-right">
            <router-link to="/account" class="user-chip" :class="{ active: active === 'account' }">
              <el-icon><Key /></el-icon>
              <span>{{ username }}</span>
            </router-link>
            <button class="btn-logout topbar-logout" @click="doLogout">
              <el-icon><SwitchButton /></el-icon>
              <span>退出</span>
            </button>
          </div>
        </header>
        <router-view />
      </main>
    </div>
  </div>
</template>

<style scoped>
.has-banner .layout { padding-top: 44px; }

.global-alert-banner {
  position: fixed;
  top: 0; left: 0; right: 0;
  z-index: 9999;
  background: linear-gradient(90deg, #b91c1c, #ef4444);
  color: #fff;
  padding: 10px 20px;
  display: flex;
  align-items: center;
  gap: 12px;
  box-shadow: 0 4px 16px rgba(0, 0, 0, 0.35);
}
.banner-icon { font-size: 16px; }
.banner-label { font-weight: 700; font-size: 13px; }
.banner-title { font-size: 13px; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.banner-time { font-size: 12px; opacity: 0.85; }
.banner-link {
  background: rgba(255, 255, 255, 0.2);
  color: #fff;
  padding: 4px 12px;
  border-radius: 6px;
  font-size: 12px;
  white-space: nowrap;
  transition: background 0.15s;
}
.banner-link:hover { background: rgba(255, 255, 255, 0.32); }
.banner-close {
  background: none; border: none; color: #fff;
  cursor: pointer; font-size: 15px; opacity: 0.8; padding: 0 4px;
}
.banner-close:hover { opacity: 1; }

.crumb-sep { font-size: 11px; color: var(--text-faint); }

.brand-version {
  font-size: 11.5px;
  color: var(--text-faint);
  letter-spacing: 0.3px;
  font-weight: 500;
}

.user-chip {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  padding: 6px 12px;
  border-radius: var(--r-pill);
  border: 1px solid var(--border);
  color: var(--text-muted);
  font-size: 13px;
  font-weight: 500;
  max-width: 200px;
  transition: all 0.18s var(--ease);
}
.user-chip span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.user-chip:hover, .user-chip.active { color: var(--text); border-color: var(--border-strong); background: var(--bg-hover); }

.topbar-logout { display: inline-flex; align-items: center; gap: 6px; }

.nav-alert-badge {
  background: var(--danger);
  border-radius: var(--r-pill);
  color: #fff;
  font-size: 10px;
  font-weight: 700;
  margin-left: auto;
  padding: 1px 7px;
  box-shadow: 0 0 0 3px var(--danger-soft);
}

@media (max-width: 760px) {
  .user-chip span { display: none; }
  .topbar-logout span { display: none; }
}
</style>
