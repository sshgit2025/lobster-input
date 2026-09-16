"""Provider and business-node runtime configuration."""
from __future__ import annotations

import hmac
import json
import time
from hashlib import sha256
from urllib.parse import urlencode, urlsplit

import httpx
from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from pydantic import BaseModel

from app.api.v1.deps import get_current_admin, get_main_db
from app.core.config import settings
from app.repositories.provider_config_repository import ProviderConfigRepository

router = APIRouter(prefix="/api/v1/provider-config", tags=["provider-config"])

IMPLEMENTATION_PLATFORM_CODES = {
    "dashscope": {"dashscope"},
    "openai": {"openai"},
    "groq": {"groq"},
    "volcengine": {"volcengine"},
    "dashscope_realtime": {"dashscope_realtime"},
    "volcengine_realtime": {"volcengine_realtime"},
    "aliyun": {"aliyun"},
    "dashscope_web_search": {"aliyun_search"},
    "tavily": {"tavily"},
}


class RuntimeConfigRequest(BaseModel):
    providers: dict
    nodes: dict


def _internal_key() -> str:
    return settings.PROVIDER_CONFIG_INTERNAL_KEY or settings.BACKEND_API_KEY


def _signed_headers(key: str, method: str, url: str, body: bytes = b"", *, backend: bool = False) -> dict:
    ts = str(int(time.time()))
    parsed = urlsplit(url)
    payload = b"\n".join([
        method.upper().encode("utf-8"),
        parsed.path.encode("utf-8"),
        parsed.query.encode("utf-8"),
        ts.encode("utf-8"),
        body,
    ])
    sig = hmac.new(key.encode("utf-8"), payload, sha256).hexdigest()
    if backend:
        return {
            "X-API-Key": key,
            "X-Internal-Timestamp": ts,
            "X-Internal-Signature": sig,
            "Content-Type": "application/json",
        }
    return {
        "X-Internal-Key": key,
        "X-Internal-Timestamp": ts,
        "X-Internal-Signature": sig,
        "Content-Type": "application/json",
    }


async def verify_provider_internal(
    request: Request,
    x_internal_key: str = Header(default="", alias="X-Internal-Key"),
    x_internal_timestamp: str = Header(default="", alias="X-Internal-Timestamp"),
    x_internal_signature: str = Header(default="", alias="X-Internal-Signature"),
):
    expected = _internal_key()
    if not expected or not x_internal_key or not hmac.compare_digest(x_internal_key, expected):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid internal key")
    try:
        ts = int(x_internal_timestamp)
    except Exception:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid timestamp")
    if abs(int(time.time()) - ts) > 300:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Signature expired")
    body = await request.body()
    parsed = urlsplit(str(request.url))
    payload = b"\n".join([
        request.method.upper().encode("utf-8"),
        parsed.path.encode("utf-8"),
        parsed.query.encode("utf-8"),
        x_internal_timestamp.encode("utf-8"),
        body,
    ])
    expected_sig = hmac.new(expected.encode("utf-8"), payload, sha256).hexdigest()
    if not x_internal_signature or not hmac.compare_digest(x_internal_signature, expected_sig):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid signature")
    return True


@router.get("/runtime")
async def get_runtime_config(
    _admin: str = Depends(get_current_admin),
):
    repo = ProviderConfigRepository(get_main_db())
    await repo.ensure_default()
    return await repo.get()


@router.post("/runtime")
async def save_runtime_config(
    req: RuntimeConfigRequest,
    _admin: str = Depends(get_current_admin),
):
    repo = ProviderConfigRepository(get_main_db())
    raw = req.model_dump()
    _validate_raw_runtime_request(raw)
    cleaned = repo._clean(raw)
    catalog = await _fetch_pool_catalog(required=True)
    _validate_runtime_config(cleaned, catalog)
    saved = await repo.save(cleaned)
    await _notify_backend_cache_clear()
    return saved


@router.get("/runtime/internal")
async def get_runtime_config_internal(
    _auth: bool = Depends(verify_provider_internal),
):
    repo = ProviderConfigRepository(get_main_db())
    await repo.ensure_default()
    return await repo.get()


@router.get("/pool-catalog")
async def get_pool_catalog(
    category: str = "",
    _admin: str = Depends(get_current_admin),
):
    return await _fetch_pool_catalog(category=category, required=False)


async def _fetch_pool_catalog(category: str = "", *, required: bool) -> dict:
    if not settings.API_POOL_URL or not settings.API_POOL_INTERNAL_KEY:
        message = "API_POOL_URL/API_POOL_INTERNAL_KEY 未配置"
        if required:
            raise HTTPException(status_code=400, detail=f"无法校验 Provider 可用性：{message}")
        return {"categories": [], "platforms": [], "groups": [], "warning": message}
    params = {}
    if category:
        params["category"] = category
    query = f"?{urlencode(params)}" if params else ""
    url = f"{settings.API_POOL_URL.rstrip('/')}/api/v1/pool/catalog{query}"
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            resp = await client.get(url, headers=_signed_headers(settings.API_POOL_INTERNAL_KEY, "GET", url))
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail=f"无法连接号池服务，不能保存 Provider 配置：{exc}") from exc
    if resp.status_code >= 400:
        raise HTTPException(
            status_code=resp.status_code if not required else 503,
            detail=f"号池目录读取失败，不能保存 Provider 配置：{resp.text[:500]}",
        )
    return resp.json()


def _validate_runtime_config(runtime: dict, catalog: dict) -> None:
    providers = runtime.get("providers") if isinstance(runtime.get("providers"), dict) else {}
    nodes = runtime.get("nodes") if isinstance(runtime.get("nodes"), dict) else {}
    groups = catalog.get("groups") if isinstance(catalog.get("groups"), list) else []
    groups_by_id = {str(group.get("group_id") or ""): group for group in groups if group.get("group_id")}
    errors: list[str] = []

    for provider in providers.values():
        if not isinstance(provider, dict) or provider.get("enabled") is False:
            continue
        errors.extend(_provider_group_errors(provider, groups_by_id, require_active_key=False, prefix=f"Provider {provider.get('provider_id') or '-'}"))

    for node in nodes.values():
        if not isinstance(node, dict) or node.get("enabled") is False:
            continue
        node_id = str(node.get("node_id") or "-")
        provider_id = str(node.get("provider_id") or "")
        if not provider_id:
            errors.append(f"业务节点 {node_id} 已启用但未选择 Provider")
            continue
        provider = providers.get(provider_id)
        if not provider:
            errors.append(f"业务节点 {node_id} 绑定的 Provider {provider_id} 不存在")
            continue
        if provider.get("enabled") is False:
            errors.append(f"业务节点 {node_id} 不能绑定已停用的 Provider {provider_id}")
        if str(node.get("category") or "") != str(provider.get("category") or ""):
            errors.append(
                f"业务节点 {node_id} 分类 {node.get('category') or '-'} 与 Provider {provider_id} 分类 {provider.get('category') or '-'} 不一致"
            )
        errors.extend(_provider_group_errors(provider, groups_by_id, require_active_key=True, prefix=f"业务节点 {node_id} 绑定的 Provider {provider_id}"))

    if errors:
        detail = "Provider 配置校验失败：\n" + "\n".join(f"- {item}" for item in errors[:20])
        if len(errors) > 20:
            detail += f"\n- 还有 {len(errors) - 20} 个错误未显示"
        raise HTTPException(status_code=400, detail=detail)


def _validate_raw_runtime_request(raw: dict) -> None:
    errors: list[str] = []
    providers = raw.get("providers")
    nodes = raw.get("nodes")
    if not isinstance(providers, dict):
        errors.append("providers 必须是对象")
        providers = {}
    if not isinstance(nodes, dict):
        errors.append("nodes 必须是对象")
        nodes = {}

    seen_providers: set[str] = set()
    for key, provider in providers.items():
        if not isinstance(provider, dict):
            errors.append(f"Provider {key} 配置格式错误")
            continue
        provider_id = _norm_text(provider.get("provider_id") or key)
        if not provider_id:
            errors.append(f"Provider {key} 缺少 provider_id")
        elif provider_id in seen_providers:
            errors.append(f"Provider ID {provider_id} 重复")
        seen_providers.add(provider_id)
        if not _norm_text(provider.get("category")):
            errors.append(f"Provider {provider_id or key} 缺少分类")
        if not _norm_text(provider.get("implementation")):
            errors.append(f"Provider {provider_id or key} 缺少实现标识")
        if not _norm_text(provider.get("pool_group_id")):
            errors.append(f"Provider {provider_id or key} 未绑定号池分组")
        if "config" in provider and not isinstance(provider.get("config"), dict):
            errors.append(f"Provider {provider_id or key} 的附加配置必须是 JSON 对象")

    seen_nodes: set[str] = set()
    for key, node in nodes.items():
        if not isinstance(node, dict):
            errors.append(f"业务节点 {key} 配置格式错误")
            continue
        node_id = _norm_text(node.get("node_id") or key)
        if not node_id:
            errors.append(f"业务节点 {key} 缺少 node_id")
        elif node_id in seen_nodes:
            errors.append(f"业务节点 ID {node_id} 重复")
        seen_nodes.add(node_id)
        if not _norm_text(node.get("category")):
            errors.append(f"业务节点 {node_id or key} 缺少分类")
        if node.get("enabled", True) is not False and not _norm_text(node.get("provider_id")):
            errors.append(f"业务节点 {node_id or key} 已启用但未选择 Provider")
        if "input_schema" in node and not isinstance(node.get("input_schema"), dict):
            errors.append(f"业务节点 {node_id or key} 的输入定义必须是 JSON 对象")
        if "output_schema" in node and not isinstance(node.get("output_schema"), dict):
            errors.append(f"业务节点 {node_id or key} 的输出定义必须是 JSON 对象")
        if "config" in node and not isinstance(node.get("config"), dict):
            errors.append(f"业务节点 {node_id or key} 的附加配置必须是 JSON 对象")

    if errors:
        detail = "Provider 配置格式校验失败：\n" + "\n".join(f"- {item}" for item in errors[:20])
        if len(errors) > 20:
            detail += f"\n- 还有 {len(errors) - 20} 个错误未显示"
        raise HTTPException(status_code=400, detail=detail)


def _provider_group_errors(provider: dict, groups_by_id: dict[str, dict], *, require_active_key: bool, prefix: str) -> list[str]:
    errors: list[str] = []
    group_id = str(provider.get("pool_group_id") or "")
    category = str(provider.get("category") or "")
    if not group_id:
        return [f"{prefix} 未绑定号池分组"]
    group = groups_by_id.get(group_id)
    if not group:
        return [f"{prefix} 绑定的号池分组 {group_id} 不存在"]
    group_category = str(group.get("category") or "")
    if category and group_category and category != group_category:
        errors.append(f"{prefix} 分类 {category} 与号池分组 {group_id} 分类 {group_category} 不一致")
    implementation = _norm_text(provider.get("implementation"))
    platform_code = _norm_text(group.get("platform_code"))
    expected_platforms = IMPLEMENTATION_PLATFORM_CODES.get(implementation)
    if expected_platforms and platform_code and platform_code not in expected_platforms:
        errors.append(
            f"{prefix} 实现 {implementation} 不能绑定平台 {platform_code} 的号池分组 {group_id}"
        )
    if group.get("enabled") is False:
        errors.append(f"{prefix} 绑定的号池分组 {group_id} 已停用")
    if require_active_key and _to_int(group.get("active_key_count")) <= 0:
        errors.append(f"{prefix} 绑定的号池分组 {group_id} 当前没有有效 API Key")
    return errors


def _to_int(value: object) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _norm_text(value: object) -> str:
    return str(value or "").strip().lower().replace(" ", "_")


async def _notify_backend_cache_clear() -> None:
    if not settings.BACKEND_URL or not settings.BACKEND_API_KEY:
        return
    url = f"{settings.BACKEND_URL.rstrip('/')}/api/v1/admin/runtime-config/cache/clear"
    body = json.dumps({"source": "lobster-admin"}, separators=(",", ":")).encode("utf-8")
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            await client.post(url, headers=_signed_headers(settings.BACKEND_API_KEY, "POST", url, body, backend=True), content=body)
    except Exception:
        return
