"""Runtime provider configuration loaded from Lobster Admin."""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from hashlib import sha256
from typing import Any
from urllib.parse import urlsplit
import hmac

import httpx

from app.core.config import settings
from app.services.infra.api_pool_client import PoolKeyInfo, pick_key

logger = logging.getLogger("voice_input.runtime_provider_config")


@dataclass
class RuntimeProvider:
    provider_id: str
    name: str
    category: str
    implementation: str
    pool_group_id: str
    enabled: bool
    config: dict[str, Any]


@dataclass
class RuntimeNode:
    node_id: str
    name: str
    category: str
    provider_id: str
    enabled: bool
    input_schema: dict[str, Any]
    output_schema: dict[str, Any]
    config: dict[str, Any]


_cache: dict[str, Any] | None = None
_cache_expires_at: float = 0.0


def clear_runtime_provider_cache() -> None:
    global _cache, _cache_expires_at
    _cache = None
    _cache_expires_at = 0.0
    logger.info("Runtime provider config cache cleared")


async def get_runtime_config(force_refresh: bool = False) -> dict[str, Any]:
    global _cache, _cache_expires_at
    now = time.monotonic()
    if not force_refresh and _cache is not None and now < _cache_expires_at:
        return _cache
    admin_url = settings.admin_config_url
    internal_key = settings.admin_config_internal_key or settings.api_key
    if not admin_url or not internal_key:
        raise RuntimeError("Admin runtime config is not configured")
    url = f"{admin_url.rstrip('/')}/api/v1/provider-config/runtime/internal"
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.get(url, headers=_signed_headers(internal_key, "GET", url))
    if resp.status_code >= 400:
        raise RuntimeError(f"Admin runtime config fetch failed: {resp.status_code} {resp.text[:300]}")
    data = _clean_runtime_config(resp.json())
    _cache = data
    _cache_expires_at = now + max(1, settings.provider_config_cache_ttl_sec)
    logger.info(
        "Runtime provider config loaded: version=%s providers=%d nodes=%d ttl=%ss",
        data.get("version"), len(data.get("providers", {})), len(data.get("nodes", {})),
        settings.provider_config_cache_ttl_sec,
    )
    return data


def _signed_headers(key: str, method: str, url: str, body: bytes = b"") -> dict[str, str]:
    ts = str(int(time.time()))
    parsed = urlsplit(url)
    payload = b"\n".join([
        method.upper().encode("utf-8"),
        parsed.path.encode("utf-8"),
        parsed.query.encode("utf-8"),
        ts.encode("utf-8"),
        body,
    ])
    signature = hmac.new(key.encode("utf-8"), payload, sha256).hexdigest()
    return {
        "X-Internal-Key": key,
        "X-Internal-Timestamp": ts,
        "X-Internal-Signature": signature,
    }


async def resolve_node_provider(node_id: str, expected_category: str = "") -> tuple[RuntimeNode, RuntimeProvider]:
    cfg = await get_runtime_config()
    node_raw = (cfg.get("nodes") or {}).get(node_id)
    if not node_raw:
        raise RuntimeError(f"Business node not configured: {node_id}")
    node = RuntimeNode(**node_raw)
    if not node.enabled:
        raise RuntimeError(f"Business node is disabled: {node_id}")
    if expected_category and node.category != expected_category:
        raise RuntimeError(f"Business node {node_id} category mismatch: {node.category} != {expected_category}")
    provider_raw = (cfg.get("providers") or {}).get(node.provider_id)
    if not provider_raw:
        raise RuntimeError(f"Provider not configured for node {node_id}: {node.provider_id}")
    provider = RuntimeProvider(**provider_raw)
    if not provider.enabled:
        raise RuntimeError(f"Provider is disabled for node {node_id}: {provider.provider_id}")
    if provider.category != node.category:
        raise RuntimeError(f"Provider {provider.provider_id} category mismatch for node {node_id}")
    return node, provider


async def pick_key_for_node(node_id: str, expected_category: str = "") -> tuple[PoolKeyInfo, RuntimeNode, RuntimeProvider]:
    node, provider = await resolve_node_provider(node_id, expected_category=expected_category)
    key_info = await pick_key(provider.pool_group_id)
    key_info.provider_id = provider.provider_id
    key_info.provider_implementation = provider.implementation
    key_info.business_node_id = node.node_id
    key_info.provider_config = dict(provider.config or {})
    if provider.category and key_info.category and key_info.category != provider.category:
        raise RuntimeError(
            f"Pool group category mismatch for provider {provider.provider_id}: "
            f"{key_info.category} != {provider.category}"
        )
    return key_info, node, provider


def _clean_runtime_config(raw: dict[str, Any]) -> dict[str, Any]:
    providers = {}
    for pid, cfg in (raw.get("providers") or {}).items():
        if not isinstance(cfg, dict):
            continue
        provider_id = _norm(cfg.get("provider_id") or pid)
        providers[provider_id] = {
            "provider_id": provider_id,
            "name": str(cfg.get("name") or provider_id),
            "category": _norm(cfg.get("category")),
            "implementation": _norm(cfg.get("implementation")),
            "pool_group_id": _norm(cfg.get("pool_group_id")),
            "enabled": bool(cfg.get("enabled", True)),
            "config": cfg.get("config") if isinstance(cfg.get("config"), dict) else {},
        }
    nodes = {}
    for nid, cfg in (raw.get("nodes") or {}).items():
        if not isinstance(cfg, dict):
            continue
        node_id = _norm(cfg.get("node_id") or nid)
        nodes[node_id] = {
            "node_id": node_id,
            "name": str(cfg.get("name") or node_id),
            "category": _norm(cfg.get("category")),
            "provider_id": _norm(cfg.get("provider_id")),
            "enabled": bool(cfg.get("enabled", True)),
            "input_schema": cfg.get("input_schema") if isinstance(cfg.get("input_schema"), dict) else {},
            "output_schema": cfg.get("output_schema") if isinstance(cfg.get("output_schema"), dict) else {},
            "config": cfg.get("config") if isinstance(cfg.get("config"), dict) else {},
        }
    return {"version": raw.get("version", 0), "providers": providers, "nodes": nodes}


def _norm(value: Any) -> str:
    return str(value or "").strip().lower().replace(" ", "_")
