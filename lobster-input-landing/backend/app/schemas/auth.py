"""认证相关请求/响应模型。"""
from pydantic import BaseModel


class SendCodeRequest(BaseModel):
    email: str


class VerifyRequest(BaseModel):
    email: str
    code: str
    device_id: str = ""
    hardware_fingerprint: str = ""


class VerifyInviteRequest(BaseModel):
    email: str
    invite_code: str
    device_id: str = ""
    hardware_fingerprint: str = ""


class AuthResponse(BaseModel):
    # authenticated=True 表示已登录（Cookie 已下发）；
    # require_invite=True 表示新用户需补填邀请码（未登录）。
    authenticated: bool
    email: str
    tier: str = ""
    is_new_user: bool = False
    require_invite: bool = False
