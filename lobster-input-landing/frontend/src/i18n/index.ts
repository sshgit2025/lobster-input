/**
 * 官网国际化运行时。
 *
 * 完整保留原 i18n.js 的语言决策机制：URL ?lang → 用户手动选择(localStorage，
 * 带版本失效) → 否则先 en 再用 IP 地理定位推断。翻译数据来自 ./locales/*。
 * currentLang 是响应式 ref，组件用 t()/tHtml() 绑定，切换语言时自动重渲染。
 */
import { ref } from 'vue'
import { languages, type LangMeta } from './languages'
import zh, { typedPhrases as zhPhrases } from './locales/zh'
import zhHant, { typedPhrases as zhHantPhrases } from './locales/zh-Hant'
import yue, { typedPhrases as yuePhrases } from './locales/yue'
import en, { typedPhrases as enPhrases } from './locales/en'
import ru, { typedPhrases as ruPhrases } from './locales/ru'
import ko, { typedPhrases as koPhrases } from './locales/ko'
import { uiMessages } from './ui'

const STORAGE_VERSION = '20260519-beta-v5'
const KEY_LANG = 'lobster_landing_lang'
const KEY_MANUAL = 'lobster_landing_lang_manual'
const KEY_VERSION = 'lobster_landing_lang_version'
const FALLBACK_LANG = 'zh' // 缺 key 时回退中文基线（与原 i18n.js 一致）
const DEFAULT_LANG = 'en'

type Messages = Record<string, string>

const messages: Record<string, Messages> = {
  zh,
  'zh-Hant': zhHant,
  yue,
  en,
  ru,
  ko,
}

// 合并新界面（登录/个人中心/页头）的 UI 文案，营销页 locale 文件保持纯净。
for (const lang of Object.keys(messages)) {
  messages[lang] = { ...messages[lang], ...(uiMessages[lang] || {}) }
}

const phrasesMap: Record<string, string[]> = {
  zh: zhPhrases,
  'zh-Hant': zhHantPhrases,
  yue: yuePhrases,
  en: enPhrases,
  ru: ruPhrases,
  ko: koPhrases,
}

export const currentLang = ref<string>(DEFAULT_LANG)
export { languages }

function langMeta(code: string): LangMeta | undefined {
  return languages.find((l) => l.code === code)
}

export function t(key: string): string {
  const lang = currentLang.value
  const v = messages[lang]?.[key]
  if (v !== undefined) return v
  return messages[FALLBACK_LANG]?.[key] ?? key
}

// 含 HTML 的富文本 key（与原 data-i18n-html 一致），配合 v-html 使用。
export function tHtml(key: string): string {
  return t(key)
}

export function currentTypedPhrases(): string[] {
  return phrasesMap[currentLang.value] ?? phrasesMap[FALLBACK_LANG] ?? []
}

function applyDocMeta(code: string): void {
  const meta = langMeta(code)
  document.documentElement.lang = meta?.htmlLang || code
  document.title = t('title')
  const desc = document.querySelector('meta[name="description"]')
  if (desc) desc.setAttribute('content', t('description'))
}

/** 内部：仅切换语言并更新文档元信息，不写 localStorage。 */
function applyLocale(code: string): void {
  if (!messages[code]) code = DEFAULT_LANG
  currentLang.value = code
  applyDocMeta(code)
}

/** 用户在右上角主动选择语言：切换 + 持久化（标记 manual）。 */
export function selectLocale(code: string): void {
  if (!messages[code]) return
  applyLocale(code)
  try {
    localStorage.setItem(KEY_LANG, code)
    localStorage.setItem(KEY_MANUAL, '1')
    localStorage.setItem(KEY_VERSION, STORAGE_VERSION)
  } catch {
    /* ignore storage errors */
  }
}

function regionLanguage(info: Record<string, unknown> | null): string {
  if (!info) return DEFAULT_LANG
  const country = String(info.country_code || info.country || info.countryCode || '').toUpperCase()
  const region = String(info.region || info.region_name || info.regionName || info.state || '').toLowerCase()
  if (country === 'HK') return 'yue'
  if (country === 'MO' || country === 'TW') return 'zh-Hant'
  if (country === 'CN') {
    if (region.includes('guangdong') || region.includes('广东') || region.includes('廣東')) return 'yue'
    return 'zh'
  }
  if (country === 'RU') return 'ru'
  if (country === 'KR' || country === 'KP') return 'ko'
  return DEFAULT_LANG
}

async function fetchRegion(): Promise<Record<string, unknown> | null> {
  const endpoints = ['https://ipapi.co/json/', 'https://ipwho.is/']
  for (const url of endpoints) {
    try {
      const controller = new AbortController()
      const timer = setTimeout(() => controller.abort(), 1400)
      const res = await fetch(url, { cache: 'no-store', signal: controller.signal })
      clearTimeout(timer)
      if (res.ok) return await res.json()
    } catch {
      /* try next endpoint */
    }
  }
  return null
}

/** 应用启动时初始化语言。 */
export function initI18n(): void {
  let urlLang = ''
  try {
    urlLang = new URLSearchParams(window.location.search).get('lang') || ''
  } catch {
    urlLang = ''
  }
  if (urlLang && messages[urlLang]) {
    applyLocale(urlLang)
    return
  }
  try {
    const manual = localStorage.getItem(KEY_MANUAL) === '1'
    const versionOk = localStorage.getItem(KEY_VERSION) === STORAGE_VERSION
    const saved = localStorage.getItem(KEY_LANG) || ''
    if (manual && versionOk && saved && messages[saved]) {
      applyLocale(saved)
      return
    }
  } catch {
    /* ignore */
  }
  // 先渲染默认语言避免首屏闪烁，再异步按地理位置纠正
  applyLocale(DEFAULT_LANG)
  fetchRegion().then((info) => {
    const lang = regionLanguage(info)
    if (messages[lang]) applyLocale(lang)
  })
}
