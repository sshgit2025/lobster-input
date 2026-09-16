<script setup lang="ts">
import { RouterView } from 'vue-router'
import SvgSprite from '@/components/common/SvgSprite.vue'
import SiteHeader from '@/components/layout/SiteHeader.vue'
</script>

<template>
  <SvgSprite />
  <SiteHeader />
  <RouterView />
</template>
