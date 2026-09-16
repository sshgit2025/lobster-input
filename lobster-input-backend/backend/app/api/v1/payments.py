"""支付订阅入口。

客户端入口只做登录态、套餐可购校验和轻量签名转发；真实支付下单和回调写入由 payment 服务负责。
"""
import hmac
import ipaddress
import json
import secrets
import time
from datetime import datetime, timezone
from hashlib import sha256
from html import escape
from urllib.parse import quote, urljoin

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request, Header
from fastapi.responses import HTMLResponse

from app.core.content_i18n import localized_text, normalize_language
from pydantic import BaseModel

from app.core.config import settings
from app.core.database import get_db
from app.core.request_utils import client_ip
from app.middleware.auth import verify_user
from app.repositories.plan_repository import PlanRepository
from app.repositories.user_repository import UserRepository
from app.services.billing.payment_runtime_config import load_payment_runtime_config
from app.services.billing.plan_policy import PlanPolicy

router = APIRouter(prefix="/payments", tags=["Payments"])
# 客户端订阅自助管理入口(/api/v1/subscription/*),与支付下单入口分开挂载
subscription_router = APIRouter(prefix="/subscription", tags=["Subscription"])
CHECKOUT_INTENT_EXPIRE_SECONDS = 15 * 60
MAINLAND_COUNTRY_CODES = {"CN"}
MAINLAND_PAYMENT_METHODS = {"alipay", "wechat"}
OVERSEAS_PAYMENT_METHODS = {"card"}
LANGUAGE_STORAGE_VERSION = "20260519-beta-v5"
LANGUAGES = [
    {"code": "zh", "label": "简体中文", "html_lang": "zh-CN"},
    {"code": "zh-Hant", "label": "繁體中文", "html_lang": "zh-Hant"},
    {"code": "yue", "label": "粵語（廣東省版）", "html_lang": "yue-Hant"},
    {"code": "en", "label": "English", "html_lang": "en"},
    {"code": "ru", "label": "Русский", "html_lang": "ru-RU"},
    {"code": "ko", "label": "한국어", "html_lang": "ko-KR"},
]
LANGUAGE_CODES = {item["code"] for item in LANGUAGES}
CHECKOUT_I18N = {
    "zh": {
        "upgrade_note": "补差价升级：原价 {list}，已抵扣当前套餐未使用部分 {credit}。",
        "title": "确认支付",
        "page_title": "确认支付 - 龙虾输入法",
        "language_aria": "切换语言",
        "hint": "请选择支付方式。确认后会进入对应支付平台托管页。",
        "empty": "当前地区暂无可用支付方式，请联系管理员配置支付渠道。",
        "footer": "支付完成后请回到客户端刷新订阅状态。权益发放以支付平台回调为准。",
        "pay_failed": "支付创建失败",
        "missing": "支付链接不存在",
        "expired": "支付链接已过期，请回到客户端重新发起",
        "redirect_title": "正在跳转",
        "redirect_body": "正在跳转到支付平台...",
        "product_fallback": "订阅",
        "order_fallback": "支付单",
    },
    "zh-Hant": {
        "upgrade_note": "補差價升級：原價 {list}，已抵扣目前套餐未使用部分 {credit}。",
        "title": "確認付款",
        "page_title": "確認付款 - 龍蝦輸入法",
        "language_aria": "切換語言",
        "hint": "請選擇付款方式。確認後會進入對應付款平台託管頁。",
        "empty": "目前地區暫無可用付款方式，請聯絡管理員配置付款渠道。",
        "footer": "付款完成後請回到客戶端重新整理訂閱狀態。權益發放以付款平台回調為準。",
        "pay_failed": "付款建立失敗",
        "missing": "付款連結不存在",
        "expired": "付款連結已過期，請回到客戶端重新發起",
        "redirect_title": "正在跳轉",
        "redirect_body": "正在跳轉到付款平台...",
        "product_fallback": "訂閱",
        "order_fallback": "付款單",
    },
    "yue": {
        "upgrade_note": "補差價升級：原價 {list}，已扣減而家套餐未用嘅部分 {credit}。",
        "title": "確認付款",
        "page_title": "確認付款 - 龍蝦輸入法",
        "language_aria": "切換語言",
        "hint": "請揀付款方式。確認之後會入到相應付款平台頁面。",
        "empty": "你而家所在地區暫時冇可用付款方式，請聯絡管理員配置付款渠道。",
        "footer": "付款完成後請返去客戶端刷新訂閱狀態。權益發放以付款平台回調為準。",
        "pay_failed": "建立付款失敗",
        "missing": "付款連結不存在",
        "expired": "付款連結已過期，請返去客戶端重新發起",
        "redirect_title": "正在跳轉",
        "redirect_body": "正在跳轉到付款平台...",
        "product_fallback": "訂閱",
        "order_fallback": "付款單",
    },
    "en": {
        "upgrade_note": "Prorated upgrade: list price {list}, minus {credit} credit for the unused part of your current plan.",
        "title": "Confirm payment",
        "page_title": "Confirm payment - Lobster Input",
        "language_aria": "Change language",
        "hint": "Choose a payment method. You will continue on the payment provider's hosted page.",
        "empty": "No payment method is available for your region. Please contact support.",
        "footer": "After payment, return to the app and refresh your subscription status. Benefits are applied after provider confirmation.",
        "pay_failed": "Could not create payment",
        "missing": "Payment link not found",
        "expired": "This payment link has expired. Please return to the app and start again.",
        "redirect_title": "Redirecting",
        "redirect_body": "Redirecting to the payment provider...",
        "product_fallback": "Subscription",
        "order_fallback": "Payment order",
    },
    "ru": {
        "upgrade_note": "Апгрейд с перерасчетом: полная цена {list}, вычтено {credit} за неиспользованную часть текущего тарифа.",
        "title": "Подтвердите оплату",
        "page_title": "Подтвердите оплату - Lobster Input",
        "language_aria": "Сменить язык",
        "hint": "Выберите способ оплаты. Затем вы перейдете на защищенную страницу платежного провайдера.",
        "empty": "Для вашего региона нет доступных способов оплаты. Обратитесь в поддержку.",
        "footer": "После оплаты вернитесь в приложение и обновите статус подписки. Доступ будет выдан после подтверждения платежа.",
        "pay_failed": "Не удалось создать платеж",
        "missing": "Платежная ссылка не найдена",
        "expired": "Срок действия платежной ссылки истек. Вернитесь в приложение и начните заново.",
        "redirect_title": "Переход",
        "redirect_body": "Переходим к платежному провайдеру...",
        "product_fallback": "Подписка",
        "order_fallback": "Платеж",
    },
    "ko": {
        "upgrade_note": "차액 결제 업그레이드: 정가 {list}에서 현재 요금제의 미사용분 {credit}이 차감되었습니다.",
        "title": "결제 확인",
        "page_title": "결제 확인 - Lobster Input",
        "language_aria": "언어 변경",
        "hint": "결제 수단을 선택하세요. 확인 후 결제 제공사의 안전한 페이지로 이동합니다.",
        "empty": "현재 지역에서 사용할 수 있는 결제 수단이 없습니다. 관리자에게 문의하세요.",
        "footer": "결제 완료 후 앱으로 돌아가 구독 상태를 새로 고치세요. 혜택은 결제 제공사 확인 후 적용됩니다.",
        "pay_failed": "결제를 생성하지 못했습니다",
        "missing": "결제 링크를 찾을 수 없습니다",
        "expired": "결제 링크가 만료되었습니다. 앱으로 돌아가 다시 시작하세요.",
        "redirect_title": "이동 중",
        "redirect_body": "결제 제공사로 이동 중...",
        "product_fallback": "구독",
        "order_fallback": "결제 주문",
    },
}
METHOD_I18N = {
    "card": {
        "zh": ("银行卡", "Visa / Mastercard 等国际卡"),
        "zh-Hant": ("銀行卡", "Visa / Mastercard 等國際卡"),
        "yue": ("銀行卡", "Visa / Mastercard 等國際卡"),
        "en": ("Card", "Visa, Mastercard and other cards"),
        "ru": ("Банковская карта", "Visa, Mastercard и другие карты"),
        "ko": ("카드", "Visa, Mastercard 등"),
    },
    "alipay": {
        "zh": ("支付宝", "使用支付宝完成支付"),
        "zh-Hant": ("支付寶", "使用支付寶完成付款"),
        "yue": ("支付寶", "用支付寶完成付款"),
        "en": ("Alipay", "Pay with Alipay"),
        "ru": ("Alipay", "Оплата через Alipay"),
        "ko": ("Alipay", "Alipay로 결제"),
    },
    "wechat": {
        "zh": ("微信支付", "使用微信支付完成支付"),
        "zh-Hant": ("微信支付", "使用微信支付完成付款"),
        "yue": ("微信支付", "用微信支付完成付款"),
        "en": ("WeChat Pay", "Pay with WeChat Pay"),
        "ru": ("WeChat Pay", "Оплата через WeChat Pay"),
        "ko": ("WeChat Pay", "WeChat Pay로 결제"),
    },
}


class SubscriptionCheckoutRequest(BaseModel):
    plan_code: str
    billing_cycle: str
    auto_renew: bool = False
    provider: str = ""
    product_code: str = ""
    payment_method: str = ""
    currency: str = ""
    settlement_mode: str = "full_price"
    discount_code: str = ""


class CreditTopupCheckoutRequest(BaseModel):
    provider: str = ""
    product_code: str = "credits_topup"
    payment_method: str = ""
    currency: str = ""
    discount_code: str = ""


class AutoRenewRequest(BaseModel):
    auto_renew: bool


class CheckoutIntentConfirmRequest(BaseModel):
    payment_method: str


def _billing_option(plan: dict, billing_cycle: str) -> dict:
    option = (plan.get("billing_options") or {}).get(billing_cycle)
    if not option or option.get("enabled") is False:
        raise HTTPException(status_code=400, detail="该支付方式未启用")
    return option


def _signed_headers(method: str, path: str, query: str, body: bytes, internal_key: str) -> dict[str, str]:
    timestamp = str(int(time.time()))
    payload = b"\n".join([
        method.upper().encode("utf-8"),
        path.encode("utf-8"),
        query.encode("utf-8"),
        timestamp.encode("utf-8"),
        body,
    ])
    signature = hmac.new(internal_key.encode("utf-8"), payload, sha256).hexdigest()
    return {
        "X-API-Key": internal_key,
        "X-Callback-Timestamp": timestamp,
        "X-Callback-Signature": signature,
        "Content-Type": "application/json",
    }


async def _request_payment_service(method: str, path: str, payload: dict | None = None) -> dict:
    runtime_config = await load_payment_runtime_config()
    service_url = runtime_config["service_url"]
    internal_key = runtime_config["callback_internal_key"]
    if not service_url or not internal_key:
        raise HTTPException(status_code=503, detail="支付服务未配置")
    body = b"" if payload is None else json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    headers = _signed_headers(method, path, "", body, internal_key)
    url = urljoin(service_url.rstrip("/") + "/", path.lstrip("/"))
    async with httpx.AsyncClient(timeout=20.0) as client:
        response = await client.request(method, url, content=body, headers=headers)
    if response.status_code >= 400:
        try:
            detail = response.json()
        except Exception:
            detail = response.text
        raise HTTPException(status_code=response.status_code, detail=detail)
    return response.json()


async def _post_payment_service(path: str, payload: dict) -> dict:
    return await _request_payment_service("POST", path, payload)


async def _payment_provider_catalog() -> dict:
    try:
        return await _request_payment_service("GET", "/api/v1/payments/catalog")
    except HTTPException:
        return {}


def _active_payment_provider(provider_catalog: dict) -> str:
    return str(provider_catalog.get("active_provider") or "").strip().lower()


def _resolve_checkout_provider(requested_provider: str, provider_catalog: dict) -> str:
    active_provider = _active_payment_provider(provider_catalog)
    provider = (requested_provider or active_provider).strip().lower()
    if not provider or provider != active_provider:
        raise HTTPException(status_code=400, detail="支付 provider 未启用")
    return provider


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _as_utc(value) -> datetime | None:
    if not value:
        return None
    if isinstance(value, datetime):
        return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)
    return None


def _intent_expired(intent: dict) -> bool:
    expires_at = _as_utc(intent.get("expires_at"))
    return bool(expires_at and expires_at < _now())


def _country_from_headers(request: Request) -> str:
    country = (
        request.query_params.get("country")
        or request.headers.get("CF-IPCountry")
        or request.headers.get("CloudFront-Viewer-Country")
        or request.headers.get("X-Vercel-IP-Country")
        or request.headers.get("X-Appengine-Country")
        or request.headers.get("X-Country-Code")
        or request.headers.get("X-Geo-Country")
        or request.headers.get("X-Client-Country")
        or request.headers.get("X-Real-Country")
        or ""
    )
    return country.strip().upper()


async def _country_from_request(request: Request) -> str:
    country = _country_from_headers(request)
    if country:
        return country
    ip = client_ip(request)
    try:
        parsed_ip = ipaddress.ip_address(ip)
    except ValueError:
        return ""
    if parsed_ip.is_private or parsed_ip.is_loopback or parsed_ip.is_link_local:
        return ""
    try:
        async with httpx.AsyncClient(timeout=1.5) as client:
            response = await client.get(f"http://ip-api.com/json/{ip}", params={"fields": "status,countryCode"})
        if response.status_code != 200:
            return ""
        data = response.json()
    except Exception:
        return ""
    if data.get("status") != "success":
        return ""
    return str(data.get("countryCode") or "").strip().upper()


async def _region_scope_from_request(request: Request) -> str:
    country = await _country_from_request(request)
    if country in MAINLAND_COUNTRY_CODES:
        return "mainland"
    if country:
        return "overseas"
    return "unknown"


def _method_code(method: dict) -> str:
    return str(method.get("code") or "").strip().lower()


def _methods_for_region(methods: list[dict], *, region_scope: str) -> list[dict]:
    """收银台不再按网络环境二选一,全部已配置支付方式同时展示,由用户自行选择。

    region_scope 仅保留用于排序:本地区常用方式排前(大陆:微信/支付宝在前,
    海外:银行卡在前),不做过滤。
    """
    if region_scope == "mainland":
        preferred = MAINLAND_PAYMENT_METHODS
    elif region_scope == "overseas":
        preferred = OVERSEAS_PAYMENT_METHODS
    else:
        return methods
    return sorted(methods, key=lambda m: 0 if _method_code(m) in preferred else 1)


def _normalize_language(raw: str | None) -> str | None:
    value = (raw or "").strip()
    if value in LANGUAGE_CODES:
        return value
    lower = value.lower()
    if lower.startswith("yue") or lower in {"zh-hk", "zh-mo"}:
        return "yue"
    if lower.startswith("zh-hant") or lower in {"zh-tw", "zh-mo"}:
        return "zh-Hant"
    if lower.startswith("zh"):
        return "zh"
    if lower.startswith("ru"):
        return "ru"
    if lower.startswith("ko"):
        return "ko"
    if lower.startswith("en"):
        return "en"
    return None


def _language_from_region(request: Request) -> str | None:
    country = _country_from_headers(request)
    region = (
        request.headers.get("X-Region")
        or request.headers.get("X-Geo-Region")
        or request.headers.get("CF-Region")
        or ""
    ).strip().lower()
    if country == "HK":
        return "yue"
    if country in {"MO", "TW"}:
        return "zh-Hant"
    if country == "CN":
        return "yue" if region in {"guangdong", "gd", "广东", "廣東"} else "zh"
    if country == "RU":
        return "ru"
    if country in {"KR", "KP"}:
        return "ko"
    if country:
        return "en"
    return None


def _language_from_accept_language(request: Request) -> str | None:
    header = request.headers.get("Accept-Language") or ""
    for item in header.split(","):
        lang = _normalize_language(item.split(";")[0])
        if lang:
            return lang
    return None


def _request_language(request: Request) -> str:
    return (
        _normalize_language(request.query_params.get("lang"))
        or _language_from_region(request)
        or _language_from_accept_language(request)
        or "en"
    )


def _t(lang: str, key: str) -> str:
    return CHECKOUT_I18N.get(lang, CHECKOUT_I18N["en"]).get(key) or CHECKOUT_I18N["en"][key]


def _localized_method(method: dict, lang: str) -> tuple[str, str]:
    code = _method_code(method)
    translated = METHOD_I18N.get(code, {}).get(lang) or METHOD_I18N.get(code, {}).get("en")
    if translated:
        return translated
    return str(method.get("name") or method.get("code") or ""), str(method.get("description") or "")


def _localized_error(error: str, lang: str) -> str:
    mapping = {
        "支付链接不存在": "missing",
        "支付链接已过期，请回到客户端重新发起": "expired",
        "支付创建失败": "pay_failed",
    }
    key = mapping.get(error)
    return _t(lang, key) if key else error


async def _checkout_public_base_url(request: Request) -> str:
    runtime_config = await load_payment_runtime_config()
    configured = runtime_config["checkout_public_base_url"]
    if configured:
        return configured
    scheme = (request.headers.get("X-Forwarded-Proto") or request.url.scheme or "https").split(",")[0].strip()
    host = (request.headers.get("X-Forwarded-Host") or request.headers.get("Host") or request.url.netloc).split(",")[0].strip()
    if host.startswith("api."):
        host = f"payment.{host[4:]}"
    prefix = (request.headers.get("X-Forwarded-Prefix") or request.scope.get("root_path") or "").strip().rstrip("/")
    if not prefix and host.endswith("example.com"):
        prefix = "/lobster"
    return f"{scheme}://{host}{prefix}".rstrip("/")


async def _checkout_intent_url(request: Request, intent_id: str) -> str:
    return f"{await _checkout_public_base_url(request)}/api/v1/payments/checkout-intents/{quote(intent_id)}"


async def _checkout_intent_confirm_url(request: Request, intent_id: str) -> str:
    return f"{await _checkout_intent_url(request, intent_id)}/confirm"


def _checkout_page_html(
    intent: dict,
    methods: list[dict],
    *,
    region_scope: str,
    lang: str,
    confirm_url: str = "",
    error: str = "",
) -> str:
    language = next((item for item in LANGUAGES if item["code"] == lang), LANGUAGES[3])
    product_name = escape(str(intent.get("product_name") or intent.get("product_code") or _t(lang, "product_fallback")))
    amount = int(intent.get("price_cents") or 0)
    currency = escape(str(intent.get("currency") or ""))
    price = f"{currency} {amount / 100:.2f}" if amount > 0 else currency
    upgrade_credit = int(intent.get("upgrade_credit_cents") or 0)
    list_price = int(intent.get("list_price_cents") or 0)
    upgrade_note_html = ""
    if amount > 0 and upgrade_credit > 0 and list_price > amount:
        note = (
            _t(lang, "upgrade_note")
            .replace("{list}", f"{currency} {list_price / 100:.2f}")
            .replace("{credit}", f"{currency} {upgrade_credit / 100:.2f}")
        )
        upgrade_note_html = f'<div class="upgrade-note">{escape(note)}</div>'
    language_buttons = "\n".join(
        f'''<button class="language-option{' is-active' if item["code"] == lang else ''}" type="button" role="menuitem" data-lang="{escape(item["code"])}">
              <span>{escape(item["label"])}</span><span class="check">✓</span>
            </button>'''
        for item in LANGUAGES
    )
    method_buttons = "\n".join(
        (lambda label, desc: f'''<button class="method" type="button" data-method="{escape(_method_code(method))}">
              <span>{escape(label)}</span>
              <small>{escape(desc)}</small>
            </button>''')(*_localized_method(method, lang))
        for method in methods
    )
    no_methods = "" if methods else f'<div class="empty">{escape(_t(lang, "empty"))}</div>'
    error_html = f'<div class="error">{escape(_localized_error(error, lang))}</div>' if error else ""
    return f"""<!doctype html>
<html lang="{escape(language["html_lang"])}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{escape(_t(lang, "page_title"))}</title>
  <style>
    :root {{ color-scheme: light; --bg:#f6f7fb; --panel:#fff; --text:#101828; --muted:#667085; --line:#d0d5dd; --primary:#175cd3; --danger:#b42318; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; min-height:100vh; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); display:flex; align-items:center; justify-content:center; padding:20px; }}
    button {{ font-family:inherit; }}
    .shell {{ width:min(720px,100%); }}
    .panel {{ background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:24px 28px 28px; box-shadow:0 18px 50px rgba(16,24,40,.08); }}
    .topline {{ display:flex; align-items:center; justify-content:space-between; gap:16px; margin-bottom:12px; }}
    .brand {{ font-size:14px; color:var(--muted); }}
    .language-menu {{ position:relative; flex-shrink:0; }}
    .language-toggle {{ display:inline-flex; align-items:center; gap:7px; padding:6px 12px; border:1px solid var(--line); border-radius:999px; background:#fff; color:var(--muted); font-size:12.5px; cursor:pointer; white-space:nowrap; }}
    .language-toggle:hover {{ border-color:var(--primary); color:var(--primary); }}
    .language-list {{ position:absolute; right:0; top:calc(100% + 8px); min-width:200px; padding:6px; border:1px solid var(--line); border-radius:8px; background:#fff; box-shadow:0 18px 40px -22px rgba(16,24,40,.45); display:none; z-index:20; flex-direction:column; gap:2px; }}
    .language-menu.is-open .language-list {{ display:flex; }}
    .language-option {{ width:100%; display:flex; align-items:center; justify-content:space-between; gap:14px; border:0; background:transparent; color:var(--muted); padding:9px 12px; border-radius:8px; font-size:13px; text-align:left; cursor:pointer; }}
    .language-option:hover,.language-option.is-active {{ background:#f2f4f7; color:var(--primary); }}
    .language-option .check {{ opacity:0; color:var(--primary); }}
    .language-option.is-active .check {{ opacity:1; }}
    h1 {{ font-size:24px; line-height:1.25; margin:0 0 18px; letter-spacing:0; }}
    .summary {{ display:grid; grid-template-columns:1fr auto; gap:12px; padding:16px; border:1px solid var(--line); border-radius:8px; margin-bottom:18px; }}
    .summary strong {{ font-size:16px; }}
    .summary span,.hint {{ color:var(--muted); font-size:14px; }}
    .upgrade-note {{ grid-column:1/-1; color:var(--muted); font-size:13px; }}
    .methods {{ display:grid; gap:10px; margin-top:14px; }}
    .method {{ width:100%; text-align:left; border:1px solid var(--line); border-radius:8px; background:#fff; padding:14px 16px; cursor:pointer; display:flex; align-items:center; justify-content:space-between; gap:16px; color:var(--text); }}
    .method:hover {{ border-color:var(--primary); box-shadow:0 0 0 3px rgba(23,92,211,.12); }}
    .method span {{ font-size:16px; font-weight:700; }}
    .method small {{ color:var(--muted); text-align:right; }}
    .empty,.error {{ border-radius:8px; padding:14px; font-size:14px; }}
    .empty {{ background:#f2f4f7; color:var(--muted); }}
    .error {{ background:#fef3f2; color:var(--danger); margin-bottom:14px; }}
    .footer {{ margin-top:18px; color:var(--muted); font-size:13px; line-height:1.6; }}
    .loading {{ opacity:.55; pointer-events:none; }}
    @media (max-width:560px) {{
      body {{ align-items:flex-start; padding:12px; }}
      .panel {{ padding:18px; }}
      h1 {{ font-size:21px; }}
      .summary {{ grid-template-columns:1fr; }}
      .method {{ align-items:flex-start; flex-direction:column; }}
      .method small {{ text-align:left; }}
      .language-list {{ right:0; min-width:184px; }}
    }}
  </style>
</head>
<body>
  <main class="shell">
    <section class="panel">
      <div class="topline">
        <div class="brand">Lobster Input</div>
        <div class="language-menu">
          <button class="language-toggle" type="button" aria-haspopup="true" aria-expanded="false" title="{escape(_t(lang, "language_aria"))}" aria-label="{escape(_t(lang, "language_aria"))}">
            <span>🌐</span><span class="language-current">{escape(language["label"])}</span>
          </button>
          <div class="language-list" role="menu" aria-label="Language selector">{language_buttons}</div>
        </div>
      </div>
      <h1>{escape(_t(lang, "title"))}</h1>
      {error_html}
      <div class="summary">
        <div><strong>{product_name}</strong></div>
        <div><strong>{escape(price)}</strong></div>
        {upgrade_note_html}
      </div>
      <div class="hint">{escape(_t(lang, "hint"))}</div>
      <div class="methods" id="methods">{method_buttons}{no_methods}</div>
      <div class="footer">{escape(_t(lang, "footer"))}</div>
    </section>
  </main>
  <script>
    const storageVersion = {json.dumps(LANGUAGE_STORAGE_VERSION)};
    const storageKeys = {{
      lang: "lobster_landing_lang",
      manual: "lobster_landing_lang_manual",
      version: "lobster_landing_lang_version"
    }};
    const supportedLanguages = {json.dumps([item["code"] for item in LANGUAGES], ensure_ascii=False)};
    const currentLang = {json.dumps(lang)};
    const confirmURL = {json.dumps(confirm_url)};
    const params = new URLSearchParams(location.search);
    const queryLang = params.get("lang");
    const savedLang = localStorage.getItem(storageKeys.lang);
    const manual = localStorage.getItem(storageKeys.manual) === "1" && localStorage.getItem(storageKeys.version) === storageVersion;
    if (!queryLang && manual && supportedLanguages.includes(savedLang) && savedLang !== currentLang) {{
      params.set("lang", savedLang);
      location.replace(location.pathname + "?" + params.toString());
    }}
    async function confirmPay(method) {{
      document.body.classList.add("loading");
      try {{
        const resp = await fetch(confirmURL, {{
          method: "POST",
          headers: {{"Content-Type": "application/json"}},
          body: JSON.stringify({{payment_method: method}})
        }});
        const data = await resp.json();
        if (!resp.ok) throw new Error(typeof data.detail === "string" ? data.detail : {json.dumps(_t(lang, "pay_failed"))});
        window.location.href = data.checkout_url;
      }} catch (err) {{
        document.body.classList.remove("loading");
        alert(err.message || {json.dumps(_t(lang, "pay_failed"))});
      }}
    }}
    document.querySelectorAll("[data-method]").forEach(btn => btn.addEventListener("click", () => confirmPay(btn.dataset.method)));
    document.querySelector(".language-toggle")?.addEventListener("click", event => {{
      event.stopPropagation();
      const menu = document.querySelector(".language-menu");
      const open = !menu.classList.contains("is-open");
      menu.classList.toggle("is-open", open);
      document.querySelector(".language-toggle")?.setAttribute("aria-expanded", String(open));
    }});
    document.querySelectorAll(".language-option").forEach(btn => btn.addEventListener("click", () => {{
      const nextLang = btn.dataset.lang;
      localStorage.setItem(storageKeys.lang, nextLang);
      localStorage.setItem(storageKeys.manual, "1");
      localStorage.setItem(storageKeys.version, storageVersion);
      const nextParams = new URLSearchParams(location.search);
      nextParams.set("lang", nextLang);
      location.href = location.pathname + "?" + nextParams.toString();
    }}));
    document.addEventListener("click", event => {{
      if (!event.target.closest(".language-menu")) {{
        document.querySelector(".language-menu")?.classList.remove("is-open");
        document.querySelector(".language-toggle")?.setAttribute("aria-expanded", "false");
      }}
    }});
  </script>
</body>
</html>"""


async def _create_checkout_intent(request: Request, intent: dict) -> dict:
    now = _now()
    intent_id = f"pi_{secrets.token_urlsafe(24)}"
    doc = {
        **intent,
        "intent_id": intent_id,
        "status": "pending",
        "created_at": now,
        "updated_at": now,
        "expires_at": datetime.fromtimestamp(now.timestamp() + CHECKOUT_INTENT_EXPIRE_SECONDS, timezone.utc),
    }
    await get_db()["payment_checkout_intents"].insert_one(doc)
    return {
        "provider": "lobster_pay",
        "request_id": intent_id,
        "order_id": "",
        "checkout_id": intent_id,
        "checkout_url": await _checkout_intent_url(request, intent_id),
        "status": "requires_payment_method",
        "product_code": intent.get("product_code") or "",
        "plan_code": intent.get("plan_code") or "",
        "billing_cycle": intent.get("billing_cycle") or "",
        "payment_method": "",
    }


@router.get("/catalog", summary="获取客户端支付商品列表")
async def payment_catalog(
    payload: dict = Depends(verify_user),
    x_accept_language: str | None = Header(default=None, alias="X-Accept-Language"),
):
    email = payload.get("sub", "")
    if not email:
        raise HTTPException(status_code=401, detail="未登录")
    language = normalize_language(x_accept_language)
    plan_repo = PlanRepository()
    show_subscription_module_enabled = await plan_repo.get_show_subscription_module_enabled()
    user_repo = UserRepository()
    user = await user_repo.find_by_email(email)
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    plans = await plan_repo.get_plan_configs()
    provider_catalog = await _payment_provider_catalog()
    active_provider = _active_payment_provider(provider_catalog)
    enabled_product_keys = set(provider_catalog.get("subscription_product_keys") or [])
    subscription_products = provider_catalog.get("subscription_products") or {}
    active_plan_code = user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or ""
    active_plan = plans.get(active_plan_code) or {}
    active_policy = PlanPolicy.from_config(active_plan, active_plan_code)
    plan_total = int(user.get("plan_credits_total", user.get("credits_total", 0)) or 0)
    plan_used = int(user.get("plan_credits_used", user.get("credits_used", 0)) or 0)
    plan_remaining = max(0, plan_total - plan_used)
    expires_at = user.get("subscription_expires_at") or user.get("plan_expires_at")
    topup_config = provider_catalog.get("credits_topup") or {}
    topup_available = (
        show_subscription_module_enabled
        and bool(topup_config.get("enabled", False))
        and active_policy.paid
        and bool(active_plan.get("paid_topup_enabled", True))
        and bool(expires_at)
        and plan_remaining <= 0
    )
    active_cycle, _active_months = _active_billing_cycle_months(user, active_plan)
    quote_options: dict = {}
    if active_policy.paid and _subscription_active(user):
        try:
            quote_result = await _post_payment_service("/api/v1/payments/quote/subscription-options", {
                "user_email": email,
                "payment_method": "",
                "currency": "",
            })
            quote_options = quote_result.get("options") or {}
        except HTTPException:
            quote_options = {}
    items = []
    for code, plan in sorted(plans.items(), key=lambda row: int((row[1] or {}).get("sort_order", 0) or 0)):
        policy = PlanPolicy.from_config(plan, code)
        if not policy.can_self_checkout_subscription:
            continue
        # 只有 external 套餐进 catalog;internal(仅管理端发放)/system(free/trial)对客户端不可见
        if str(plan.get("sale_type") or "").strip().lower() != "external":
            continue
        billing = []
        for cycle, option in (plan.get("billing_options") or {}).items():
            if option.get("enabled") is False:
                continue
            product_key = f"{code}:{cycle}".lower()
            if enabled_product_keys and product_key not in enabled_product_keys:
                continue
            product_detail = subscription_products.get(product_key) or {}
            if not product_detail:
                continue
            target_months = _cycle_duration_months(option.get("duration_period"), option.get("duration_count"))
            blocked_reason = _checkout_block_reason(user, active_plan, plan, target_months)
            quote = quote_options.get(product_key) or {}
            price_cents = int(product_detail.get("price_cents") or 0)
            payable_cents = price_cents
            settlement_mode = "full_price"
            upgrade_credit_cents = 0
            if not blocked_reason and quote.get("purchasable"):
                settlement_mode, payable_cents, upgrade_credit_cents = _scaled_quote_pricing(
                    quote, price_cents, product_detail.get("currency") or "",
                )
            billing.append({
                "cycle": cycle,
                "product_code": product_detail.get("code") or product_detail.get("product_code") or f"{code}_{cycle}".lower(),
                "price_cents": price_cents,
                "payable_price_cents": payable_cents,
                "settlement_mode": settlement_mode,
                "upgrade_credit_cents": upgrade_credit_cents,
                "purchasable": blocked_reason is None,
                "blocked_reason": blocked_reason,
                "currency": product_detail.get("currency") or "USD",
                "prices": product_detail.get("prices") or [],
                "payment_methods": product_detail.get("payment_methods") or provider_catalog.get("payment_methods") or [],
                "duration_period": option.get("duration_period"),
                "duration_count": int(option.get("duration_count") or 1),
            })
        if billing:
            items.append({
                "type": "subscription",
                "plan_code": code,
                "name": localized_text(plan.get("localized_names"), language, fallback=plan.get("name") or code),
                "credits": int(plan.get("credits") or 0),
                "rank": int(plan.get("rank") or 0),
                "billing_options": billing,
            })
    return {
        "active_provider": active_provider,
        "providers": provider_catalog.get("providers") or [],
        "payment_methods": provider_catalog.get("payment_methods") or [],
        "subscription_module": {"enabled": show_subscription_module_enabled},
        "current_plan": {
            "plan_code": active_plan_code,
            "plan_name": localized_text(active_plan.get("localized_names"), language, fallback=active_plan.get("name") or active_plan_code),
            "billing_cycle": active_cycle,
            "plan_credits_total": plan_total,
            "plan_credits_used": plan_used,
            "plan_credits_remaining": plan_remaining,
            "paid": bool(active_policy.paid),
            "paid_topup_enabled": bool(active_plan.get("paid_topup_enabled", False)),
        },
        "subscriptions": items,
        "credits_topup": {
            "type": "credits_topup",
            "provider": active_provider,
            "product_code": topup_config.get("product_code") or "credits_topup",
            "enabled": bool(topup_config.get("enabled", False)),
            "available": bool(topup_available),
            "amount": topup_config.get("amount"),
            "price_cents": int(topup_config.get("price_cents") or 0),
            "currency": topup_config.get("currency") or "",
            "payment_methods": topup_config.get("payment_methods") or provider_catalog.get("payment_methods") or [],
            "blocked_reason": None if topup_available else _topup_blocked_reason(
                show_subscription_module_enabled,
                active_policy,
                active_plan,
                plan_remaining,
                bool(expires_at),
            ),
        },
        "discount": provider_catalog.get("discount") or {"supported": True, "default_enabled": False},
    }


def _topup_blocked_reason(
    module_enabled: bool,
    active_policy: PlanPolicy,
    active_plan: dict,
    plan_remaining: int,
    has_expires_at: bool,
) -> str:
    if not module_enabled:
        return "subscription_module_disabled"
    if not active_policy.paid:
        return "paid_plan_required"
    if not active_plan.get("paid_topup_enabled", True):
        return "topup_disabled_for_plan"
    if not has_expires_at:
        return "subscription_inactive"
    if plan_remaining > 0:
        return "plan_credits_remaining"
    return "unavailable"


@router.get("/checkout-intents/{intent_id}", response_class=HTMLResponse, name="checkout_intent_page")
async def checkout_intent_page(intent_id: str, request: Request):
    lang = _request_language(request)
    intent = await get_db()["payment_checkout_intents"].find_one({"intent_id": intent_id})
    confirm_url = await _checkout_intent_confirm_url(request, intent_id)
    if not intent:
        return HTMLResponse(
            _checkout_page_html(
                {"product_name": _t(lang, "order_fallback"), "intent_id": intent_id},
                [],
                region_scope="unknown",
                lang=lang,
                confirm_url=confirm_url,
                error="支付链接不存在",
            ),
            status_code=404,
        )
    if _intent_expired(intent):
        return HTMLResponse(
            _checkout_page_html(
                intent,
                [],
                region_scope="unknown",
                lang=lang,
                confirm_url=confirm_url,
                error="支付链接已过期，请回到客户端重新发起",
            ),
            status_code=410,
        )
    if intent.get("status") == "checkout_created" and intent.get("checkout_url"):
        return HTMLResponse(
            f'<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{escape(_t(lang, "redirect_title"))}</title><script>location.href={json.dumps(intent["checkout_url"])};</script>'
            f'<p>{escape(_t(lang, "redirect_body"))}</p>'
        )
    region_scope = await _region_scope_from_request(request)
    allowed_methods = _methods_for_region(intent.get("payment_methods") or [], region_scope=region_scope)
    return HTMLResponse(_checkout_page_html(intent, allowed_methods, region_scope=region_scope, lang=lang, confirm_url=confirm_url))


@router.post("/checkout-intents/{intent_id}/confirm")
async def confirm_checkout_intent(intent_id: str, data: CheckoutIntentConfirmRequest, request: Request):
    db = get_db()
    intent = await db["payment_checkout_intents"].find_one({"intent_id": intent_id})
    if not intent:
        raise HTTPException(status_code=404, detail="支付链接不存在")
    if _intent_expired(intent):
        raise HTTPException(status_code=410, detail="支付链接已过期，请回到客户端重新发起")
    if intent.get("status") == "checkout_created" and intent.get("checkout_url"):
        return {"checkout_url": intent["checkout_url"], "status": "checkout_created"}

    region_scope = await _region_scope_from_request(request)
    allowed_methods = _methods_for_region(intent.get("payment_methods") or [], region_scope=region_scope)
    requested_method = str(data.payment_method or "").strip().lower()
    method = next((item for item in allowed_methods if _method_code(item) == requested_method), None)
    if not method:
        raise HTTPException(status_code=400, detail="该支付方式未配置或不可用")

    if intent.get("kind") == "subscription":
        checkout = await _post_payment_service("/api/v1/payments/checkout/subscription", {
            "provider": intent.get("provider") or "lobster_pay",
            "product_code": intent.get("product_code") or "",
            "payment_method": requested_method,
            "currency": intent.get("currency") or "",
            "user_email": intent.get("user_email") or "",
            "plan_code": intent.get("plan_code") or "",
            "billing_cycle": intent.get("billing_cycle") or "monthly",
            "settlement_mode": intent.get("settlement_mode") or "full_price",
            "auto_renew": bool(intent.get("auto_renew")),
            "discount_code": intent.get("discount_code") or "",
        })
    elif intent.get("kind") == "credits_topup":
        checkout = await _post_payment_service("/api/v1/payments/checkout/credits-topup", {
            "provider": intent.get("provider") or "lobster_pay",
            "product_code": intent.get("product_code") or "credits_topup",
            "payment_method": requested_method,
            "currency": intent.get("currency") or "",
            "user_email": intent.get("user_email") or "",
            "discount_code": intent.get("discount_code") or "",
        })
    else:
        raise HTTPException(status_code=400, detail="支付类型不合法")

    await db["payment_checkout_intents"].update_one(
        {"intent_id": intent_id},
        {"$set": {
            "status": "checkout_created",
            "selected_payment_method": requested_method,
            "checkout_url": checkout.get("checkout_url") or "",
            "payment_checkout": checkout,
            "updated_at": _now(),
        }},
    )
    return checkout


def _subscription_active(user: dict) -> bool:
    expires_at = user.get("subscription_expires_at") or user.get("plan_expires_at")
    if not expires_at:
        return False
    if isinstance(expires_at, str):
        try:
            expires_at = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
        except ValueError:
            return False
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    return expires_at > datetime.now(timezone.utc)


def _cycle_duration_months(period: str | None, count: int | None) -> int:
    count = max(1, int(count or 1))
    return count * 12 if period == "year" else count


def _active_billing_cycle_months(user: dict, current_plan: dict) -> tuple[str, int]:
    active_cycle = str(user.get("subscription_billing_cycle") or "").strip().lower()
    option = (current_plan.get("billing_options") or {}).get(active_cycle) if active_cycle else None
    months = _cycle_duration_months(
        (option or {}).get("duration_period"),
        (option or {}).get("duration_count"),
    )
    return active_cycle, months


BLOCK_REASON_DUPLICATE = "duplicate_purchase"
BLOCK_REASON_LOWER_TIER = "lower_tier"
BLOCK_REASON_CYCLE_DOWNGRADE = "cycle_downgrade"
CHECKOUT_BLOCK_MESSAGES = {
    BLOCK_REASON_DUPLICATE: "当前有效套餐不能重复购买",
    BLOCK_REASON_LOWER_TIER: "当前有效套餐不支持降级购买低等级套餐",
    BLOCK_REASON_CYCLE_DOWNGRADE: "账期不支持缩短：年付等长账期套餐不可改为更短账期，可到期后再调整",
}


def _checkout_block_reason(user: dict, current_plan: dict, target_plan: dict, target_months: int) -> str | None:
    """套餐有效优先级 = (等级 rank, 账期时长)，购买仅允许严格向上变更。

    与支付端 _checkout_block_reason 保持一致：同套餐更长账期为补差价升级放行；
    同套餐同账期/更短账期拒绝；更高等级要求账期不缩短；低等级一律拒绝。
    """
    current_policy = PlanPolicy.from_config(current_plan, current_plan.get("code", ""))
    if not current_policy.paid or not _subscription_active(user):
        return None
    current_rank = int(current_plan.get("rank") or 0)
    target_rank = int(target_plan.get("rank") or 0)
    if target_rank < current_rank:
        return BLOCK_REASON_LOWER_TIER
    _, active_months = _active_billing_cycle_months(user, current_plan)
    if target_rank == current_rank:
        same_plan = (target_plan.get("code") or "") == (current_plan.get("code") or "")
        if same_plan and target_months > active_months:
            return None
        if same_plan and target_months < active_months:
            return BLOCK_REASON_CYCLE_DOWNGRADE
        return BLOCK_REASON_DUPLICATE
    if target_months < active_months:
        return BLOCK_REASON_CYCLE_DOWNGRADE
    return None


def _reject_duplicate_or_downgrade_checkout(user: dict, current_plan: dict, target_plan: dict, target_months: int) -> None:
    reason = _checkout_block_reason(user, current_plan, target_plan, target_months)
    if reason:
        raise HTTPException(status_code=400, detail=CHECKOUT_BLOCK_MESSAGES[reason])


@router.post("/subscription/checkout", summary="创建订阅支付单")
async def create_subscription_checkout(
    data: SubscriptionCheckoutRequest,
    request: Request,
    payload: dict = Depends(verify_user),
):
    email = payload.get("sub", "")
    if not email:
        raise HTTPException(status_code=401, detail="未登录")
    if data.settlement_mode not in {"full_price", "prorated_difference"}:
        raise HTTPException(status_code=400, detail="不支持的结算方式")

    plan_repo = PlanRepository()
    plan = await plan_repo.get_plan_config(data.plan_code)
    policy = PlanPolicy.from_config(plan, data.plan_code)
    if not policy.can_self_checkout_subscription:
        raise HTTPException(status_code=400, detail="该套餐不可由用户支付购买")
    # 健壮性:只有 external 套餐可被客户端购买。sale_type 是权威(不依赖可能被误配的 self_checkout_enabled),
    # 显式拒绝 internal(仅管理端发放)/system(free/trial)被伪造套餐 id 下单。
    if str(plan.get("sale_type") or "").strip().lower() != "external":
        raise HTTPException(status_code=403, detail="该套餐不支持购买")
    option = _billing_option(plan, data.billing_cycle)
    provider_catalog = await _payment_provider_catalog()
    provider = _resolve_checkout_provider(data.provider, provider_catalog)
    product_detail = (provider_catalog.get("subscription_products") or {}).get(f"{data.plan_code}:{data.billing_cycle}".lower()) or {}
    if not product_detail:
        raise HTTPException(status_code=400, detail="该套餐未配置支付平台商品")
    if not await plan_repo.get_show_subscription_module_enabled():
        raise HTTPException(status_code=403, detail="客户端订阅入口已关闭")
    user_repo = UserRepository()
    user = await user_repo.find_by_email(email)
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    current_plan_code = user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or ""
    current_plan = await plan_repo.get_plan_config(current_plan_code)
    target_months = _cycle_duration_months(option.get("duration_period"), option.get("duration_count"))
    _reject_duplicate_or_downgrade_checkout(user, current_plan, plan, target_months)
    # 结算模式与应付金额以支付端报价为准(升级购买为补差价)，报价不可用时回退全价
    quote = await _subscription_option_quote(email, data.plan_code, data.billing_cycle, data.currency)
    display_price_cents = int(product_detail.get("price_cents") or 0)
    display_currency = data.currency or product_detail.get("currency") or ""
    settlement_mode, price_cents, upgrade_credit_cents = _scaled_quote_pricing(
        quote, display_price_cents, display_currency,
    ) if quote else ("full_price", display_price_cents, 0)
    product_code = data.product_code or product_detail.get("code") or product_detail.get("product_code") or f"{data.plan_code}_{data.billing_cycle}".lower()
    return await _create_checkout_intent(request, {
        "kind": "subscription",
        "provider": provider,
        "product_code": product_code,
        "product_name": product_detail.get("name") or plan.get("name") or data.plan_code,
        "price_cents": price_cents,
        "list_price_cents": display_price_cents,
        "upgrade_credit_cents": upgrade_credit_cents,
        "currency": display_currency,
        "payment_methods": product_detail.get("payment_methods") or provider_catalog.get("payment_methods") or [],
        "user_email": email,
        "plan_code": data.plan_code,
        "billing_cycle": data.billing_cycle,
        "settlement_mode": settlement_mode,
        "auto_renew": bool(data.auto_renew),
        "discount_code": data.discount_code,
        "duration_period": option.get("duration_period"),
        "duration_count": int(option.get("duration_count") or 1),
    })


async def _subscription_option_quote(email: str, plan_code: str, billing_cycle: str, currency: str = "") -> dict:
    """向支付端查询该用户购买指定 套餐:账期 的应付金额与结算模式；失败时回退全价。"""
    try:
        quotes = await _post_payment_service("/api/v1/payments/quote/subscription-options", {
            "user_email": email,
            "payment_method": "",
            "currency": currency or "",
        })
    except HTTPException:
        return {}
    option = (quotes.get("options") or {}).get(f"{plan_code}:{billing_cycle}".lower()) or {}
    return option if option.get("purchasable") else {}


def _scaled_quote_pricing(quote: dict, display_price_cents: int, display_currency: str) -> tuple[str, int, int]:
    """把支付端报价换算到目录展示币种，返回 (settlement_mode, payable, credit)。

    报价按实际扣款渠道币种(如 CNY)计算，目录展示价可能是默认币种(如 USD)换算价；
    币种不一致时按 应付/目录价 的比例缩放，保证展示单位一致。实际扣款金额仍以
    支付端 checkout 时的权威计算为准。
    """
    settlement_mode = quote.get("settlement_mode") or "full_price"
    if settlement_mode != "prorated_difference":
        return "full_price", display_price_cents, 0
    quote_list = int(quote.get("list_price_cents") or 0)
    quote_payable = int(quote.get("payable_cents") or 0)
    if quote_list <= 0 or display_price_cents <= 0:
        return "full_price", display_price_cents, 0
    if (quote.get("currency") or "").upper() == (display_currency or "").upper():
        payable = min(quote_payable, display_price_cents)
    else:
        payable = max(1, round(display_price_cents * quote_payable / quote_list))
    return settlement_mode, payable, max(0, display_price_cents - payable)


@router.post("/credits-topup/checkout", summary="创建积分加购支付单")
async def create_credits_topup_checkout(
    data: CreditTopupCheckoutRequest,
    request: Request,
    payload: dict = Depends(verify_user),
):
    email = payload.get("sub", "")
    if not email:
        raise HTTPException(status_code=401, detail="未登录")
    provider_catalog = await _payment_provider_catalog()
    provider = _resolve_checkout_provider(data.provider, provider_catalog)
    plan_repo = PlanRepository()
    if not await plan_repo.get_show_subscription_module_enabled():
        raise HTTPException(status_code=403, detail="客户端订阅入口已关闭")
    topup_config = provider_catalog.get("credits_topup") or {}
    return await _create_checkout_intent(request, {
        "kind": "credits_topup",
        "provider": provider,
        "product_code": data.product_code or topup_config.get("product_code") or "credits_topup",
        "product_name": "积分加购包",
        "price_cents": int(topup_config.get("price_cents") or 0),
        "currency": data.currency or topup_config.get("currency") or "",
        "payment_methods": topup_config.get("payment_methods") or provider_catalog.get("payment_methods") or [],
        "user_email": email,
        "discount_code": data.discount_code,
    })


@router.post("/subscription/manage-portal", summary="获取订阅自助管理页链接(平台托管自动续费渠道)")
async def subscription_manage_portal(payload: dict = Depends(verify_user)):
    """Creem 等平台托管订阅渠道提供自助管理页(取消续费/更新支付方式)。

    zpay(微信/支付宝)无代扣能力,续费为到期手动购买,无管理页,返回 400。
    """
    email = payload.get("sub", "")
    if not email:
        raise HTTPException(status_code=401, detail="未登录")
    return await _post_payment_service("/api/v1/payments/portal/subscription", {"user_email": email})


@router.post("/subscription/auto-renew", summary="更新当前用户自动续费开关")
async def update_subscription_auto_renew(
    data: AutoRenewRequest,
    payload: dict = Depends(verify_user),
):
    email = payload.get("sub", "")
    if not email:
        raise HTTPException(status_code=401, detail="未登录")

    user_repo = UserRepository()
    user = await user_repo.find_by_email(email)
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    plan_code = user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier")
    plan_repo = PlanRepository()
    plan = await plan_repo.get_plan_config(plan_code)
    policy = PlanPolicy.from_config(plan, plan_code)
    if not policy.can_auto_renew and data.auto_renew:
        raise HTTPException(status_code=400, detail="非付费套餐不能开启自动续费")

    # 自动续费能力完全由渠道决定(见 docs/auto-renewal-strategy.md),与 plan_admin.set_auto_renew 同构校验:
    # 开启操作按渠道收敛,避免出现"本地开启但渠道无代扣"的误导状态与到期误续期。关闭操作一律放行。
    if data.auto_renew:
        provider = str(user.get("latest_payment_provider") or "").strip().lower()
        provider_subscription_id = str(user.get("latest_provider_subscription_id") or "").strip()
        currently_on = bool(user.get("subscription_auto_renew", False))
        if provider == "zpay":
            raise HTTPException(status_code=400, detail="当前支付渠道不支持自动续费，请到期后手动续订")
        if provider == "creem" and provider_subscription_id and not currently_on:
            raise HTTPException(status_code=400, detail="Creem 渠道代扣取消后无法程序化恢复，需重新订阅后才能开启自动续费")

    await user_repo.update_subscription(email, {"subscription_auto_renew": bool(data.auto_renew)})
    return {"message": "自动续费状态已更新", "subscription_auto_renew": bool(data.auto_renew)}


@subscription_router.post("/cancel-renewal", summary="取消当前用户订阅自动续费（周期末生效）")
async def cancel_subscription_renewal(payload: dict = Depends(verify_user)):
    """代理支付端取消自动续费：本周期权益保留到 effective_until，之后不再自动扣款。

    - email 一律取当前登录用户，绝不信任客户端传入；
    - 渠道同步细节（channel_sync）属于内部字段，不透传给客户端；
    - status: cancelled（本次取消成功）| already_cancelled（此前已取消，幂等）。
    """
    email = payload.get("sub", "")
    if not email:
        raise HTTPException(status_code=401, detail="未登录")
    result = await _post_payment_service("/api/v1/payments/subscription/cancel-renewal", {"user_email": email})
    return {
        "status": result.get("status") or "",
        "effective_until": result.get("effective_until"),
    }
