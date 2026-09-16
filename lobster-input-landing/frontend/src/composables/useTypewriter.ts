/** Hero 转写框打字机（逐字移植自原 index.html 内联脚本），切换语言时重置到新 locale 短语。 */
import { ref, watch, onMounted, onBeforeUnmount } from 'vue'
import { currentLang, currentTypedPhrases } from '@/i18n'

const FALLBACK = ['把刚刚那段会议纪要润色成更正式的语气']

export function useTypewriter() {
  const text = ref('')
  let pi = 0
  let ci = 0
  let deleting = false
  let timer: ReturnType<typeof setTimeout> | null = null

  function phrases(): string[] {
    const list = currentTypedPhrases()
    return list.length ? list : FALLBACK
  }

  function tick(): void {
    const list = phrases()
    if (pi >= list.length) pi = 0
    const p = list[pi]
    if (!deleting) {
      ci++
      text.value = p.slice(0, ci)
      if (ci >= p.length) {
        deleting = true
        timer = setTimeout(tick, 2200)
        return
      }
    } else {
      ci--
      text.value = p.slice(0, ci)
      if (ci <= 0) {
        deleting = false
        pi = (pi + 1) % list.length
      }
    }
    timer = setTimeout(tick, deleting ? 18 : 50 + Math.random() * 40)
  }

  function reset(): void {
    pi = 0
    ci = 0
    deleting = false
    text.value = ''
  }

  watch(currentLang, () => reset())

  onMounted(() => {
    timer = setTimeout(tick, 1400)
  })
  onBeforeUnmount(() => {
    if (timer) clearTimeout(timer)
  })

  return { text }
}
