<script setup lang="ts">
import { t } from '@/i18n'
</script>

<template>
  <div class="runner">
    <div class="wrap" style="overflow:hidden;">
      <div class="runner-track">
        <span><span class="tick"></span> VOL. N°01</span>
        <span>EST. MMXXVI</span>
        <span>{{ t('runnerOs') }}</span>
        <span>WINDOWS · MACOS · IOS · ANDROID</span>
        <span><span class="tick"></span> AI VOICE INPUT</span>
        <span>{{ t('runnerSign') }}</span>
        <span><span class="tick"></span> {{ t('runnerBeta') }}</span>
        <!-- repeat for seamless loop -->
        <span><span class="tick"></span> VOL. N°01</span>
        <span>EST. MMXXVI</span>
        <span>{{ t('runnerOs2') }}</span>
        <span>WINDOWS · MACOS · IOS · ANDROID</span>
        <span><span class="tick"></span> AI VOICE INPUT</span>
        <span>{{ t('runnerSign2') }}</span>
        <span><span class="tick"></span> {{ t('runnerBeta2') }}</span>
      </div>
    </div>
  </div>
</template>
