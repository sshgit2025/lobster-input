"""用户词典管理代理 API。"""
import hmac
import logging
import time
from hashlib import sha256
from typing import Optional
from urllib.parse import urlencode, urlsplit

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query

from app.api.v1.deps import get_current_admin
from app.core.config import settings

logger = logging.getLogger("lobster_admin.user_dict")

router = APIRouter(prefix="/api/v1/user-dict", tags=["user-dict"])

BACKEND_TIMEOUT = 30.0


def _backend_url(path: str) -> str:
    return f"{settings.BACKEND_URL.rstrip('/')}/api/v1/admin/user-dict{path}"


def _headers(method: str, url: str, body: bytes = b"") -> dict:
    ts = str(int(time.time()))
    parsed = urlsplit(url)
    payload = b"\n".join([
        method.upper().encode("utf-8"),
        parsed.path.encode("utf-8"),
        parsed.query.encode("utf-8"),
        ts.encode("utf-8"),
        body,
    ])
    signature = hmac.new(settings.BACKEND_API_KEY.encode("utf-8"), payload, sha256).hexdigest()
    return {
        "X-API-Key": settings.BACKEND_API_KEY,
        "X-Internal-Timestamp": ts,
        "X-Internal-Signature": signature,
        "Content-Type": "application/json",
    }


async def _proxy_get(path: str, params: dict | None = None) -> dict:
    query = urlencode(params or {})
    url = _backend_url(path) + (f"?{query}" if query else "")
    async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
        resp = await client.get(url, headers=_headers("GET", url))
    if resp.status_code != 200:
        detail = resp.json().get("detail", resp.text) if resp.headers.get("content-type", "").startswith("application/json") else resp.text
        raise HTTPException(resp.status_code, detail)
    return resp.json()


async def _proxy_delete(path: str) -> dict:
    url = _backend_url(path)
    async with httpx.AsyncClient(timeout=BACKEND_TIMEOUT) as client:
        resp = await client.delete(url, headers=_headers("DELETE", url))
    if resp.status_code != 200:
        detail = resp.json().get("detail", resp.text) if resp.headers.get("content-type", "").startswith("application/json") else resp.text
        raise HTTPException(resp.status_code, detail)
    return resp.json()


@router.get("")
async def list_user_dict(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    user_email: Optional[str] = Query(None),
    _: str = Depends(get_current_admin),
):
    params: dict = {"page": page, "page_size": page_size}
    if user_email:
        params["user_email"] = user_email
    return await _proxy_get("", params)


@router.delete("/{hw_id}")
async def admin_delete_user_dict(
    hw_id: str,
    user_email: str = Query(...),
    _: str = Depends(get_current_admin),
):
    return await _proxy_delete(f"/{hw_id}?{urlencode({'user_email': user_email})}")
