<script setup lang="ts">
import { computed } from 'vue'
import { t } from '@/i18n'
import { useBeta, type DownloadInfo } from '@/composables/useBeta'

const { unlocked, days, hours, minutes, seconds, DOWNLOADS, detectPlatform } = useBeta()

const platform = detectPlatform()
const isIos = computed(() => platform === 'ios')
const isUnknown = computed(() => platform === 'unknown')
const matched = computed<DownloadInfo | null>(() => {
  if (platform === 'mac' || platform === 'windows' || platform === 'android') return DOWNLOADS[platform]
  return null
})
const matchedLabel = computed(() => {
  if (platform === 'mac') return t('heroDlMac')
  if (platform === 'windows') return t('heroDlWin')
  if (platform === 'android') return t('heroDlAndroid')
  return t('heroDlAll')
})

const pad2 = (n: number) => String(Math.max(0, n)).padStart(2, '0')
</script>

<template>
  <section class="beta-banner" id="beta-banner" aria-labelledby="beta-banner-title">
    <div class="beta-banner-inner">
      <!-- 倒计时态 -->
      <template v-if="!unlocked">
        <div class="beta-banner-lead">
          <div class="beta-banner-kicker"><span class="tick"></span> <span>{{ t('bannerKicker') }}</span></div>
          <p class="beta-banner-title" id="beta-banner-title">{{ t('bannerTitle') }}</p>
          <p class="beta-banner-sub">{{ t('bannerSub') }}</p>
        </div>
        <div class="beta-banner-countdown">
          <p class="countdown-hint">{{ t('countdownHint') }}</p>
          <div class="countdown-grid" aria-live="polite">
            <div class="countdown-unit"><div class="num">{{ days }}</div><div class="lbl">{{ t('countdownDays') }}</div></div>
            <div class="countdown-unit"><div class="num">{{ pad2(hours) }}</div><div class="lbl">{{ t('countdownHours') }}</div></div>
            <div class="countdown-unit"><div class="num">{{ pad2(minutes) }}</div><div class="lbl">{{ t('countdownMinutes') }}</div></div>
            <div class="countdown-unit"><div class="num">{{ pad2(seconds) }}</div><div class="lbl">{{ t('countdownSeconds') }}</div></div>
          </div>
        </div>
      </template>

      <!-- 下载态 -->
      <div v-else class="beta-banner-lead" style="grid-column:1/-1;">
        <div class="beta-banner-kicker"><span class="tick"></span> <span>{{ t('bannerKickerLive') }}</span></div>
        <p class="beta-banner-title">{{ t('bannerTitleLive') }}</p>
        <p class="beta-banner-sub">{{ t('bannerSubLive') }}</p>
        <div class="beta-banner-actions">
          <a v-if="matched" class="btn-primary" :href="matched.url" download>
            <span>{{ matchedLabel }}</span><svg width="18" height="18"><use href="#ic-arrow" /></svg>
          </a>
          <a v-else-if="isUnknown" class="btn-primary" href="#beta">
            <span>{{ t('heroDlAll') }}</span><svg width="18" height="18"><use href="#ic-arrow" /></svg>
          </a>
          <a class="btn-ghost" href="#beta"><span>{{ t('heroDlMore') }}</span></a>
        </div>
        <p v-if="isIos" class="beta-banner-ios">{{ t('dlIosNote') }}</p>
      </div>
    </div>
  </section>
</template>
