<script setup lang="ts">
import { t, tHtml } from '@/i18n'
</script>

<template>
  <section class="vibe" id="vibe">
    <div class="wrap">
      <div class="section-tag"><span class="num">N°02</span> · <span>{{ t('vibeTagText') }}</span></div>
      <div class="vibe-grid">
        <div>
          <h2 class="section-title" v-html="tHtml('vibeTitle')"></h2>
          <p class="vibe-body">{{ t('vibeBody') }}</p>

          <div class="vibe-quote">
            <div class="label">{{ t('vibeQuoteLabel') }}</div>
            <div class="said">{{ t('vibeQuoteSaid') }}</div>
          </div>
        </div>

        <div class="vibe-tags">
          <div class="vibe-tag">
            <span class="ix">i.</span>
            <div>
              <span class="txt">{{ t('vibeI') }}</span>
              <span class="sub">{{ t('vibeISub') }}</span>
            </div>
          </div>
          <div class="vibe-tag">
            <span class="ix">ii.</span>
            <div>
              <span class="txt">{{ t('vibeII') }}</span>
              <span class="sub">{{ t('vibeIISub') }}</span>
            </div>
          </div>
          <div class="vibe-tag">
            <span class="ix">iii.</span>
            <div>
              <span class="txt">{{ t('vibeIII') }}</span>
              <span class="sub">{{ t('vibeIIISub') }}</span>
            </div>
          </div>
          <div class="vibe-tag" style="border-top:1px solid #ffffff20;padding-top:22px;margin-top:8px;">
            <span class="ix" style="color:#ffffff55;">·</span>
            <div>
              <span class="txt" style="font-family:'Geist Mono',monospace;font-size:14px;letter-spacing:0.04em;color:#ffffff95;font-weight:400;">⌥Q · ⌥E · ⌥W</span>
              <span class="sub">{{ t('vibeKeysSub') }}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  </section>
</template>
