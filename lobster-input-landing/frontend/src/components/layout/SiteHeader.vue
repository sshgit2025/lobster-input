<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { t, tHtml } from '@/i18n'
import LanguageMenu from '@/components/common/LanguageMenu.vue'
import { useAuthStore } from '@/stores/auth'
import { useBeta } from '@/composables/useBeta'

const route = useRoute()
const router = useRouter()
const isHome = computed(() => route.name === 'home')
const { email, isAuthenticated, logout } = useAuthStore()
const { unlocked } = useBeta()

const accountOpen = ref(false)
const avatarLetter = computed(() => (email.value || '?').charAt(0))

function toggleAccount() {
  accountOpen.value = !accountOpen.value
}
function onDocClick(e: MouseEvent) {
  if (!(e.target as HTMLElement).closest('.account-menu')) accountOpen.value = false
}
async function doLogout() {
  accountOpen.value = false
  await logout()
  router.push('/')
}
function goAccount() {
  accountOpen.value = false
  router.push('/account')
}
onMounted(() => document.addEventListener('click', onDocClick))
onBeforeUnmount(() => document.removeEventListener('click', onDocClick))
</script>

<template>
  <header class="topbar">
    <div class="wrap topbar-inner">
      <RouterLink class="brand" to="/">
        <svg class="brand-mark" style="color:var(--lobster)"><use href="#lobster" /></svg>
        <span class="brand-name" v-html="tHtml('brandName')"></span>
      </RouterLink>

      <nav v-if="isHome" class="nav">
        <a href="#features">{{ t('navFeatures') }}</a>
        <a href="#vibe">{{ t('navVibe') }}</a>
        <a href="#flow">{{ t('navFlow') }}</a>
        <a href="#modes">{{ t('navModes') }}</a>
        <a href="#beta-banner">{{ t('navBeta') }}</a>
      </nav>

      <div class="top-meta">
        <LanguageMenu />

        <!-- 登录态 -->
        <template v-if="isAuthenticated">
          <div class="account-menu" :class="{ 'is-open': accountOpen }">
            <button class="account-toggle" type="button" @click.stop="toggleAccount">
              <span class="avatar">{{ avatarLetter }}</span>
              <span class="account-email">{{ email }}</span>
            </button>
            <div class="account-list" role="menu">
              <div class="account-head">
                <div class="k">{{ t('ui_account') }}</div>
                <div class="v">{{ email }}</div>
              </div>
              <button class="account-item" type="button" @click.stop="goAccount">
                <svg><use href="#ic-user" /></svg>{{ t('ui_account') }}
              </button>
              <button class="account-item" type="button" @click.stop="doLogout">
                <svg><use href="#ic-logout" /></svg>{{ t('ui_logout') }}
              </button>
            </div>
          </div>
        </template>
        <RouterLink v-else class="account-link" to="/login">
          <svg width="13" height="13"><use href="#ic-user" /></svg>
          <span>{{ t('ui_loginRegister') }}</span>
        </RouterLink>

        <!-- 首页：内测 CTA；子页：返回首页 -->
        <template v-if="isHome">
          <a v-if="!unlocked" class="cta-pill" href="#beta-banner"><span class="dot"></span> <span>{{ t('navCta') }}</span></a>
          <a v-else class="cta-pill" href="#beta"><span class="dot"></span> <span>{{ t('navCtaLive') }}</span></a>
        </template>
        <RouterLink v-else class="top-back" to="/">
          <svg><use href="#ic-arrow-left" /></svg>
          <span>{{ t('ui_backHome') }}</span>
        </RouterLink>
      </div>
    </div>
  </header>
</template>
