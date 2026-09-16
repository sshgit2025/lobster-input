/** 内测解锁状态、倒计时与各平台下载（逐字移植自原 download.js 的常量与逻辑）。 */
import { ref } from 'vue'

/** 内测开放：2026-05-24 14:00 北京时间 */
const BETA_UNLOCK_AT = Date.parse('2026-05-24T14:00:00+08:00')

export type Platform = 'android' | 'ios' | 'windows' | 'mac' | 'unknown'

export interface DownloadInfo {
  url: string
  version: string
}

export const DOWNLOADS: Record<'mac' | 'windows' | 'android', DownloadInfo> = {
  // 官网分发一律指向 uat(公测·正式版)通道的包;preview 内测包不在官网分发
  mac: {
    url: 'https://downloads.example.com/uat/mac/voice-input-0.0.1-b220.zip',
    version: '0.0.1 (220)',
  },
  windows: {
    url: 'https://downloads.example.com/windows/preview/%E9%BE%99%E8%99%BE%E8%BE%93%E5%85%A5%E6%B3%95-preview-0.1.88-Setup.exe',
    version: '0.1.88',
  },
  android: {
    url: 'https://downloads.example.com/uat/android/lobster-input-0.0.1.apk',
    version: '0.0.1',
  },
}

export function detectPlatform(): Platform {
  if (typeof navigator === 'undefined') return 'unknown'
  const ua = navigator.userAgent || ''
  const plat =
    (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData?.platform ||
    navigator.platform ||
    ''
  const p = String(plat).toLowerCase()
  if (/android/i.test(ua)) return 'android'
  if (/iphone|ipad|ipod/i.test(ua)) return 'ios'
  if (/win/i.test(p) || /windows/i.test(ua)) return 'windows'
  if (/mac/i.test(p) || /macintosh|mac os x/i.test(ua)) return 'mac'
  return 'unknown'
}

// ── 共享倒计时状态（模块级单例，全站一致）──
const unlocked = ref(Date.now() >= BETA_UNLOCK_AT)
const days = ref(0)
const hours = ref(0)
const minutes = ref(0)
const seconds = ref(0)
let started = false

function tick(): void {
  const remain = BETA_UNLOCK_AT - Date.now()
  if (remain <= 0) {
    unlocked.value = true
    days.value = hours.value = minutes.value = seconds.value = 0
    return
  }
  const total = Math.max(0, Math.floor(remain / 1000))
  days.value = Math.floor(total / 86400)
  hours.value = Math.floor((total % 86400) / 3600)
  minutes.value = Math.floor((total % 3600) / 60)
  seconds.value = total % 60
  const delay = remain > 1000 ? 250 : Math.max(16, remain)
  setTimeout(tick, delay)
}

function startCountdown(): void {
  if (started) return
  started = true
  if (!unlocked.value) tick()
}

export function useBeta() {
  startCountdown()
  return { unlocked, days, hours, minutes, seconds, DOWNLOADS, detectPlatform }
}
