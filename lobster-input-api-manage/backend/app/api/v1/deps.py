import hmac
import time
from hashlib import sha256

from fastapi import Depends, HTTPException, Cookie, Header, Request, status
from typing import Annotated, Optional
from app.core.security import decode_access_token
from app.core.config import settings
from app.core.database import get_db
from app.repositories.api_key_repository import ApiKeyRepository
from app.repositories.admin_repository import AdminRepository

async def get_current_admin(
    access_token: Optional[str] = Cookie(default=None, alias=settings.AUTH_COOKIE_NAME),
):
    if not access_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="未登录",
        )
    payload = decode_access_token(access_token)
    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token无效或已过期",
        )
    return payload.get("sub")


async def verify_internal_key(
    request: Request,
    x_internal_key: str = Header(..., alias="X-Internal-Key"),
    x_internal_timestamp: str = Header(..., alias="X-Internal-Timestamp"),
    x_internal_signature: str = Header(..., alias="X-Internal-Signature"),
):
    """验证后端服务调用号池的内部鉴权 Key 和 HMAC 签名。"""
    if not hmac.compare_digest(x_internal_key, settings.INTERNAL_API_KEY):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid internal key",
        )
    try:
        ts = int(x_internal_timestamp)
    except ValueError:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid internal timestamp")
    if abs(int(time.time()) - ts) > settings.INTERNAL_SIGNATURE_TOLERANCE_SEC:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Internal signature expired")
    body = await request.body()
    payload = b"\n".join([
        request.method.upper().encode("utf-8"),
        request.url.path.encode("utf-8"),
        request.url.query.encode("utf-8"),
        x_internal_timestamp.encode("utf-8"),
        body,
    ])
    expected = hmac.new(settings.INTERNAL_API_KEY.encode("utf-8"), payload, sha256).hexdigest()
    if not hmac.compare_digest(x_internal_signature, expected):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid internal signature")
    return True


def get_api_key_repo() -> ApiKeyRepository:
    return ApiKeyRepository(get_db())


def get_admin_repo() -> AdminRepository:
    return AdminRepository(get_db())
