// 管理端通用「英文枚举 → 中文」字典与取值助手。
// 取不到时回退原始 key,保证未知/新增枚举不会变成空白。

export const BONUS_SOURCE_LABELS: Record<string, string> = {
  registration_reward: '注册奖励',
  invite_reward: '邀请奖励',
}

export const PAYMENT_ORDER_STATUS_LABELS: Record<string, string> = {
  created: '已创建',
  pending_payment: '待支付',
  paid: '已支付',
  refunding: '退款中',
  partially_refunded: '部分退款',
  refunded: '已退款',
  failed: '支付失败',
  closed: '已关闭',
  cancelled: '已取消',
  expired: '已过期',
}

export const REFUND_STATUS_LABELS: Record<string, string> = {
  pending: '待处理',
  processing: '处理中',
  refunding: '退款中',
  partially_refunded: '部分退款',
  refunded: '已退款',
  failed: '退款失败',
  closed: '已关闭',
}

export function zhLabel(map: Record<string, string>, key: unknown): string {
  if (key == null || key === '') return '-'
  const k = String(key)
  return map[k] || k
}
