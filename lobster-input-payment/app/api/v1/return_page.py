"""支付中转页(presentation layer)。

从 payments.py God File 抽出的 HTML 支付结果中转页与其状态查询接口:
支付平台跳回后展示订单状态、轮询权益写入结果。纯展示/查询逻辑,
依赖 payments 核心的 ``_normalize_provider`` + 计费配置 + 主库,不参与支付履约写入。
"""
import json
from html import escape
from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from app.core.database import get_main_db
from app.services.billing.config import default_price, load_billing_config, products_by_code
from app.api.v1.payments import _normalize_provider

# 与 payments.router 同前缀/标签,保证中转页路由路径不变(/payments/return-status、/payments/{provider}/return)。
router = APIRouter(prefix="/payments", tags=["payments"])


def _mask_email(email: str) -> str:
    local, sep, domain = str(email or "").partition("@")
    if not sep:
        return email or "-"
    if len(local) <= 2:
        return f"{local[:1]}***@{domain}"
    return f"{local[:2]}***{local[-1:]}@{domain}"


def _format_money(cents: int | None, currency: str) -> str:
    if cents is None:
        return "-"
    amount = max(0, int(cents or 0)) / 100
    currency = (currency or "USD").upper()
    symbols = {"USD": "$", "CNY": "¥", "RMB": "¥", "EUR": "€", "GBP": "£", "JPY": "¥"}
    symbol = symbols.get(currency)
    if symbol:
        return f"{symbol}{amount:,.2f}"
    return f"{amount:,.2f} {currency}"


async def _return_checkout_by_id(db, request_id: str = "", checkout_id: str = "") -> dict | None:
    query = {"$or": []}
    if request_id:
        query["$or"].append({"request_id": request_id})
    if checkout_id:
        query["$or"].append({"checkout_id": checkout_id})
    if not query["$or"]:
        return None
    return await db["payment_checkout_sessions"].find_one(query)


async def _return_status_payload(request_id: str = "", checkout_id: str = "") -> dict[str, Any]:
    db = get_main_db()
    checkout = await _return_checkout_by_id(db, request_id, checkout_id)
    if not checkout:
        return {
            "found": False,
            "status": "processing",
            "title": "支付确认中",
            "subtitle": "我们正在等待支付平台回传结果，请稍后返回客户端查看权益。",
            "status_label": "确认中",
            "kind_label": "支付订单",
            "amount_label": "-",
            "product_name": "Lobster Input",
            "email": "-",
        }
    result = checkout.get("result") or {}
    raw_event = checkout.get("raw_completed_event") or {}
    raw_object = raw_event.get("object") if isinstance(raw_event, dict) else {}
    raw_product = raw_object.get("product") if isinstance(raw_object, dict) else {}
    config = await load_billing_config()
    product_detail = products_by_code(config).get(checkout.get("product_code") or "") or {}
    price_detail = default_price(config, checkout.get("product_code") or "", checkout.get("currency") or "") or {}
    price_cents = (
        result.get("paid_amount_cents")
        if result.get("paid_amount_cents") is not None
        else result.get("price_cents")
    )
    if price_cents is None and isinstance(raw_product, dict):
        price_cents = raw_product.get("price")
    if price_cents is None:
        price_cents = price_detail.get("amount_cents")
    currency = (
        (raw_product or {}).get("currency")
        or price_detail.get("currency")
        or "USD"
    )
    kind = checkout.get("kind") or ""
    plan_code = checkout.get("plan_code") or ""
    kind_label = "积分加购" if kind == "credits_topup" else "套餐订阅"
    product_name = product_detail.get("name") or (f"{plan_code} 套餐" if plan_code else "Lobster Input")
    if kind == "credits_topup" and checkout.get("amount"):
        product_name = f"{int(checkout.get('amount') or 0):,} 积分加购"
    completed = checkout.get("status") == "completed"
    return {
        "found": True,
        "status": "completed" if completed else "processing",
        "title": "支付已完成" if completed else "支付确认中",
        "subtitle": "权益已经写入账户，请返回 Lobster Input 客户端刷新查看。" if completed else "支付平台已跳回，正在确认订单并写入权益。",
        "status_label": "已生效" if completed else "确认中",
        "kind_label": kind_label,
        "amount_label": _format_money(int(price_cents), currency) if price_cents is not None else "-",
        "product_name": product_name,
        "email": _mask_email(checkout.get("user_email") or ""),
        "provider": checkout.get("provider") or "",
        "request_id": checkout.get("request_id") or "",
        "checkout_id": checkout.get("checkout_id") or "",
    }


def _payment_return_html(provider: str, payload: dict[str, Any], request_id: str, checkout_id: str) -> str:
    initial_json = json.dumps(payload, ensure_ascii=False).replace("</", "<\\/")
    request_json = json.dumps(request_id, ensure_ascii=False)
    checkout_json = json.dumps(checkout_id, ensure_ascii=False)
    provider_name = escape(provider.title())
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Lobster Input 支付结果</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #0f1117;
      --panel: #181b23;
      --panel-2: #202634;
      --text: #f7f7f4;
      --muted: #9ca3af;
      --line: rgba(255,255,255,.12);
      --accent: #ff6a3d;
      --green: #39d98a;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at 20% 8%, rgba(255,106,61,.18), transparent 32%),
        radial-gradient(circle at 84% 14%, rgba(57,217,138,.13), transparent 28%),
        var(--bg);
      color: var(--text);
      display: grid;
      place-items: center;
      padding: 28px;
    }}
    .shell {{
      width: min(760px, 100%);
      border: 1px solid var(--line);
      background: linear-gradient(180deg, rgba(255,255,255,.055), rgba(255,255,255,.025));
      border-radius: 22px;
      box-shadow: 0 24px 80px rgba(0,0,0,.45);
      overflow: hidden;
    }}
    .hero {{ padding: 34px 34px 28px; background: rgba(24,27,35,.86); }}
    .brand {{ color: var(--muted); font-size: 13px; letter-spacing: .08em; text-transform: uppercase; }}
    h1 {{ margin: 14px 0 8px; font-size: clamp(30px, 5vw, 46px); line-height: 1.06; letter-spacing: 0; }}
    .subtitle {{ margin: 0; color: var(--muted); font-size: 16px; line-height: 1.7; }}
    .status {{
      display: inline-flex;
      align-items: center;
      gap: 8px;
      margin-top: 22px;
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(57,217,138,.12);
      color: var(--green);
      border: 1px solid rgba(57,217,138,.28);
      font-weight: 700;
      font-size: 13px;
    }}
    .dot {{ width: 8px; height: 8px; border-radius: 50%; background: currentColor; box-shadow: 0 0 18px currentColor; }}
    .details {{ display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1px; background: var(--line); }}
    .item {{ background: rgba(32,38,52,.86); padding: 20px 24px; min-height: 88px; }}
    .label {{ color: var(--muted); font-size: 12px; margin-bottom: 8px; }}
    .value {{ font-size: 18px; font-weight: 750; overflow-wrap: anywhere; }}
    .amount {{ color: #fff; font-size: 28px; }}
    .footer {{ padding: 20px 34px 28px; color: var(--muted); font-size: 13px; line-height: 1.7; background: rgba(15,17,23,.92); }}
    .spinner {{
      display: inline-block;
      width: 14px;
      height: 14px;
      border: 2px solid rgba(255,255,255,.22);
      border-top-color: var(--accent);
      border-radius: 50%;
      animation: spin .9s linear infinite;
      vertical-align: -2px;
      margin-right: 8px;
    }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
    @media (max-width: 640px) {{
      body {{ padding: 16px; }}
      .hero {{ padding: 26px 22px 22px; }}
      .details {{ grid-template-columns: 1fr; }}
      .footer {{ padding: 18px 22px 24px; }}
    }}
  </style>
</head>
<body>
  <main class="shell">
    <section class="hero">
      <div class="brand">Lobster Input · {provider_name}</div>
      <h1 id="title"></h1>
      <p class="subtitle" id="subtitle"></p>
      <div class="status"><span class="dot"></span><span id="status-label"></span></div>
    </section>
    <section class="details">
      <div class="item"><div class="label">支付金额</div><div class="value amount" id="amount"></div></div>
      <div class="item"><div class="label">购买项目</div><div class="value" id="product"></div></div>
      <div class="item"><div class="label">订单类型</div><div class="value" id="kind"></div></div>
      <div class="item"><div class="label">账户</div><div class="value" id="email"></div></div>
    </section>
    <section class="footer" id="footer"></section>
  </main>
  <script>
    const requestId = {request_json};
    const checkoutId = {checkout_json};
    let state = {initial_json};
    function text(id, value) {{ document.getElementById(id).textContent = value || "-"; }}
    function render(data) {{
      state = data || state;
      text("title", state.title);
      text("subtitle", state.subtitle);
      text("status-label", state.status_label);
      text("amount", state.amount_label);
      text("product", state.product_name);
      text("kind", state.kind_label);
      text("email", state.email);
      const footer = document.getElementById("footer");
      footer.innerHTML = state.status === "completed"
        ? "可以关闭此页面并返回 Lobster Input 客户端。客户端刷新账户信息后会显示最新套餐或加购积分。"
        : '<span class="spinner"></span>正在同步支付结果，页面会自动更新；如果长时间未变化，请返回客户端稍后刷新。';
    }}
    async function poll() {{
      if ((!requestId && !checkoutId) || state.status === "completed") return;
      try {{
        const url = new URL("../return-status", window.location.href);
        if (requestId) url.searchParams.set("request_id", requestId);
        if (checkoutId) url.searchParams.set("checkout_id", checkoutId);
        const response = await fetch(url.toString(), {{cache: "no-store"}});
        if (response.ok) render(await response.json());
      }} catch (_) {{}}
    }}
    render(state);
    if ((requestId || checkoutId) && state.status !== "completed") {{
      setInterval(poll, 1800);
      setTimeout(poll, 500);
    }}
  </script>
</body>
</html>"""


@router.get("/return-status")
async def payment_return_status(request_id: str = "", checkout_id: str = ""):
    return await _return_status_payload(request_id.strip(), checkout_id.strip())


@router.get("/{provider}/return", response_class=HTMLResponse)
async def payment_provider_return(provider: str, request: Request):
    provider = _normalize_provider(provider)
    request_id = str(request.query_params.get("request_id") or request.query_params.get("out_trade_no") or "").strip()
    checkout_id = str(request.query_params.get("checkout_id") or request.query_params.get("checkoutId") or "").strip()
    payload = await _return_status_payload(request_id, checkout_id)
    return _payment_return_html(provider, payload, request_id, checkout_id)
