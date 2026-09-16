"""
对外接口安全风控中间件。
基于 IP、账号和高成本接口做短窗口限流，并记录可审计的攻击详情。
"""
import logging
from dataclasses import dataclass
from typing import Optional

from fastapi import Request
from fastapi.responses import JSONResponse
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware

from app.core.config import settings
from app.core.request_utils import client_ip
from app.repositories.security_repository import SecurityRepository

logger = logging.getLogger("voice_input.middleware.security_guard")

_SKIP_PREFIXES = (
    "/health",
    "/docs",
    "/redoc",
    "/openapi.json",
)


@dataclass(frozen=True)
class LimitSpec:
    scope: str
    limit: int
    window_seconds: int
    reason_code: str
    reason_label: str
    severity: str = "medium"


class SecurityGuardMiddleware(BaseHTTPMiddleware):
    """对用户可访问接口做可解释限流与临时封禁。"""

    def __init__(self, app):
        super().__init__(app)
        self.repo = SecurityRepository()

    async def dispatch(self, request: Request, call_next):
        path = request.url.path
        if self._should_skip(request):
            return await call_next(request)

        ip = client_ip(request)
        user_agent = request.headers.get("User-Agent", "")[:500]
        user_email = self._user_email(request)
        method = request.method.upper()
        path_group = self._path_group(method, path)

        await self.repo.touch_identity(
            user_email=user_email,
            ip=ip,
            user_agent=user_agent,
        )

        restriction = await self.repo.get_active_restriction(
            user_email=user_email,
            ip=ip,
        )
        if restriction:
            return self._blocked_response(restriction)

        limited = await self._check_limits(
            user_email=user_email,
            ip=ip,
            method=method,
            path=path,
            path_group=path_group,
            user_agent=user_agent,
        )
        if limited:
            return limited

        response = await call_next(request)
        await self._observe_response(
            user_email=user_email,
            ip=ip,
            method=method,
            path=path,
            path_group=path_group,
            user_agent=user_agent,
            status_code=response.status_code,
        )
        return response

    def _should_skip(self, request: Request) -> bool:
        if request.method.upper() == "OPTIONS":
            return True
        path = request.url.path
        if not path.startswith(("/api/v1/", "/api/v2/")):
            return True
        return path.startswith(_SKIP_PREFIXES)

    @staticmethod
    def _user_email(request: Request) -> Optional[str]:
        auth = request.headers.get("Authorization", "")
        if not auth.lower().startswith("bearer "):
            return None
        token = auth.split(" ", 1)[1].strip()
        try:
            payload = jwt.decode(
                token,
                settings.jwt_secret_key,
                algorithms=[settings.jwt_algorithm],
            )
        except JWTError:
            return None
        email = payload.get("sub")
        return email if email and email != "api_key_user" else None

    @staticmethod
    def _path_group(method: str, path: str) -> str:
        if "/audio/" in path and path.endswith("/process"):
            return "audio_process"
        if path.startswith("/api/v1/hotwords") and method in {"POST", "PUT"}:
            return "hotword_write"
        if path.startswith("/api/v1/auth/"):
            return "auth"
        if method in {"POST", "PUT", "PATCH", "DELETE"}:
            return "write"
        return "general"

    def _limit_specs(self, path_group: str, has_user: bool) -> list[LimitSpec]:
        specs = [
            LimitSpec(
                scope="ip",
                limit=120,
                window_seconds=60,
                reason_code="IP_RATE_LIMIT",
                reason_label="IP 短时间请求过高",
            )
        ]
        if has_user:
            specs.append(LimitSpec(
                scope="account",
                limit=180,
                window_seconds=60,
                reason_code="ACCOUNT_RATE_LIMIT",
                reason_label="账号短时间请求过高",
            ))
        if path_group == "auth":
            specs.append(LimitSpec(
                scope="ip",
                limit=30,
                window_seconds=60,
                reason_code="AUTH_RATE_LIMIT",
                reason_label="认证接口高频访问",
                severity="high",
            ))
        if path_group == "audio_process":
            specs.append(LimitSpec(
                scope="account" if has_user else "ip",
                limit=20 if has_user else 60,
                window_seconds=60,
                reason_code="HIGH_COST_AUDIO_ABUSE",
                reason_label="高成本音频接口高频访问",
                severity="high",
            ))
        if path_group == "hotword_write":
            specs.append(LimitSpec(
                scope="account" if has_user else "ip",
                limit=30,
                window_seconds=60,
                reason_code="HOTWORD_WRITE_ABUSE",
                reason_label="词典写入接口高频访问",
                severity="high",
            ))
        return specs

    async def _check_limits(
        self,
        *,
        user_email: Optional[str],
        ip: str,
        method: str,
        path: str,
        path_group: str,
        user_agent: str,
    ) -> Optional[JSONResponse]:
        for spec in self._limit_specs(path_group, bool(user_email)):
            key = user_email if spec.scope == "account" and user_email else ip
            count = await self.repo.hit_counter(
                scope=spec.scope,
                key=key,
                path_group=path_group,
                window_seconds=spec.window_seconds,
            )
            if count <= spec.limit:
                continue
            action = "blocked" if count >= spec.limit * 3 else "limited"
            severity = "critical" if action == "blocked" else spec.severity
            await self.repo.record_event(
                user_email=user_email,
                ip=ip,
                method=method,
                path=path,
                reason_code=spec.reason_code,
                reason_label=spec.reason_label,
                severity=severity,
                action=action,
                window_seconds=spec.window_seconds,
                request_count=count,
                user_agent=user_agent,
            )
            return self._rate_limited_response(action)

        if user_email:
            ip_count = await self.repo.count_account_ips(
                user_email=user_email,
                window_seconds=600,
            )
            if ip_count >= 10:
                await self.repo.record_event(
                    user_email=user_email,
                    ip=ip,
                    method=method,
                    path=path,
                    reason_code="MULTI_IP_ACCOUNT_ABUSE",
                    reason_label="账号短时间内关联过多访问 IP",
                    severity="high",
                    action="limited",
                    window_seconds=600,
                    request_count=ip_count,
                    user_agent=user_agent,
                )
                return self._rate_limited_response("limited")
        return None

    async def _observe_response(
        self,
        *,
        user_email: Optional[str],
        ip: str,
        method: str,
        path: str,
        path_group: str,
        user_agent: str,
        status_code: int,
    ) -> None:
        if status_code in (401, 403):
            await self._observe_bad_response(
                user_email=user_email,
                ip=ip,
                method=method,
                path=path,
                path_group=path_group,
                user_agent=user_agent,
                status_code=status_code,
                reason_code="AUTH_ABUSE",
                reason_label="认证或权限失败过多",
                limit=20,
                window_seconds=600,
                severity="high",
            )
        elif status_code in (400, 404, 405):
            await self._observe_bad_response(
                user_email=user_email,
                ip=ip,
                method=method,
                path=path,
                path_group=path_group,
                user_agent=user_agent,
                status_code=status_code,
                reason_code="PROBING_OR_SCAN",
                reason_label="异常路径或错误请求过多",
                limit=60,
                window_seconds=300,
                severity="medium",
            )

    async def _observe_bad_response(
        self,
        *,
        user_email: Optional[str],
        ip: str,
        method: str,
        path: str,
        path_group: str,
        user_agent: str,
        status_code: int,
        reason_code: str,
        reason_label: str,
        limit: int,
        window_seconds: int,
        severity: str,
    ) -> None:
        key = user_email or ip
        count = await self.repo.hit_counter(
            scope="bad_response",
            key=key,
            path_group=path_group,
            window_seconds=window_seconds,
        )
        if count <= limit:
            return
        action = "blocked" if count >= limit * 3 else "limited"
        await self.repo.record_event(
            user_email=user_email,
            ip=ip,
            method=method,
            path=path,
            reason_code=reason_code,
            reason_label=reason_label,
            severity="critical" if action == "blocked" else severity,
            action=action,
            window_seconds=window_seconds,
            request_count=count,
            user_agent=user_agent,
            status_code=status_code,
        )

    @staticmethod
    def _rate_limited_response(action: str) -> JSONResponse:
        if action == "blocked":
            return JSONResponse(
                status_code=403,
                content={
                    "code": "SECURITY_BLOCKED",
                    "message": "Request blocked for security reasons",
                },
            )
        return JSONResponse(
            status_code=429,
            content={
                "code": "SECURITY_RATE_LIMITED",
                "message": "Too many requests, please try again later",
            },
            headers={"Retry-After": "900"},
        )

    @staticmethod
    def _blocked_response(restriction: dict) -> JSONResponse:
        action = restriction.get("status")
        return SecurityGuardMiddleware._rate_limited_response(
            "blocked" if action == "blocked" else "limited"
        )
