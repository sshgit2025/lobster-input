"""调用主后端公开接口的代理。

目前只用于"发送验证码"：复用主后端真实的邮件发送、临时邮箱拦截、同邮箱冷却
与同 IP 限频逻辑，避免在官网重写这套安全策略。透传真实客户端 IP，使主后端的
限流按真实用户口径生效。
"""
import httpx
from app.core.config import settings
from app.core.errors import AppError


def _extract_upstream_error(resp: httpx.Response) -> dict:
    try:
        data = resp.json()
    except Exception:
        return {"code": "SEND_CODE_FAILED", "message": "发送验证码失败，请稍后再试"}
    detail = data.get("detail", data) if isinstance(data, dict) else data
    if isinstance(detail, dict):
        return {
            "code": detail.get("code") or "SEND_CODE_FAILED",
            "message": detail.get("message") or detail.get("detail") or "发送验证码失败，请稍后再试",
        }
    if isinstance(detail, str):
        return {"code": "SEND_CODE_FAILED", "message": detail}
    return {"code": "SEND_CODE_FAILED", "message": "发送验证码失败，请稍后再试"}


async def proxy_send_code(email: str, client_ip: str) -> None:
    url = f"{settings.BACKEND_URL}/api/v1/auth/send-code"
    # 主后端有平台白名单中间件，只接受 macos/ios/windows/android。发送验证码本身
    # 不创建任何会话、不写 active_sessions（仅发邮件 + 限频），这里带一个合法平台值
    # 仅为通过该中间件，对用户的真实客户端会话零影响；官网自己的登录态独立于此。
    headers = {"Content-Type": "application/json", "X-Client-Platform": "windows"}
    if client_ip and client_ip != "unknown":
        headers["X-Forwarded-For"] = client_ip
        headers["X-Real-IP"] = client_ip
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(url, json={"email": email}, headers=headers)
    except httpx.HTTPError as exc:
        raise AppError(503, "SEND_CODE_UPSTREAM_ERROR", "验证码服务暂不可用，请稍后再试") from exc
    if resp.status_code >= 400:
        info = _extract_upstream_error(resp)
        raise AppError(resp.status_code, info["code"], info["message"])
