"""Client SDK for lobster-input-api-manage group-based API pool."""
from __future__ import annotations

import hmac
import json
import logging
import time
from dataclasses import dataclass, field
from hashlib import sha256
from typing import Optional
from urllib.parse import urlencode, urlsplit

import httpx

from app.core.config import settings

logger = logging.getLogger("voice_input.api_pool")

_http_client: Optional[httpx.AsyncClient] = None


def _get_client() -> httpx.AsyncClient:
    global _http_client
    if _http_client is None or _http_client.is_closed:
        _http_client = httpx.AsyncClient(timeout=10.0)
    return _http_client


def _signed_headers(method: str, url: str, body: bytes = b"") -> dict:
    ts = str(int(time.time()))
    parsed = urlsplit(url)
    payload = b"\n".join([
        method.upper().encode("utf-8"),
        parsed.path.encode("utf-8"),
        parsed.query.encode("utf-8"),
        ts.encode("utf-8"),
        body,
    ])
    signature = hmac.new(settings.api_pool_internal_key.encode("utf-8"), payload, sha256).hexdigest()
    return {
        "X-Internal-Key": settings.api_pool_internal_key,
        "X-Internal-Timestamp": ts,
        "X-Internal-Signature": signature,
        "Content-Type": "application/json",
    }


@dataclass
class PoolKeyInfo:
    id: str
    api_key: str
    base_url: str = ""
    model: str = ""
    group_id: str = ""
    category: str = ""
    platform_code: str = ""
    platform_name: str = ""
    provider_id: str = ""
    provider_implementation: str = ""
    business_node_id: str = ""
    provider_config: dict = field(default_factory=dict)
    extra_config: dict = field(default_factory=dict)
    proxy_config: dict = field(default_factory=dict)
    # 计费用：LLMService 在调用完成后回填 provider 返回的真实 token 数（None 表示未知）
    real_input_tokens: int | None = None
    real_output_tokens: int | None = None


async def pick_key(group_id: str) -> PoolKeyInfo:
    pool_url = settings.api_pool_url
    pool_key = settings.api_pool_internal_key
    if not pool_url or not pool_key:
        raise RuntimeError("API pool not configured (API_POOL_URL / API_POOL_INTERNAL_KEY missing)")
    if not group_id:
        raise RuntimeError("API pool group_id is required")

    t0 = time.monotonic()
    try:
        client = _get_client()
        query = urlencode({"group_id": group_id})
        url = f"{pool_url.rstrip('/')}/api/v1/pool/pick?{query}"
        resp = await client.get(url, headers=_signed_headers("GET", url))
        elapsed_ms = (time.monotonic() - t0) * 1000
        if resp.status_code == 200:
            data = resp.json()
            logger.info(
                "Pool pick group=%s -> id=%s platform=%s (%.1fms)",
                group_id, data["id"], data.get("platform_code", ""), elapsed_ms,
            )
            return PoolKeyInfo(
                id=data["id"],
                api_key=data["api_key"],
                base_url=data.get("base_url", ""),
                model=data.get("model", ""),
                group_id=data.get("group_id", group_id),
                category=data.get("category", ""),
                platform_code=data.get("platform_code", ""),
                platform_name=data.get("platform_name", ""),
                extra_config=data.get("extra_config") or {},
                proxy_config=data.get("proxy_config") or {},
            )
        if resp.status_code == 503:
            raise RuntimeError(f"No available key in pool for group_id={group_id} ({elapsed_ms:.1f}ms)")
        raise RuntimeError(f"Pool pick failed: {resp.status_code} {resp.text[:200]} ({elapsed_ms:.1f}ms)")
    except RuntimeError:
        raise
    except Exception as e:
        elapsed_ms = (time.monotonic() - t0) * 1000
        raise RuntimeError(f"Pool pick error for group_id={group_id}: {e} ({elapsed_ms:.1f}ms)") from e


async def report_usage(
    key_info: PoolKeyInfo,
    tokens_used: float = 0,
    seconds_used: float = 0,
    requests_used: int = 1,
    operation: str = "",
    user_email: str = "",
    latency_ms: int = 0,
    success: bool = True,
    error_message: str = "",
    client_platform: str = "",
) -> None:
    pool_url = settings.api_pool_url
    pool_key = settings.api_pool_internal_key
    if not pool_url or not pool_key:
        return

    try:
        from app.data.usage.extractors.base import BaseUsageExtractor
        hint = BaseUsageExtractor._mask_api_key(key_info.api_key)
        client = _get_client()
        url = f"{pool_url.rstrip('/')}/api/v1/pool/usage"
        payload = json.dumps({
            "api_key_id": key_info.id,
            "group_id": key_info.group_id,
            "category": key_info.category,
            "platform_code": key_info.platform_code,
            "tokens_used": tokens_used,
            "seconds_used": seconds_used,
            "requests_used": requests_used,
            "operation": operation,
            "user_email": user_email,
            "latency_ms": latency_ms,
            "success": success,
            "error_message": error_message,
            "client_platform": client_platform,
            "api_key_hint": hint,
        }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        await client.post(url, headers=_signed_headers("POST", url, payload), content=payload)
    except Exception as e:
        logger.debug("Pool usage report failed: %s", e)


async def report_error(key_info: PoolKeyInfo, error_message: str = "") -> None:
    pool_url = settings.api_pool_url
    pool_key = settings.api_pool_internal_key
    if not pool_url or not pool_key:
        return
    try:
        client = _get_client()
        url = f"{pool_url.rstrip('/')}/api/v1/pool/error"
        payload = json.dumps({
            "api_key_id": key_info.id,
            "error_message": error_message,
        }, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        await client.post(url, headers=_signed_headers("POST", url, payload), content=payload)
    except Exception as e:
        logger.debug("Pool error report failed: %s", e)
