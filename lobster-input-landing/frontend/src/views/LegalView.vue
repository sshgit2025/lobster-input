<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue'
import { RouterLink, useRoute } from 'vue-router'
import { marked } from 'marked'
import { t, currentLang } from '@/i18n'
import { fetchAgreement } from '@/api/agreements'

const route = useRoute()
const type = computed<'privacy' | 'terms'>(() => (route.name === 'terms' ? 'terms' : 'privacy'))
const titleKey = computed(() => (type.value === 'terms' ? 'terms' : 'privacy'))

const html = ref('')
const updatedAt = ref<string | null>(null)
const loading = ref(true)
const empty = ref(false)

function fmtDate(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

async function load() {
  loading.value = true
  empty.value = false
  try {
    const a = await fetchAgreement(type.value, currentLang.value)
    updatedAt.value = a.updated_at || null
    if (!a.content) {
      empty.value = true
      html.value = ''
    } else {
      html.value = await marked.parse(a.content)
    }
  } catch {
    empty.value = true
    html.value = ''
  } finally {
    loading.value = false
  }
}

watch([type, currentLang], load)
onMounted(load)
</script>

<template>
  <main>
    <section class="legal-hero">
      <div class="wrap">
        <div class="legal-eyebrow"><span class="num">§</span> <span>LEGAL · 法律条款</span></div>
        <h1 class="legal-title">{{ t(titleKey) }}</h1>
        <div v-if="updatedAt" class="legal-meta">
          <div class="mi">
            <span class="k">Last Updated</span>
            <span class="v">{{ fmtDate(updatedAt) }}</span>
          </div>
        </div>
      </div>
    </section>

    <div class="legal-body">
      <div class="wrap">
        <div v-if="loading" class="legal-state">{{ t('ui_loading') }}</div>
        <div v-else-if="empty" class="legal-state">—</div>
        <article v-else class="legal-article" v-html="html"></article>
      </div>
    </div>

    <footer class="foot-bottom-wrap">
      <div class="wrap">
        <div class="foot-bottom" style="margin-top:0;border-top:1px solid var(--rule-2);">
          <span>{{ t('footCopy') }}</span>
          <span class="icp" style="display:flex;gap:18px;align-items:center;">
            <RouterLink to="/privacy">{{ t('privacy') }}</RouterLink>
            <RouterLink to="/terms">{{ t('terms') }}</RouterLink>
            <a href="https://beian.miit.gov.cn/" target="_blank" rel="noopener noreferrer">冀ICP备2026012846号</a>
          </span>
        </div>
      </div>
    </footer>
  </main>
</template>
