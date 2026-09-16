"""支付端 API 请求 Pydantic 模型(从 payments.py God File 抽出的数据模型层)。"""
from typing import Any

from pydantic import BaseModel, Field

from app.services.billing.enums import CHARGE_TYPE_MANUAL_PURCHASE, SETTLEMENT_FULL_PRICE


class SubscriptionPaymentRequest(BaseModel):
    payment_event_id: str
    user_email: str
    plan_code: str
    billing_cycle: str = "monthly"
    provider: str = "unknown"
    settlement_mode: str = SETTLEMENT_FULL_PRICE
    paid_amount_cents: int | None = None
    payment_order_id: str = ""
    provider_payment_id: str = ""
    payment_channel: str = ""
    auto_renew: bool = False
    charge_type: str = CHARGE_TYPE_MANUAL_PURCHASE
    raw_event: dict[str, Any] = Field(default_factory=dict)


class CreditTopupPaymentRequest(BaseModel):
    payment_event_id: str
    user_email: str
    amount: int
    provider: str = "unknown"
    raw_event: dict[str, Any] = Field(default_factory=dict)


class CreateSubscriptionCheckoutRequest(BaseModel):
    provider: str = "lobster_pay"
    product_code: str = ""
    payment_method: str = ""
    currency: str = ""
    user_email: str
    plan_code: str
    billing_cycle: str = "monthly"
    settlement_mode: str = SETTLEMENT_FULL_PRICE
    auto_renew: bool = True
    discount_code: str = ""


class CreateCreditTopupCheckoutRequest(BaseModel):
    provider: str = "lobster_pay"
    product_code: str = "credits_topup"
    payment_method: str = ""
    currency: str = ""
    user_email: str
    discount_code: str = ""


class SubscriptionQuoteRequest(BaseModel):
    user_email: str
    payment_method: str = ""
    currency: str = ""


class SubscriptionPortalRequest(BaseModel):
    user_email: str


class CancelRenewalRequest(BaseModel):
    user_email: str


class BillingConfigRequest(BaseModel):
    products: list[dict[str, Any]] = Field(default_factory=list)
    currencies: list[dict[str, Any]] = Field(default_factory=list)
    payment_methods: list[dict[str, Any]] = Field(default_factory=list)
    channels: list[dict[str, Any]] = Field(default_factory=list)
    channel_prices: list[dict[str, Any]] = Field(default_factory=list)
    exchange_rate_provider: dict[str, Any] = Field(default_factory=dict)


class ManualRefundRequest(BaseModel):
    refund_mode: str = "full"
    amount_cents: int | None = None
    reason_code: str = "admin_adjustment"
    reason: str = ""
    reason_note: str = ""
    # 退款默认保留权益(套餐重构决策);需要撤销时管理端显式勾选 revoke_entitlement=True。
    revoke_entitlement: bool = False
