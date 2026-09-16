"""认证接口（官网自管会话）。

  POST /api/v1/auth/send-code     — 发送验证码（代理主后端）
  POST /api/v1/auth/verify        — 验证码登录/注册（老用户登录，新用户判定是否需邀请码）
  POST /api/v1/auth/verify-invite — 新用户填邀请码完成注册
  GET  /api/v1/auth/me            — 当前登录用户
  POST /api/v1/auth/logout        — 退出登录
"""
from fastapi import APIRouter, Depends, Request, Response

from app.core.config import settings
from app.core.request_utils import client_ip
from app.core.security import create_site_token
from app.middleware.deps import get_current_email
from app.schemas.auth import SendCodeRequest, VerifyRequest, VerifyInviteRequest, AuthResponse
from app.services.auth_service import AuthService

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])
auth_service = AuthService()


def _set_session_cookie(response: Response, email: str) -> None:
    token = create_site_token(email)
    response.set_cookie(
        key=settings.AUTH_COOKIE_NAME,
        value=token,
        httponly=True,
        samesite="lax",
        secure=settings.COOKIE_SECURE,
        path=settings.COOKIE_PATH,
        max_age=settings.SITE_JWT_EXPIRE_MINUTES * 60,
    )


@router.post("/send-code")
async def send_code(body: SendCodeRequest, request: Request):
    await auth_service.send_code(body.email, client_ip(request))
    return {"message": "Verification code sent"}


@router.post("/verify", response_model=AuthResponse)
async def verify(body: VerifyRequest, request: Request, response: Response):
    result = await auth_service.verify(
        email=body.email,
        code=body.code,
        device_id=body.device_id,
        client_ip=client_ip(request),
        hw_fingerprint=body.hardware_fingerprint,
    )
    if result.get("authenticated"):
        _set_session_cookie(response, result["email"])
    return result


@router.post("/verify-invite", response_model=AuthResponse)
async def verify_invite(body: VerifyInviteRequest, request: Request, response: Response):
    result = await auth_service.verify_invite(
        email=body.email,
        invite_code=body.invite_code,
        device_id=body.device_id,
        client_ip=client_ip(request),
        hw_fingerprint=body.hardware_fingerprint,
    )
    if result.get("authenticated"):
        _set_session_cookie(response, result["email"])
    return result


@router.get("/me")
async def me(email: str = Depends(get_current_email)):
    return {"email": email}


@router.post("/logout")
async def logout(response: Response):
    response.delete_cookie(settings.AUTH_COOKIE_NAME, path=settings.COOKIE_PATH)
    return {"message": "已退出登录"}
