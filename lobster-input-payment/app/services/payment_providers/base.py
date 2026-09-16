import json
from dataclasses import asdict, dataclass
from typing import Any

from app.services.webhook import ingest as webhook_ingest
from app.services.payment_providers.webhook import NormalizedWebhookEvent


@dataclass(frozen=True)
class PaymentProduct:
    product_id: str
    name: str = ""
    price_cents: int = 0
    currency: str = "USD"
    billing_type: str = ""
    billing_period: str = ""
    status: str = ""

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


# 渠道适配器注册表:子类定义时通过 __init_subclass__ 自动登记(见下),
# 无需在任何中心文件手工维护映射。新增渠道 = 新建一个子类文件即自动接入。
_PROVIDER_REGISTRY: dict[str, type["PaymentProviderAdapter"]] = {}


class PaymentProviderAdapter:
    code = "unknown"
    display_name = "Unknown"

    def __init_subclass__(cls, **kwargs: Any) -> None:
        # 每个渠道子类一经定义即自动注册到 _PROVIDER_REGISTRY,以 code 为键。
        # 这样扩展新渠道只需在本包内新建一个子类文件并设置 code,无需改 registry 或任何现有代码。
        super().__init_subclass__(**kwargs)
        code = str(getattr(cls, "code", "") or "").strip().lower()
        if code and code != "unknown":
            _PROVIDER_REGISTRY[code] = cls

    # ── 渠道能力声明(capability)────────────────────────────────────────
    # 业务层据此分流,避免 `provider == "xxx"` 字面量硬编码。接入新渠道只需在子类
    # 覆盖这些属性 + 实现对应方法,业务逻辑(补差价/续费/portal/退款分流)无需改动。
    supports_recurring = False        # 平台托管代扣/自动续费(如 Creem/Stripe)
    supports_discount_codes = False   # 支持折扣券(升级补差价用)
    supports_customer_portal = False  # 支持自助管理页(取消订阅/换支付方式)
    supports_refund_api = False       # 支持程序化退款 API
    order_mode = "amount_order"       # external_product(外部商品制)| amount_order(动态金额制)

    def __init__(self, config: dict[str, Any]) -> None:
        self.config = dict(config)

    async def products_by_id(self) -> dict[str, PaymentProduct]:
        raise NotImplementedError

    async def create_checkout(
        self,
        *,
        product_id: str,
        request_id: str,
        user_email: str,
        success_url: str,
        notify_url: str = "",
        product_name: str = "",
        amount_cents: int = 0,
        currency: str = "",
        payment_method: str = "",
        discount_code: str = "",
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        raise NotImplementedError

    def verify_webhook_signature(self, raw_body: bytes, signature: str | None) -> None:
        raise NotImplementedError

    async def refund_payment(
        self,
        *,
        payment_order_id: str,
        provider_payment_id: str,
        amount_cents: int,
        currency: str,
        reason: str = "",
        refund_id: str = "",
    ) -> dict[str, Any]:
        raise NotImplementedError

    async def cancel_subscription(self, subscription_id: str, *, mode: str = "immediate", on_execute: str = "") -> dict[str, Any]:
        # 统一签名(与 CreemAdapter 一致):mode=immediate|scheduled;on_execute 供 scheduled 模式使用。
        # 消除此前基类只有 1 参数、子类偷偷加参的里氏替换违约。无代扣渠道不实现。
        raise NotImplementedError

    # ── webhook 规范化契约 ──────────────────────────────────────────────
    # 渠道知识(验签体、签名位置、事件解析)集中于此,webhook 入口/领域分发/重放均 provider 无关。
    webhook_signature_header = ""  # 签名所在请求头名(空=签名不在 header,如从表单 body 取)
    webhook_ack_text: str | None = None  # 成功/重复时的应答:非空以纯文本应答(如 ZPay 要求 "success"),None 则 JSON

    def webhook_verify_body(self, raw_body: bytes, request: Any) -> bytes:
        """返回参与验签的 body。默认用原始 body;表单/query 型渠道(如 ZPay)覆盖为规范化后的查询串。"""
        return raw_body

    def webhook_signature(self, request: Any) -> str | None:
        """从请求中取出验签签名。默认读 webhook_signature_header 指定的头;签名在 body 内的渠道返回 None。"""
        return request.headers.get(self.webhook_signature_header) if self.webhook_signature_header else None

    def webhook_event_id(self, raw_body: bytes, request: Any) -> str:
        """提取用于幂等摄取的事件 ID(不查 DB)。默认取 JSON body 的 id 字段,取不到用 body 摘要合成。"""
        try:
            payload = json.loads(raw_body.decode("utf-8"))
            event_id = str((payload or {}).get("id") or "").strip()
        except (json.JSONDecodeError, UnicodeDecodeError, AttributeError):
            event_id = ""
        return event_id or webhook_ingest.synthetic_event_id(raw_body)

    def webhook_ingest_raw(self, raw_body: bytes, request: Any) -> dict[str, Any]:
        """入摄取台账前的原始事件快照(在 normalize 之前、不查 DB)。默认解析 JSON body。"""
        try:
            parsed = json.loads(raw_body.decode("utf-8"))
            if isinstance(parsed, dict):
                return parsed
        except (json.JSONDecodeError, UnicodeDecodeError):
            pass
        return {"body": raw_body.decode("utf-8", errors="replace")}

    def rebuild_webhook_body(self, raw: dict[str, Any]) -> bytes:
        """从存档的事件 raw 还原验签/解析用的 body(供失败事件重放)。默认 JSON 序列化。"""
        return json.dumps(raw or {}, ensure_ascii=False, default=str).encode("utf-8")

    async def normalize_webhook_event(self, db: Any, raw_body: bytes, request: Any) -> NormalizedWebhookEvent:
        """把本渠道原生 webhook 事件解析为统一的 NormalizedWebhookEvent(可查 db 补全领域数据)。"""
        raise NotImplementedError

    async def product_by_id(self, product_id: str) -> dict[str, Any]:
        if not product_id:
            return {}
        product = (await self.products_by_id()).get(product_id)
        return product.to_dict() if product else {"product_id": product_id}

    async def product_details(self, product_map: dict[str, str]) -> dict[str, dict[str, Any]]:
        products = await self.products_by_id()
        details: dict[str, dict[str, Any]] = {}
        for key, product_id in product_map.items():
            product = products.get(product_id)
            details[key] = product.to_dict() if product else {"product_id": product_id}
        return details
