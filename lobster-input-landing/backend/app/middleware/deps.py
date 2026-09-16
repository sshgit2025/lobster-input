"""登录态依赖：从 HttpOnly Cookie 解出当前用户邮箱。

官网独立会话——只校验官网自己签发的 lobster_site_token，不涉及主后端会话。
"""
from typing import Annotated, Optional

from fastapi import Cookie

from app.core.config import settings
from app.core.security import decode_site_token
from app.core.errors import AppError

SiteAuthCookie = Annotated[Optional[str], Cookie(alias=settings.AUTH_COOKIE_NAME)]


async def get_current_email(token: SiteAuthCookie = None) -> str:
    if not token:
        raise AppError(401, "UNAUTHENTICATED", "未登录，请先登录")
    payload = decode_site_token(token)
    email = (payload or {}).get("sub")
    if not email:
        raise AppError(401, "UNAUTHENTICATED", "登录已过期，请重新登录")
    return email
