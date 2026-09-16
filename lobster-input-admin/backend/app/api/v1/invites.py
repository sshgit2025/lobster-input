from fastapi import APIRouter, Depends, Query
from typing import Optional
from app.repositories.invite_repository import InviteRepository
from app.api.v1.deps import get_invite_repo, get_current_admin
from app.models.invite import CreateInviteCodeRequest

router = APIRouter(prefix="/api/v1/invites", tags=["invites"])


@router.get("")
async def list_invites(
    owner_email: Optional[str] = Query(None),
    is_used: Optional[bool] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
    repo: InviteRepository = Depends(get_invite_repo),
):
    q = {}
    if owner_email:
        q["owner_email"] = {"$regex": owner_email, "$options": "i"}
    if is_used is not None:
        q["is_used"] = is_used
    total = await repo.count(q)
    items = await repo.find_paginated(q, page, page_size)
    for item in items:
        item.pop("_id", None)
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/stats")
async def invite_stats(
    _: str = Depends(get_current_admin),
    repo: InviteRepository = Depends(get_invite_repo),
):
    return await repo.get_stats()


@router.post("")
async def create_invite(
    data: CreateInviteCodeRequest,
    _: str = Depends(get_current_admin),
    repo: InviteRepository = Depends(get_invite_repo),
):
    codes = await repo.create_codes(data.owner_email, data.count)
    return {"codes": codes, "message": f"成功创建 {len(codes)} 个邀请码"}


@router.delete("/{code}")
async def delete_invite(
    code: str,
    _: str = Depends(get_current_admin),
    repo: InviteRepository = Depends(get_invite_repo),
):
    ok = await repo.delete_code(code)
    if not ok:
        return {"message": "邀请码不存在或已被使用，无法删除"}
    return {"message": f"邀请码 {code} 已删除"}
