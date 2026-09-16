<script setup lang="ts">
import { t, tHtml } from '@/i18n'
import { useBeta } from '@/composables/useBeta'
import { useTypewriter } from '@/composables/useTypewriter'

const { unlocked } = useBeta()
const { text } = useTypewriter()
</script>

<template>
  <section class="hero">
    <div class="wrap">
      <div class="hero-grid">
        <div class="hero-left" style="position:relative;">
          <span class="vol-marker">{{ t('volMarker') }}</span>
          <div class="eyebrow">
            <span class="num">N°01</span>
            <span>·</span>
            <span>{{ t('eyebrowZh') }}</span>
            <span>·</span>
            <span>{{ t('eyebrowEn') }}</span>
          </div>
          <h1 class="headline" v-html="tHtml('headline')"></h1>
          <p class="lede" v-html="tHtml('lede')"></p>
          <div class="hero-cta-row">
            <a v-if="!unlocked" class="btn-primary" href="#beta-banner">
              <span>{{ t('ctaPrimary') }}</span>
              <svg width="18" height="18"><use href="#ic-arrow" /></svg>
            </a>
            <a v-else class="btn-primary" href="#beta">
              <span>{{ t('ctaPrimaryLive') }}</span>
              <svg width="18" height="18"><use href="#ic-arrow" /></svg>
            </a>
            <a class="btn-ghost" href="#features">
              <svg width="14" height="14"><use href="#ic-bullet" /></svg>
              <span>{{ t('ctaSecondary') }}</span>
            </a>
          </div>
          <div class="compat">
            <span class="compat-item"><svg width="14" height="14"><use href="#ic-check" /></svg> <span>{{ t('compat1') }}</span></span>
            <span style="color:var(--rule-2)">/</span>
            <span class="compat-item"><svg width="14" height="14"><use href="#ic-check" /></svg> <span>{{ t('compat2') }}</span></span>
            <span style="color:var(--rule-2)">/</span>
            <span class="compat-item"><svg width="14" height="14"><use href="#ic-check" /></svg> <span>{{ t('compat3') }}</span></span>
          </div>
        </div>

        <!-- Mac mockup -->
        <div class="hero-right">
          <div class="mac" id="mac">
            <div class="mac-bar">
              <span class="dot dot-r"></span>
              <span class="dot dot-y"></span>
              <span class="dot dot-g"></span>
              <span class="mac-title">{{ t('macTitle') }}</span>
            </div>
            <div class="mac-body">
              <aside class="mac-side">
                <div class="brand-mini">
                  <svg width="20" height="20" style="color:var(--lobster)"><use href="#lobster" /></svg>
                  <b>Lobster</b>
                </div>
                <div class="item active">
                  <svg><use href="#ic-home" /></svg> <span>{{ t('macHome') }}</span>
                </div>
                <div class="item">
                  <svg><use href="#ic-book" /></svg> <span>{{ t('macDict') }}</span>
                </div>
                <div class="item">
                  <svg><use href="#ic-mask" /></svg> <span>{{ t('macPersona') }}</span>
                </div>
                <div class="item">
                  <svg><use href="#ic-history" /></svg> <span>{{ t('macHistory') }}</span>
                </div>
                <div class="item">
                  <svg><use href="#ic-settings" /></svg> <span>{{ t('macSettings') }}</span>
                </div>
                <div class="group" style="margin-top:auto">{{ t('macShortcutsGroup') }}</div>
                <div style="font-family:'Geist Mono',monospace;font-size:11px;color:var(--ink-3);line-height:1.9;padding:0 9px;">
                  <div>⌥Q · <span>{{ t('macKeyTranscribe') }}</span></div>
                  <div>⌥E · <span>{{ t('macKeyRewrite') }}</span></div>
                  <div>⌥W · Agent</div>
                </div>
              </aside>
              <div class="mac-main">
                <div class="mac-h">{{ t('macGuide') }}</div>
                <div class="shortcut-row">
                  <span class="keys">
                    <span class="kbd">⌥</span><span class="kbd plus">+</span><span class="kbd">Q</span>
                  </span>
                  <span class="label" v-html="tHtml('shortcut1')"></span>
                </div>
                <div class="shortcut-row">
                  <span class="keys">
                    <span class="kbd">⌥</span><span class="kbd plus">+</span><span class="kbd">E</span>
                  </span>
                  <span class="label" v-html="tHtml('shortcut2')"></span>
                </div>
                <div class="shortcut-row" style="border-bottom:0;">
                  <span class="keys">
                    <span class="kbd">⌥</span><span class="kbd plus">+</span><span class="kbd">W</span>
                  </span>
                  <span class="label" v-html="tHtml('shortcut3')"></span>
                </div>

                <div class="rec-stage">
                  <span class="rec-led"></span>
                  <div class="rec-wave">
                    <span style="animation-delay:0s"></span>
                    <span style="animation-delay:.08s"></span>
                    <span style="animation-delay:.16s"></span>
                    <span style="animation-delay:.24s"></span>
                    <span style="animation-delay:.32s"></span>
                    <span style="animation-delay:.4s"></span>
                    <span style="animation-delay:.48s"></span>
                    <span style="animation-delay:.56s"></span>
                    <span style="animation-delay:.64s"></span>
                    <span style="animation-delay:.56s"></span>
                    <span style="animation-delay:.48s"></span>
                    <span style="animation-delay:.4s"></span>
                    <span style="animation-delay:.32s"></span>
                    <span style="animation-delay:.24s"></span>
                    <span style="animation-delay:.16s"></span>
                    <span style="animation-delay:.08s"></span>
                  </div>
                  <span class="rec-text">REC · 0:08</span>
                </div>

                <div class="transcript">
                  <span class="ai-stamp">// transcript</span>
                  <span id="typed">{{ text }}</span><span class="caret"></span>
                </div>
              </div>
            </div>
          </div>

          <div class="float-tag" style="top:-14px;right:-10px;">
            <span class="lead">{{ t('floatStatusLead') }}</span>
            <span v-html="tHtml('floatStatusBody')"></span>
          </div>
        </div>
      </div>
    </div>
  </section>
</template>
