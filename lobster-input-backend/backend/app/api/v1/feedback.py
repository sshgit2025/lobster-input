"""
用户反馈接口。
  POST /api/v1/feedback — 登录用户提交反馈意见。
"""
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, Field
from app.core.request_utils import client_ip
from app.middleware.auth import verify_user
from app.repositories.feedback_repository import FeedbackRepository

router = APIRouter(prefix="/feedback", tags=["Feedback"])


class FeedbackCreateRequest(BaseModel):
    content: str = Field(..., min_length=1, max_length=5000, description="反馈意见")
    phone: Optional[str] = Field(None, max_length=64, description="手机号，可选，建议包含区号")
    email: Optional[str] = Field(None, max_length=254, description="邮箱，可选")
    app_version: Optional[str] = Field(None, max_length=64, description="客户端版本，可选")
    os_version: Optional[str] = Field(None, max_length=128, description="系统版本，可选")


@router.post("", summary="提交用户反馈")
async def create_feedback(
    request: Request,
    body: FeedbackCreateRequest,
    payload: dict = Depends(verify_user),
):
    user_email = payload.get("sub")
    if not user_email or user_email == "api_key_user":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": "LOGIN_REQUIRED", "message": "请登录后提交反馈"},
        )

    feedback_id = await FeedbackRepository().insert({
        "user_email": user_email,
        "content": body.content.strip(),
        "phone": body.phone.strip() if body.phone else None,
        "email": body.email.strip() if body.email else None,
        "client_platform": request.headers.get("X-Client-Platform"),
        "app_variant": request.headers.get("X-App-Variant"),
        "accept_language": request.headers.get("X-Accept-Language"),
        "app_version": body.app_version or request.headers.get("X-App-Version"),
        "os_version": body.os_version or request.headers.get("X-OS-Version"),
        "user_agent": request.headers.get("User-Agent"),
        "client_ip": client_ip(request),
        "forwarded_for": request.headers.get("X-Forwarded-For"),
        "real_ip": request.headers.get("X-Real-IP"),
    })
    return {"message": "accepted", "id": feedback_id}
