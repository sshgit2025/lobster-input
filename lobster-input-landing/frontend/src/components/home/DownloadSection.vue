<script setup lang="ts">
import { computed } from 'vue'
import { t, tHtml } from '@/i18n'
import { useBeta } from '@/composables/useBeta'

const { unlocked, DOWNLOADS, detectPlatform } = useBeta()
const platform = detectPlatform()
const isIos = computed(() => platform === 'ios')

interface Card {
  key: 'mac' | 'windows' | 'android'
  titleKey: string
  btnKey: string
  url: string
  version: string
  primary: boolean
}

const allCards: Omit<Card, 'primary'>[] = [
  { key: 'mac', titleKey: 'dlMacTitle', btnKey: 'dlMacBtn', url: DOWNLOADS.mac.url, version: DOWNLOADS.mac.version },
  { key: 'windows', titleKey: 'dlWinTitle', btnKey: 'dlWinBtn', url: DOWNLOADS.windows.url, version: DOWNLOADS.windows.version },
  { key: 'android', titleKey: 'dlAndroidTitle', btnKey: 'dlAndroidBtn', url: DOWNLOADS.android.url, version: DOWNLOADS.android.version },
]

const visibleCards = computed<Card[]>(() => {
  return allCards.map((c) => ({ ...c, primary: c.key === platform }))
})
</script>

<template>
  <section class="cta-section" id="beta">
    <svg class="cta-big-mark" width="520" height="520" style="color:var(--cream);"><use href="#lobster" /></svg>
    <div class="wrap">
      <div class="cta-inner">
        <div>
          <div class="section-tag" style="color:#fde8df;margin-bottom:18px;">
            <span class="num" style="color:#fde8df;">N°06</span> · <span>{{ t('ctaTag') }}</span>
          </div>
          <h2 v-if="!unlocked" v-html="tHtml('ctaTitle')"></h2>
          <h2 v-else v-html="tHtml('ctaTitleLive')"></h2>
          <p v-if="!unlocked" class="sub">{{ t('ctaFooterSub') }}</p>
          <p v-else class="sub">{{ t('ctaSubLive') }}</p>

          <div v-if="unlocked" id="beta-download">
            <div class="beta-download-cards">
              <article
                v-for="card in visibleCards"
                :key="card.key"
                class="dl-card"
                :class="{ 'is-primary': card.primary }"
                :data-dl-platform="card.key"
              >
                <div class="dl-card-main">
                  <div class="dl-card-title">{{ t(card.titleKey) }}</div>
                  <div class="dl-card-meta"><span>{{ t('dlVersionLabel') }}</span> <span>{{ card.version }}</span></div>
                </div>
                <a class="dl-card-action" :href="card.url" download rel="noopener">
                  <span>{{ t(card.btnKey) }}</span><svg width="16" height="16"><use href="#ic-arrow" /></svg>
                </a>
              </article>
            </div>
            <p v-if="isIos" class="beta-ios-note">{{ t('dlIosNote') }}</p>
          </div>
        </div>
        <div class="stamp-row">
          <span class="stamp"><svg width="14" height="14"><use href="#ic-check" /></svg> <span>{{ t('stamp1') }}</span></span>
          <span class="stamp"><svg width="14" height="14"><use href="#ic-check" /></svg> <span>{{ t('stamp2') }}</span></span>
          <span class="stamp"><svg width="14" height="14"><use href="#ic-check" /></svg> <span>{{ t('stamp3') }}</span></span>
          <span class="stamp"><svg width="14" height="14"><use href="#ic-check" /></svg> <span>{{ t('stamp4') }}</span></span>
        </div>
      </div>
    </div>
  </section>
</template>
