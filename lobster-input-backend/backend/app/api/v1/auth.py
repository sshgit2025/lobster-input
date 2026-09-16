"""
认证接口。
  POST /api/v1/auth/send-code     — 发送验证码（含临时邮箱拦截 + 频率限制）
  POST /api/v1/auth/verify        — 校验验证码（老用户直登，新用户返回 require_invite）
  POST /api/v1/auth/verify-invite — 新用户填写邀请码完成注册（三维联动封禁）
  GET  /api/v1/auth/invite-codes  — 获取当前用户的邀请码列表（需鉴权）
  POST /api/v1/auth/logout        — 退出登录，清除当前平台登录态（需鉴权，幂等）
"""
from fastapi import APIRouter, Request, Depends
from app.models.schemas import (
    SendCodeRequest,
    LoginRequest,
    AuthResponse,
    VerifyInviteRequest,
    MyInviteCodesResponse,
    InviteCodeItem,
)
from app.services.account.auth_service import AuthService, _get_client_ip
from app.middleware.auth import verify_user

router = APIRouter(prefix="/auth", tags=["Auth"])
auth_service = AuthService()


@router.post("/send-code", summary="发送验证码（含临时邮箱拦截 + 频率限制）")
async def send_code(body: SendCodeRequest, request: Request):
    """
    向指定邮箱发送 6 位数字验证码。
    前置校验：① 临时邮箱域名黑名单 ② 同「邮箱+IP+客户端类型」60s 冷却 ③ 同 IP 每小时限额
    返回 cooldown_seconds 供客户端展示发送倒计时。
    """
    client_ip = _get_client_ip(request)
    client_platform = request.headers.get("X-Client-Platform", "")
    cooldown_seconds = await auth_service.send_unified_code(body.email, client_ip, client_platform)
    return {"message": "Verification code sent", "cooldown_seconds": cooldown_seconds}


@router.post("/verify", response_model=AuthResponse, summary="验证码确认（自动区分新老用户）")
async def verify(body: LoginRequest, request: Request):
    """
    校验验证码。
    - 老用户：直接返回 JWT Token，require_invite=False
    - 新用户：token 为空，require_invite=True，客户端应跳转邀请码填写页
    """
    return await auth_service.verify_unified(
        body.email,
        body.code,
        request.headers.get("X-Client-Platform", ""),
        device_id=body.device_id,
        client_ip=_get_client_ip(request),
        hw_fingerprint=body.hardware_fingerprint,
    )


@router.post("/verify-invite", response_model=AuthResponse, summary="新用户填写邀请码完成注册")
async def verify_invite(body: VerifyInviteRequest, request: Request):
    """
    新用户完成邀请码校验并创建账号。
    三维联动封禁：设备码 / 硬件指纹 / 注册 IP 任意一个达上限 → 全部封禁
    """
    client_ip = _get_client_ip(request)
    return await auth_service.verify_invite(
        email=body.email,
        invite_code=body.invite_code,
        device_id=body.device_id,
        client_ip=client_ip,
        hw_fingerprint=body.hardware_fingerprint,
        client_platform=request.headers.get("X-Client-Platform", ""),
    )


@router.post("/logout", summary="退出登录（清除当前平台登录态）")
async def logout(payload: dict = Depends(verify_user)):
    """
    清除该账号当前平台的 active_sessions.{platform}（$unset，幂等）。
    退出后该平台旧 token 立即失效（后续请求 sid 校验不通过 → 401）。
    平台取自 token 内的 platform 声明（verify_user 已确保与请求平台头一致），
    各平台登录态互不影响。
    """
    email = payload.get("sub", "")
    platform = payload.get("platform", "")
    await auth_service.logout(email, platform)
    return {"ok": True}


@router.get("/invite-codes", response_model=MyInviteCodesResponse, summary="获取我的邀请码")
async def get_invite_codes(payload: dict = Depends(verify_user)):
    """获取当前登录用户的 3 个邀请码及使用状态。"""
    email = payload.get("sub", "")
    codes = await auth_service.get_my_invite_codes(email)
    items = [InviteCodeItem(**c) for c in codes]
    return MyInviteCodesResponse(invite_codes=items)
