export const BASE_URL = (import.meta.env.BASE_URL || '/').replace(/\/+$/, '')

export const CATEGORY_LABELS: Record<string, string> = {
  asr: 'ASR 语音识别',
  asr_realtime: '实时 ASR',
  llm_chat: 'LLM 文本对话',
  web_search: '联网搜索',
  embedding: '向量 Embedding',
  tts: '音频合成',
}

export const STATUS_LABELS: Record<string, string> = {
  active: '活跃',
  cooldown: '冷却中',
  exhausted: '耗尽',
  disabled: '已禁用',
  error: '异常',
  expired: '已过期',
}
