from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from app.models.admin import LoginRequest, ChangePasswordRequest, TokenResponse
from app.repositories.admin_repository import AdminRepository
from app.core.security import create_access_token
from app.core.config import settings
from app.core.database import get_admin_db
from app.api.v1.deps import get_admin_repo, get_current_admin

_LEGACY_AUTH_COOKIE = "access_token"

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])


@router.post("/login", response_model=TokenResponse)
async def login(
    request: Request,
    data: LoginRequest,
    response: Response,
    repo: AdminRepository = Depends(get_admin_repo),
):
    await _check_login_rate(request, data.username)
    user = await repo.verify_login(data.username, data.password)
    if not user:
        await _record_login_failure(request, data.username)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="账号或密码错误")
    await get_admin_db()["admin_login_attempts"].delete_one({"_id": _login_key(request, data.username)})
    token = create_access_token({"sub": data.username})
    response.delete_cookie(_LEGACY_AUTH_COOKIE)
    response.set_cookie(
        key=settings.AUTH_COOKIE_NAME,
        value=token,
        httponly=True,
        samesite="lax",
        secure=settings.COOKIE_SECURE,
        max_age=60 * 60 * 8,
    )
    return TokenResponse(access_token=token)


def _login_key(request: Request, username: str) -> str:
    host = request.client.host if request.client else "unknown"
    return f"{host}:{username.strip().lower()}"


async def _check_login_rate(request: Request, username: str) -> None:
    col = get_admin_db()["admin_login_attempts"]
    await col.create_index("expires_at", expireAfterSeconds=0)
    doc = await col.find_one({"_id": _login_key(request, username)})
    if doc and int(doc.get("count", 0)) >= 8:
        raise HTTPException(status_code=429, detail="登录失败次数过多，请稍后再试")


async def _record_login_failure(request: Request, username: str) -> None:
    now = datetime.now(timezone.utc)
    await get_admin_db()["admin_login_attempts"].update_one(
        {"_id": _login_key(request, username)},
        {
            "$inc": {"count": 1},
            "$set": {"updated_at": now, "expires_at": now + timedelta(minutes=15)},
        },
        upsert=True,
    )


@router.post("/logout")
async def logout(response: Response):
    response.delete_cookie(settings.AUTH_COOKIE_NAME)
    response.delete_cookie(_LEGACY_AUTH_COOKIE)
    return {"message": "已退出登录"}


@router.post("/change-password")
async def change_password(
    data: ChangePasswordRequest,
    username: str = Depends(get_current_admin),
    repo: AdminRepository = Depends(get_admin_repo),
):
    ok = await repo.change_password(username, data.old_password, data.new_password)
    if not ok:
        raise HTTPException(status_code=400, detail="旧密码错误")
    return {"message": "密码修改成功"}
