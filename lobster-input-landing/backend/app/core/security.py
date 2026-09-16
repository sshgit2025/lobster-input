"""官网独立会话 JWT 的签发与校验。

与主后端 JWT 完全独立：用官网自己的 SITE_JWT_SECRET 签名，payload 只含
邮箱与过期时间，不带 platform/sid，因此绝不会与 Mac/Win/安卓/iOS 的
单平台单设备会话互相干扰。
"""
from datetime import datetime, timedelta, timezone
from typing import Optional

from jose import JWTError, jwt
from app.core.config import settings


def create_site_token(email: str) -> str:
    payload = {
        "sub": email,
        "exp": datetime.now(timezone.utc) + timedelta(minutes=settings.SITE_JWT_EXPIRE_MINUTES),
    }
    return jwt.encode(payload, settings.SITE_JWT_SECRET, algorithm=settings.SITE_JWT_ALGORITHM)


def decode_site_token(token: str) -> Optional[dict]:
    try:
        return jwt.decode(token, settings.SITE_JWT_SECRET, algorithms=[settings.SITE_JWT_ALGORITHM])
    except JWTError:
        return None
