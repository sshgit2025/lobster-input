"""Webhook 事件幂等摄取管道(计费域重构阶段 0)。

设计见 lobster-input-backend/docs/billing-rearchitecture-design.md 第二/三节:
验签 → 原始事件落库((provider, event_id) 唯一索引)→ 去重 → 处理结果回写。
本模块只维护 webhook_events 台账本身,不承载任何业务处理逻辑。

集合结构:
webhook_events {
    provider, event_id, raw(dict), signature_ok(bool),
    status: received|processing|done|failed,
    error(str|null), received_at, processed_at,
    result(dict, mark_done 时写入),
    UNIQUE(provider, event_id)
}
"""
import json
import logging
from datetime import datetime, timezone
from hashlib import sha256
from typing import Any

from pymongo.errors import DuplicateKeyError

logger = logging.getLogger(__name__)

WEBHOOK_EVENTS_COLLECTION = "webhook_events"

STATUS_RECEIVED = "received"
STATUS_PROCESSING = "processing"
STATUS_DONE = "done"
STATUS_FAILED = "failed"

# 验签失败的记录使用独立键空间,避免占用真实事件 ID 导致后续合法请求被误判为重复
INVALID_SIGNATURE_PREFIX = "invalid_sig:"

ERROR_TEXT_MAX_LEN = 2000


def synthetic_event_id(raw_body: bytes) -> str:
    """provider 未提供事件 ID 时的合成键:原始 body 的 sha256 前 16 位。"""
    return sha256(raw_body or b"").hexdigest()[:16]


def invalid_signature_event_id(event_id: str) -> str:
    return f"{INVALID_SIGNATURE_PREFIX}{event_id}"


def error_text(exc: BaseException) -> str:
    """把处理异常转成可落库的错误描述(兼容 HTTPException.detail 为 dict 的情况)。"""
    detail = getattr(exc, "detail", None)
    if detail is not None:
        if isinstance(detail, (dict, list)):
            try:
                return json.dumps(detail, ensure_ascii=False, default=str)[:ERROR_TEXT_MAX_LEN]
            except (TypeError, ValueError):
                return str(detail)[:ERROR_TEXT_MAX_LEN]
        return str(detail)[:ERROR_TEXT_MAX_LEN]
    return f"{type(exc).__name__}: {exc}"[:ERROR_TEXT_MAX_LEN]


async def ensure_indexes(db) -> None:
    """建 webhook_events 索引,在 app 启动时调用。"""
    await db[WEBHOOK_EVENTS_COLLECTION].create_index([("provider", 1), ("event_id", 1)], unique=True)
    await db[WEBHOOK_EVENTS_COLLECTION].create_index([("provider", 1), ("status", 1), ("received_at", -1)])
    await db[WEBHOOK_EVENTS_COLLECTION].create_index([("status", 1), ("received_at", -1)])
    await db[WEBHOOK_EVENTS_COLLECTION].create_index([("received_at", -1)])


async def ingest(db, provider: str, event_id: str, raw: dict[str, Any], signature_ok: bool) -> str:
    """落一条 webhook 事件记录,返回 "new" | "duplicate"。

    - 首次出现:插入 status=received,返回 "new",调用方执行业务 handler;
    - (provider, event_id) 已存在且非 failed:返回 "duplicate",调用方跳过 handler
      直接返回既有幂等应答;
    - 已存在但 status=failed:provider 的重试必须有机会重新处理(与现有
      "5xx 触发 provider 重试"的语义保持一致,否则失败事件的自动重试会被吞掉),
      原子地重置为 processing 并返回 "new"。
    """
    now = datetime.now(timezone.utc)
    try:
        await db[WEBHOOK_EVENTS_COLLECTION].insert_one({
            "provider": provider,
            "event_id": event_id,
            "raw": raw,
            "signature_ok": bool(signature_ok),
            "status": STATUS_RECEIVED,
            "error": None,
            "received_at": now,
            "processed_at": None,
        })
        return "new"
    except DuplicateKeyError:
        reclaimed = await db[WEBHOOK_EVENTS_COLLECTION].update_one(
            {"provider": provider, "event_id": event_id, "status": STATUS_FAILED},
            {"$set": {
                "status": STATUS_PROCESSING,
                "signature_ok": bool(signature_ok),
                "error": None,
                "received_at": now,
            }},
        )
        if reclaimed.modified_count:
            return "new"
        return "duplicate"


async def mark_done(db, provider: str, event_id: str, result: Any) -> None:
    await db[WEBHOOK_EVENTS_COLLECTION].update_one(
        {"provider": provider, "event_id": event_id},
        {"$set": {
            "status": STATUS_DONE,
            "result": result,
            "error": None,
            "processed_at": datetime.now(timezone.utc),
        }},
    )


async def mark_failed(db, provider: str, event_id: str, error: str) -> None:
    await db[WEBHOOK_EVENTS_COLLECTION].update_one(
        {"provider": provider, "event_id": event_id},
        {"$set": {
            "status": STATUS_FAILED,
            "error": str(error or "")[:ERROR_TEXT_MAX_LEN],
            "processed_at": datetime.now(timezone.utc),
        }},
    )
