<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount } from 'vue'
import { languages, currentLang, selectLocale, t } from '@/i18n'

const open = ref(false)
const currentLabel = computed(() => languages.find((l) => l.code === currentLang.value)?.label || '')

function toggle() {
  open.value = !open.value
}
function choose(code: string) {
  selectLocale(code)
  open.value = false
}
function onDocClick(e: MouseEvent) {
  if (!(e.target as HTMLElement).closest('.language-menu')) open.value = false
}
onMounted(() => document.addEventListener('click', onDocClick))
onBeforeUnmount(() => document.removeEventListener('click', onDocClick))
</script>

<template>
  <div class="language-menu" :class="{ 'is-open': open }">
    <button
      class="language-toggle"
      type="button"
      aria-haspopup="true"
      :aria-expanded="open"
      :title="t('languageAria') || 'Change language'"
      @click.stop="toggle"
    >
      <svg width="13" height="13"><use href="#ic-globe" /></svg>
      <span class="language-current">{{ currentLabel }}</span>
    </button>
    <div class="language-list" role="menu" aria-label="Language selector">
      <button
        v-for="l in languages"
        :key="l.code"
        class="language-option"
        :class="{ 'is-active': l.code === currentLang }"
        type="button"
        @click.stop="choose(l.code)"
      >
        <span>{{ l.label }}</span>
        <svg class="check" width="16" height="16"><use href="#ic-check" /></svg>
      </button>
    </div>
  </div>
</template>
