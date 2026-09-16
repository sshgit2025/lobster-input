<script setup lang="ts">
import { t, tHtml } from '@/i18n'
</script>

<template>
  <section class="modes" id="modes">
    <div class="wrap">
      <div class="section-tag"><span class="num">N°05</span> · <span>{{ t('modesTag') }}</span></div>
      <h2 class="section-title" v-html="tHtml('modesTitle')"></h2>
      <p class="section-lede">{{ t('modesLede') }}</p>

      <div class="mode-stack">
        <div class="mode">
          <div class="m-keys">
            <span class="kbd">⌥</span><span class="kbd plus" style="border:0;background:transparent">+</span><span class="kbd">Q</span>
          </div>
          <div class="m-label">Transcribe</div>
          <div>
            <div class="m-title"><span>{{ t('mode1Title') }}</span> <span class="en">{{ t('mode1En') }}</span></div>
            <div class="m-desc" style="margin-top:6px;">{{ t('mode1Desc') }}</div>
          </div>
        </div>

        <div class="mode">
          <div class="m-keys">
            <span class="kbd">⌥</span><span class="kbd plus" style="border:0;background:transparent">+</span><span class="kbd">E</span>
          </div>
          <div class="m-label">Rewrite</div>
          <div>
            <div class="m-title"><span>{{ t('mode2Title') }}</span> <span class="en">{{ t('mode2En') }}</span></div>
            <div class="m-desc" style="margin-top:6px;">{{ t('mode2Desc') }}</div>
          </div>
        </div>

        <div class="mode">
          <div class="m-keys">
            <span class="kbd">⌥</span><span class="kbd plus" style="border:0;background:transparent">+</span><span class="kbd">W</span>
          </div>
          <div class="m-label">Agent</div>
          <div>
            <div class="m-title"><span>{{ t('mode3Title') }}</span> <span class="en">{{ t('mode3En') }}</span></div>
            <div class="m-desc" style="margin-top:6px;">{{ t('mode3Desc') }}</div>
          </div>
        </div>
      </div>
    </div>
  </section>
</template>
