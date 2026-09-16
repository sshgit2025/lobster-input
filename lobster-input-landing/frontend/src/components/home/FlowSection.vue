<script setup lang="ts">
import { t, tHtml } from '@/i18n'
</script>

<template>
  <section class="flow" id="flow">
    <div class="wrap">
      <div class="section-tag"><span class="num">N°04</span> · <span>{{ t('flowTag') }}</span></div>
      <h2 class="section-title" v-html="tHtml('flowTitle')"></h2>

      <div class="step-list">
        <div class="step">
          <div class="num-big">01<sup>I</sup></div>
          <h3>{{ t('step1Title') }}</h3>
          <p>{{ t('step1Desc') }}</p>
          <div class="step-vis">
            <svg viewBox="0 0 240 80" fill="none" style="width:100%;height:100%">
              <rect x="14" y="20" width="50" height="50" rx="8" stroke="var(--ink)" stroke-width="1.5"/>
              <text x="39" y="52" text-anchor="middle" font-family="Geist Mono" font-size="18" fill="var(--ink)">⌥</text>
              <text x="84" y="50" text-anchor="middle" font-family="Geist Mono" font-size="18" fill="var(--ink-3)">+</text>
              <rect x="104" y="20" width="50" height="50" rx="8" stroke="var(--ink)" stroke-width="1.5"/>
              <text x="129" y="52" text-anchor="middle" font-family="Geist Mono" font-size="18" fill="var(--ink)">Q</text>
              <path d="M174 45 H225 M215 38 L225 45 L215 52" stroke="var(--lobster)" stroke-width="1.6" fill="none" stroke-linecap="round"/>
            </svg>
          </div>
        </div>
        <div class="step">
          <div class="num-big">02<sup>II</sup></div>
          <h3>{{ t('step2Title') }}</h3>
          <p>{{ t('step2Desc') }}</p>
          <div class="step-vis">
            <svg viewBox="0 0 240 80" fill="none" style="width:100%;height:100%">
              <g stroke="var(--ink)" stroke-width="1.6" stroke-linecap="round">
                <path d="M10 40 L10 40"/>
                <path d="M22 36 V44"/>
                <path d="M34 30 V50"/>
                <path d="M46 20 V60"/>
                <path d="M58 26 V54"/>
                <path d="M70 34 V46"/>
                <path d="M82 28 V52"/>
                <path d="M94 18 V62"/>
                <path d="M106 24 V56"/>
                <path d="M118 32 V48"/>
                <path d="M130 22 V58"/>
                <path d="M142 28 V52"/>
                <path d="M154 36 V44"/>
                <path d="M166 30 V50"/>
                <path d="M178 38 V42"/>
                <path d="M190 40 V40"/>
              </g>
              <path d="M205 40 H225 M218 33 L225 40 L218 47" stroke="var(--lobster)" stroke-width="1.6" fill="none" stroke-linecap="round"/>
            </svg>
          </div>
        </div>
        <div class="step">
          <div class="num-big">03<sup>III</sup></div>
          <h3>{{ t('step3Title') }}</h3>
          <p>{{ t('step3Desc') }}</p>
          <div class="step-vis">
            <svg viewBox="0 0 240 80" fill="none" style="width:100%;height:100%">
              <rect x="10" y="22" width="180" height="40" rx="6" stroke="var(--ink)" stroke-width="1.5"/>
              <text x="22" y="48" font-family="Noto Serif SC" font-size="15" fill="var(--ink)">{{ t('step3VisText') }}</text>
              <rect x="178" y="32" width="1.5" height="20" fill="var(--lobster)">
                <animate attributeName="opacity" values="1;0;1" dur="1s" repeatCount="indefinite"/>
              </rect>
              <path d="M205 42 H225 M218 35 L225 42 L218 49" stroke="var(--lobster)" stroke-width="1.6" fill="none" stroke-linecap="round"/>
            </svg>
          </div>
        </div>
      </div>
    </div>
  </section>
</template>
