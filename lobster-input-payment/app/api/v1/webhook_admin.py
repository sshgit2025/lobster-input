"""Webhook 事件浏览与重放的管理端内部接口(计费域重构阶段 0)。

独立成模块以避免 payments <-> apple_iap 的循环导入。重放对 registry 已注册的渠道(creem/zpay/…)
统一走 adapter.normalize_webhook_event + payments.dispatch_webhook_event(与实时入口同一套领域分发,
不再各渠道各写一遍);apple 走 apple_iap 自身的重放。鉴权用 verify_callback_key 内部签名。
"""
import json
from typing import Any

from fastapi import APIRouter, HTTPException, Security

from app.api.v1 import apple_iap as apple_iap_api
from app.api.v1 import payments as payments_api
from app.api.v1.payments import verify_callback_key
from app.core.database import get_main_db
from app.services.webhook import ingest as webhook_ingest
from app.services.payment_providers import is_registered_provider

router = APIRouter(prefix="/payments/admin/webhook-events", tags=["payments-webhook-admin"])

RAW_SUMMARY_MAX_LEN = 300


def _raw_summary(raw: Any) -> str:
    try:
        text = json.dumps(raw, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        text = str(raw)
    if len(text) <= RAW_SUMMARY_MAX_LEN:
        return text
    return text[:RAW_SUMMARY_MAX_LEN] + "..."


def _serialize_event(doc: dict[str, Any], include_raw: bool) -> dict[str, Any]:
    row = dict(doc)
    if row.get("_id") is not None:
        row["_id"] = str(row["_id"])
    if not include_raw:
        raw = row.pop("raw", None)
        row["raw_summary"] = _raw_summary(raw)
    return row


@router.get("")
async def admin_webhook_events(
    provider: str = "",
    status: str = "",
    page: int = 1,
    page_size: int = 20,
    _: None = Security(verify_callback_key),
):
    """分页浏览 webhook 事件(raw 字段仅返回截断摘要,完整 raw 走详情接口)。"""
    db = get_main_db()
    query: dict[str, Any] = {}
    if provider:
        query["provider"] = provider.strip().lower()
    if status:
        query["status"] = status.strip().lower()
    page = max(1, int(page or 1))
    page_size = min(100, max(1, int(page_size or 20)))
    collection = db[webhook_ingest.WEBHOOK_EVENTS_COLLECTION]
    total = await collection.count_documents(query)
    rows = await collection.find(query).sort("received_at", -1).skip((page - 1) * page_size).limit(page_size).to_list(length=page_size)
    return {
        "items": [_serialize_event(row, include_raw=False) for row in rows],
        "total": total,
        "page": page,
        "page_size": page_size,
    }


@router.get("/{provider}/{event_id}")
async def admin_webhook_event_detail(provider: str, event_id: str, _: None = Security(verify_callback_key)):
    db = get_main_db()
    doc = await db[webhook_ingest.WEBHOOK_EVENTS_COLLECTION].find_one({
        "provider": provider.strip().lower(),
        "event_id": event_id,
    })
    if not doc:
        raise HTTPException(status_code=404, detail="webhook 事件不存在")
    return {"event": _serialize_event(doc, include_raw=True)}


async def _replay_via_adapter(db, provider: str, raw: dict[str, Any]) -> dict[str, Any]:
    """已注册渠道的统一重放:还原 body → adapter.normalize_webhook_event → dispatch_webhook_event。"""
    accounts = await payments_api._webhook_provider_accounts(provider)
    if not accounts:
        raise HTTPException(status_code=400, detail=f"支付 provider {provider} 未启用,无法重放")
    profile, adapter = await payments_api._payment_context_for_account(accounts[0])
    raw_body = adapter.rebuild_webhook_body(raw)
    event = await adapter.normalize_webhook_event(db, raw_body, None)
    return await payments_api.dispatch_webhook_event(db, profile, adapter, event)


@router.post("/{provider}/{event_id}/replay")
async def admin_webhook_event_replay(provider: str, event_id: str, _: None = Security(verify_callback_key)):
    """重放 status=failed 的事件:与实时入口共用领域分发,成功后 mark_done。"""
    db = get_main_db()
    provider = provider.strip().lower()
    doc = await db[webhook_ingest.WEBHOOK_EVENTS_COLLECTION].find_one({"provider": provider, "event_id": event_id})
    if not doc:
        raise HTTPException(status_code=404, detail="webhook 事件不存在")
    if doc.get("status") != webhook_ingest.STATUS_FAILED:
        raise HTTPException(status_code=400, detail="仅 status=failed 的事件允许重放")
    if not doc.get("signature_ok"):
        raise HTTPException(status_code=400, detail="验签失败的事件不允许重放")
    if provider != "apple" and not is_registered_provider(provider):
        raise HTTPException(status_code=400, detail=f"暂不支持重放 provider={provider} 的事件,请人工核对后处理")
    raw = doc.get("raw") or {}
    try:
        if provider == "apple":
            result = await apple_iap_api.replay_apple_notification_event(db, raw)
        else:
            result = await _replay_via_adapter(db, provider, raw)
    except Exception as exc:
        error = webhook_ingest.error_text(exc)
        await webhook_ingest.mark_failed(db, provider, event_id, error)
        raise HTTPException(status_code=502, detail={"message": "重放失败,事件仍为 failed", "error": error})
    await webhook_ingest.mark_done(db, provider, event_id, result)
    return {"message": "重放成功", "provider": provider, "event_id": event_id, "result": result}
