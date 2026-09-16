<script setup lang="ts">
import { RouterLink } from 'vue-router'
import { t, tHtml } from '@/i18n'
</script>

<template>
  <footer>
    <div class="wrap">
      <div class="foot-top">
        <div>
          <div class="foot-brand">
            <svg class="brand-mark" style="color:var(--lobster)"><use href="#lobster" /></svg>
            <span class="brand-name" v-html="tHtml('brandName')"></span>
          </div>
          <p class="foot-blurb">{{ t('footBlurb') }}</p>
        </div>
        <div class="foot-col">
          <h4>{{ t('footProduct') }}</h4>
          <a href="#features">{{ t('navFeatures') }}</a>
          <a href="#modes">{{ t('navModes') }}</a>
          <a href="#flow">{{ t('navFlow') }}</a>
          <a href="#beta">{{ t('footBetaLink') }}</a>
        </div>
        <div class="foot-col">
          <h4>{{ t('footSupport') }}</h4>
          <a href="mailto:support@example.com">support@example.com</a>
          <RouterLink to="/privacy">{{ t('privacy') }}</RouterLink>
          <RouterLink to="/terms">{{ t('terms') }}</RouterLink>
        </div>
        <div class="foot-col">
          <h4>{{ t('footSystem') }}</h4>
          <span class="item">Windows</span>
          <span class="item">macOS</span>
          <span class="item">iOS</span>
          <span class="item">Android</span>
        </div>
      </div>
      <div class="foot-bottom">
        <span>{{ t('footCopy') }}</span>
        <span class="icp">
          <a href="https://beian.miit.gov.cn/" target="_blank" rel="noopener noreferrer">冀ICP备2026012846号</a>
        </span>
      </div>
    </div>
  </footer>
</template>
