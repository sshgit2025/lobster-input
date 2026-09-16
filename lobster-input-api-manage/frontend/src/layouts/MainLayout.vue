<script setup lang="ts">
import { computed, markRaw, type Component } from 'vue'
import { useRoute } from 'vue-router'
import { Odometer, Key, Document, Lock, SwitchButton } from '@element-plus/icons-vue'
import { logout } from '@/api'

interface NavItem {
  path: string
  icon: Component
  label: string
  active: string
}

const route = useRoute()
const active = computed(() => (route.meta.active as string) || '')

const navItems: NavItem[] = [
  { path: '/dashboard', icon: markRaw(Odometer), label: '仪表盘', active: 'dashboard' },
  { path: '/keys', icon: markRaw(Key), label: 'Key 管理', active: 'keys' },
  { path: '/usage', icon: markRaw(Document), label: '消费明细', active: 'usage' },
  { path: '/account', icon: markRaw(Lock), label: '账号安全', active: 'account' },
]

const currentLabel = computed(() => navItems.find((i) => i.active === active.value)?.label || '')

async function doLogout() {
  await logout()
}
</script>

<template>
  <div class="layout">
    <aside class="sidebar">
      <div class="sidebar-logo">
        <span class="logo-mark"><el-icon><Key /></el-icon></span>
        <span class="logo-text">
          API Pool
          <small>号池管理平台</small>
        </span>
      </div>
      <nav class="sidebar-nav">
        <router-link
          v-for="item in navItems"
          :key="item.path"
          :to="item.path"
          class="nav-item"
          :class="{ active: active === item.active }"
        >
          <span class="nav-icon"><el-icon><component :is="item.icon" /></el-icon></span>
          <span>{{ item.label }}</span>
        </router-link>
      </nav>
      <div class="sidebar-footer">
        <span class="brand-version">v1 · API Pool Console</span>
      </div>
    </aside>
    <main class="main">
      <header class="topbar">
        <div class="topbar-title">
          <span class="crumb">号池</span>
          <span class="crumb-sep">›</span>
          <span>{{ currentLabel }}</span>
        </div>
        <div class="topbar-right">
          <span class="user-chip">
            <el-icon><Lock /></el-icon>
            <span>管理员</span>
          </span>
          <button class="btn-logout topbar-logout" @click="doLogout">
            <el-icon><SwitchButton /></el-icon>
            <span>退出</span>
          </button>
        </div>
      </header>
      <router-view />
    </main>
  </div>
</template>

<style scoped>
.crumb-sep { color: var(--text-faint); font-size: 14px; }

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
}

.topbar-logout { display: inline-flex; align-items: center; gap: 6px; }

@media (max-width: 760px) {
  .user-chip span { display: none; }
  .topbar-logout span { display: none; }
}
</style>
