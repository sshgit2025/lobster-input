export function fmtTime(ts?: string | null): string {
  if (!ts) return '-'
  return new Date(ts).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })
}

export function fmtNum(n?: number | null): string {
  if (n === undefined || n === null) return '0'
  return Number(n).toLocaleString()
}
