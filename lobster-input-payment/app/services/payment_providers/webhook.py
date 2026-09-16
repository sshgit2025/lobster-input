"""支付 webhook 规范化契约。

各渠道 adapter 负责把自己的原生 webhook 事件解析为统一的 `NormalizedWebhookEvent`
(渠道知识集中在 adapter),webhook 入口与领域分发层据此 provider 无关地处理。
新增渠道只需在其 adapter 实现 normalize_webhook_event,入口/分发/重放无需改动。
"""
from dataclasses import dataclass, field
from typing import Any


class WebhookEventKind:
    """规范化后的支付领域事件类型(与具体渠道无关)。"""
    SUBSCRIPTION_PAYMENT = "subscription_payment"   # 订阅履约:首购 / 升级 / 平台托管续费
    TOPUP = "topup"                                 # 积分加购
    SUBSCRIPTION_STATUS = "subscription_status"     # 订阅状态变更:取消/逾期/到期
    IGNORED = "ignored"                             # 无需处理的事件


@dataclass
class NormalizedWebhookEvent:
    """渠道无关的规范化 webhook 事件。

    adapter.normalize_webhook_event 输出本结构;其载荷字段已足够让领域分发层直接调用
    对应的履约业务函数(subscription_callback / credits_topup_callback / 订阅状态处理),
    无需再感知渠道差异。
    """
    kind: str
    event_id: str
    provider: str
    provider_event_type: str = ""
    # 履约载荷(按 kind 二选一填充):可直接构造对应的 *PaymentRequest
    subscription: dict[str, Any] | None = None   # SUBSCRIPTION_PAYMENT:subscription_callback 参数
    topup: dict[str, Any] | None = None          # TOPUP:credits_topup_callback 参数
    status_change: dict[str, Any] | None = None  # SUBSCRIPTION_STATUS:{event_type, object}
    # 后处理上下文(渠道无关):
    checkout: dict[str, Any] | None = None       # 关联的 checkout 会话(adapter 已查),用于收尾标记与清理
    new_subscription_id: str = ""                # 换订阅时取消旧代扣所需的新订阅 id(仅托管代扣渠道)
    # 履约后由分发层统一落库的补充写入(渠道差异由 adapter 决定,分发层不感知渠道):
    #   user_updates:$set 到履约用户 users 文档(如 Creem 订阅回写 latest_provider_subscription_id/customer_id)
    #   callback_event_updates:$set 到 payment_callback_events(如加购/ZPay 回填订单号/流水号/渠道)
    user_updates: dict[str, Any] | None = None
    callback_event_updates: dict[str, Any] | None = None
    result_overrides: dict[str, Any] | None = None  # 合并进履约 result 的补充字段(如 ZPay 加购回填 paid_amount_cents)
    raw: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def ignored(cls, *, event_id: str, provider: str, provider_event_type: str = "",
                raw: dict[str, Any] | None = None) -> "NormalizedWebhookEvent":
        return cls(
            kind=WebhookEventKind.IGNORED, event_id=event_id, provider=provider,
            provider_event_type=provider_event_type, raw=raw or {},
        )
