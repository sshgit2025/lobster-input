from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from app.core.security import (
    verify_password, create_access_token, hash_password,
)
from app.core.config import settings
from app.core.database import get_db
from app.api.v1.deps import get_current_admin, get_admin_repo
from app.repositories.admin_repository import AdminRepository

_LEGACY_AUTH_COOKIE = "access_token"

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])


class LoginRequest(BaseModel):
    username: str
    password: str


class ChangePasswordRequest(BaseModel):
    old_password: str
    new_password: str


@router.post("/login")
async def login(
    request: Request,
    req: LoginRequest,
    repo: AdminRepository = Depends(get_admin_repo),
):
    await _check_login_rate(request, req.username)
    admin = await repo.find_by_username(req.username)
    if not admin or not verify_password(
        req.password, admin["hashed_password"]
    ):
        await _record_login_failure(request, req.username)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="用户名或密码错误",
        )
    await get_db()["admin_login_attempts"].delete_one({"_id": _login_key(request, req.username)})
    token = create_access_token({"sub": req.username})
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(_LEGACY_AUTH_COOKIE)
    resp.set_cookie(
        settings.AUTH_COOKIE_NAME,
        token,
        httponly=True,
        samesite="lax",
        secure=settings.COOKIE_SECURE,
        max_age=3600 * 8,
    )
    return resp


def _login_key(request: Request, username: str) -> str:
    host = request.client.host if request.client else "unknown"
    return f"{host}:{username.strip().lower()}"


async def _check_login_rate(request: Request, username: str) -> None:
    col = get_db()["admin_login_attempts"]
    await col.create_index("expires_at", expireAfterSeconds=0)
    doc = await col.find_one({"_id": _login_key(request, username)})
    if doc and int(doc.get("count", 0)) >= 8:
        raise HTTPException(status_code=429, detail="登录失败次数过多，请稍后再试")


async def _record_login_failure(request: Request, username: str) -> None:
    now = datetime.now(timezone.utc)
    await get_db()["admin_login_attempts"].update_one(
        {"_id": _login_key(request, username)},
        {
            "$inc": {"count": 1},
            "$set": {"updated_at": now, "expires_at": now + timedelta(minutes=15)},
        },
        upsert=True,
    )


@router.post("/logout")
async def logout():
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(settings.AUTH_COOKIE_NAME)
    resp.delete_cookie(_LEGACY_AUTH_COOKIE)
    return resp


@router.post("/change-password")
async def change_password(
    req: ChangePasswordRequest,
    admin: str = Depends(get_current_admin),
    repo: AdminRepository = Depends(get_admin_repo),
):
    admin_doc = await repo.find_by_username(admin)
    if not admin_doc or not verify_password(
        req.old_password, admin_doc["hashed_password"]
    ):
        raise HTTPException(
            status_code=400, detail="原密码错误"
        )
    hashed = hash_password(req.new_password)
    await repo.update_password(admin, hashed)
    return {"ok": True, "message": "密码已修改"}
