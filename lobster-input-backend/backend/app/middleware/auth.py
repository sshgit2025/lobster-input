"""Authentication dependencies for public users and internal services."""
from __future__ import annotations

import hmac
import logging
import time
from hashlib import sha256

from fastapi import Request, Security
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.security.api_key import APIKeyHeader
from jose import JWTError, jwt

from app.core.config import settings
from app.core.exceptions import SecurityBlockedException, UnauthorizedException, UserBannedException
from app.core.request_utils import client_ip
from app.repositories.security_repository import SecurityRepository
from app.repositories.user_repository import UserRepository
from app.services.account.session_service import is_session_expired

logger = logging.getLogger("voice_input.auth")

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)
bearer_scheme = HTTPBearer(auto_error=False)

_user_repo = UserRepository()
_security_repo = SecurityRepository()


async def verify_user(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Security(bearer_scheme),
) -> dict:
    """Verify a logged-in user JWT. Static API keys are not accepted here."""
    if not credentials:
        raise UnauthorizedException()
    try:
        payload = jwt.decode(
            credentials.credentials,
            settings.jwt_secret_key,
            algorithms=[settings.jwt_algorithm],
        )
    except JWTError as exc:
        raise UnauthorizedException() from exc

    email = (payload.get("sub") or "").strip().lower()
    if not email or email == "api_key_user":
        raise UnauthorizedException()

    user = await _user_repo.find_by_email(email)
    if not user:
        logger.warning("[auth] user not found in DB: %s", email)
        raise UnauthorizedException("User not found")
    if not user.get("is_active", True):
        logger.warning("[auth] banned user request blocked: %s", email)
        raise UserBannedException()
    restriction = await _security_repo.get_active_restriction(
        user_email=email,
        ip=client_ip(request),
    )
    if restriction:
        logger.warning("[auth] security restricted user request blocked: %s", email)
        raise SecurityBlockedException()

    token_platform = payload.get("platform") or ""
    token_session_id = payload.get("sid") or ""
    if not token_platform or not token_session_id:
        logger.warning("[auth] legacy token blocked email=%s", email)
        raise UnauthorizedException("Session expired")

    request_platform = request.headers.get("X-Client-Platform", "") or token_platform
    if token_platform and request_platform and token_platform != request_platform:
        logger.warning(
            "[auth] token platform mismatch email=%s token=%s request=%s",
            email, token_platform, request_platform,
        )
        raise UnauthorizedException("Session expired")

    active_session = (
        (user.get("active_sessions") or {})
        .get(request_platform or token_platform, {})
    )
    active_session_id = active_session.get("session_id") if isinstance(active_session, dict) else None
    if not active_session_id or active_session_id != token_session_id:
        logger.warning(
            "[auth] stale session blocked email=%s platform=%s",
            email, request_platform or token_platform or "-",
        )
        raise UnauthorizedException("Session expired")

    # 滑动窗口过期校验：15 天无活跃则失效；
    # 无 expires_at 的存量 session 视为有效（平滑迁移，由续期中间件补写）
    if is_session_expired(active_session):
        logger.warning(
            "[auth] expired session blocked email=%s platform=%s",
            email, request_platform or token_platform or "-",
        )
        raise UnauthorizedException("Session expired")

    payload["sub"] = email
    return payload


async def verify_internal_api_key(
    request: Request,
    api_key: str = Security(api_key_header),
) -> dict:
    """
    Verify service-to-service requests.

    Internal callers must provide the static key plus a short-lived HMAC signature:
      X-API-Key, X-Internal-Timestamp, X-Internal-Signature
    Signature payload: METHOD + path + query + timestamp + raw body.
    """
    expected = settings.api_key
    if not expected or not api_key or not hmac.compare_digest(api_key, expected):
        raise UnauthorizedException()

    timestamp = request.headers.get("X-Internal-Timestamp", "")
    signature = request.headers.get("X-Internal-Signature", "")
    if not timestamp or not signature:
        raise UnauthorizedException()
    try:
        ts = int(timestamp)
    except ValueError as exc:
        raise UnauthorizedException() from exc
    if abs(int(time.time()) - ts) > settings.internal_signature_tolerance_sec:
        raise UnauthorizedException("Internal signature expired")

    body = await request.body()
    query = request.url.query.encode("utf-8")
    payload = b"\n".join([
        request.method.upper().encode("utf-8"),
        request.url.path.encode("utf-8"),
        query,
        timestamp.encode("utf-8"),
        body,
    ])
    expected_signature = hmac.new(expected.encode("utf-8"), payload, sha256).hexdigest()
    if not hmac.compare_digest(signature, expected_signature):
        raise UnauthorizedException()
    return {"sub": "internal_service", "tier": "internal"}


async def verify_any(
    request: Request,
    api_key: str = Security(api_key_header),
    credentials: HTTPAuthorizationCredentials = Security(bearer_scheme),
) -> dict:
    """Backward-compatible user auth dependency. Static API keys are ignored."""
    return await verify_user(request=request, credentials=credentials)
