"""
登录态滑动续期中间件（接口活跃检测）。

职责: 在响应完成后检测本次请求是否为"含登录态"的业务接口调用,
是则异步调度一次 session 续期(schedule_renewal 内部做同日节流 + create_task),
时效性不敏感,绝不阻塞请求,续期失败也不影响响应。

触发条件(全部满足):
  - 响应 status < 400(鉴权失败/业务失败的请求不算活跃)
  - 路径以 /api/ 开头,且不属于 /api/v1/admin/(管理端与内部服务间接口不续期;
    其余服务间接口走 X-API-Key 而非 Bearer JWT,天然不满足下一条)
  - 请求头携带 Authorization: Bearer <JWT>,且 JWT 可用本服务密钥成功解码
    (仅解 payload 取 email/platform/sid,不查库 —— sid 有效性由鉴权依赖保证,
    续期 update 自带 session_id 条件过滤,伪造/过期 sid 不会产生任何写入)
"""
import logging

from fastapi import Request, Response
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware

from app.core.config import settings
from app.services.account.session_service import schedule_renewal

logger = logging.getLogger("voice_input.middleware.session_renewal")

_RENEWAL_PATH_PREFIX = "/api/"
# 排除管理端(内部服务间)接口: 管理端调用不代表用户活跃
_EXCLUDED_PREFIXES = ("/api/v1/admin/",)


class SessionRenewalMiddleware(BaseHTTPMiddleware):
    """响应完成后异步调度登录态续期,任何异常都被吞掉,不影响正常响应。"""

    async def dispatch(self, request: Request, call_next) -> Response:
        response = await call_next(request)
        try:
            _maybe_schedule_renewal(request, response.status_code)
        except Exception as exc:
            # 续期属于旁路增强逻辑,绝不能影响业务响应
            logger.debug("[session_renewal] skipped due to error: %s", exc)
        return response


def _maybe_schedule_renewal(request: Request, status_code: int) -> None:
    """判定本次请求是否触发续期;命中则交给 schedule_renewal(内含同日节流)。"""
    if status_code >= 400:
        return
    path = request.url.path
    if not path.startswith(_RENEWAL_PATH_PREFIX) or path.startswith(_EXCLUDED_PREFIXES):
        return
    auth = request.headers.get("Authorization", "")
    if not auth.lower().startswith("bearer "):
        return
    token = auth.split(" ", 1)[1].strip()
    if not token:
        return
    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
    except JWTError:
        return
    email = (payload.get("sub") or "").strip().lower()
    platform = payload.get("platform") or ""
    session_id = payload.get("sid") or ""
    if not email or email == "api_key_user" or not platform or not session_id:
        return
    schedule_renewal(email, platform, session_id)
