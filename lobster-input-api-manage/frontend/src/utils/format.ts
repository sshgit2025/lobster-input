export function fmtNum(n?: number | null) {
  if (n === undefined || n === null) return '0'
  return Number(n).toLocaleString()
}

export function fmtTime(t?: string) {
  if (!t) return '-'
  return new Date(t).toLocaleString('zh-CN', { hour12: false, timeZone: 'Asia/Shanghai' })
}
