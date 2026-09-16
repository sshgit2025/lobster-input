<script setup lang="ts">
import { t, tHtml } from '@/i18n'
</script>

<template>
  <section class="features" id="features">
    <div class="wrap">
      <div class="section-tag"><span class="num">N°03</span> · <span>{{ t('featuresTag') }}</span></div>
      <h2 class="section-title" v-html="tHtml('featuresTitle')"></h2>
      <p class="section-lede" style="margin-bottom:48px;">{{ t('featuresLede') }}</p>

      <div class="feat-grid">
        <div class="feat feat-1">
          <span class="ix">{{ t('feat1Ix') }}</span>
          <div class="icon"><svg viewBox="0 0 56 56" fill="none" stroke="currentColor" stroke-width="1.6">
            <rect x="6" y="18" width="44" height="26" rx="3"/>
            <path d="M12 24h3M19 24h3M26 24h6M36 24h6M46 24h0.5M12 30h4M20 30h6M30 30h12M12 36h32"/>
            <circle cx="44" cy="6" r="3" fill="var(--lobster)" stroke="none"/>
            <path d="M44 9v6" stroke="var(--lobster)"/>
          </svg></div>
          <h3>{{ t('feat1Name') }}</h3>
          <p>{{ t('feat1Desc') }}</p>
        </div>

        <div class="feat feat-2">
          <span class="ix">{{ t('feat2Ix') }}</span>
          <div class="icon"><svg viewBox="0 0 56 56" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
            <path d="M6 28h4"/><path d="M14 22v12"/><path d="M22 16v24"/><path d="M30 11v34"/><path d="M38 18v20"/><path d="M46 24v8"/><path d="M50 28h2"/>
          </svg></div>
          <h3>{{ t('feat2Name') }}</h3>
          <p>{{ t('feat2Desc') }}</p>
        </div>

        <div class="feat feat-3">
          <span class="ix">{{ t('feat3Ix') }}</span>
          <div class="icon"><svg viewBox="0 0 56 56" fill="none" stroke="currentColor" stroke-width="1.6">
            <circle cx="28" cy="28" r="18"/>
            <path d="M28 10v36M10 28h36M16 16l24 24M16 40l24-24"/>
            <circle cx="28" cy="28" r="4" fill="currentColor"/>
          </svg></div>
          <h3>{{ t('feat3Name') }}</h3>
          <p>{{ t('feat3Desc') }}</p>
        </div>

        <div class="feat feat-4">
          <span class="ix">{{ t('feat4Ix') }}</span>
          <div class="icon"><svg viewBox="0 0 56 56" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
            <path d="M10 22 C10 14, 17 10, 28 10 C39 10, 46 14, 46 22 L46 32 C46 40, 39 46, 28 46 C17 46, 10 40, 10 32 Z"/>
            <circle cx="20" cy="26" r="2" fill="currentColor"/>
            <circle cx="36" cy="26" r="2" fill="currentColor"/>
            <path d="M20 36 C23 38, 33 38, 36 36"/>
            <path d="M14 14 L8 8 M42 14 L48 8"/>
          </svg></div>
          <h3>{{ t('feat4Name') }}</h3>
          <p>{{ t('feat4Desc') }}</p>
        </div>

        <div class="feat feat-5">
          <span class="ix">{{ t('feat5Ix') }}</span>
          <div class="icon"><svg viewBox="0 0 56 56" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round">
            <path d="M10 12 H26 C28 12, 28 13, 28 14 V46 C28 45, 28 44, 26 44 H10 Z"/>
            <path d="M46 12 H30 C28 12, 28 13, 28 14 V46 C28 45, 28 44, 30 44 H46 Z"/>
            <path d="M15 20 H23 M15 26 H23 M15 32 H20 M33 20 H41 M33 26 H41 M33 32 H38"/>
          </svg></div>
          <h3>{{ t('feat5Name') }}</h3>
          <p>{{ t('feat5Desc') }}</p>
        </div>

        <div class="feat feat-6">
          <span class="ix">{{ t('feat6Ix') }}</span>
          <div class="icon"><svg viewBox="0 0 56 56" fill="none" stroke="currentColor" stroke-width="1.6">
            <circle cx="28" cy="28" r="18"/>
            <path d="M28 16v12l9 6"/>
            <path d="M10 18 L14 22 M10 22 L14 18" stroke="var(--lobster)"/>
          </svg></div>
          <h3>{{ t('feat6Name') }}</h3>
          <p>{{ t('feat6Desc') }}</p>
        </div>
      </div>
    </div>
  </section>
</template>
