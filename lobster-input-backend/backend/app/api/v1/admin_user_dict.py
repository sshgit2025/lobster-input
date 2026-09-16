"""用户词典管理内部 API。"""
from __future__ import annotations

import math

from fastapi import APIRouter, Depends, HTTPException, Query

from app.middleware.auth import verify_internal_api_key
from app.repositories.hotword_repository import HotWordRepository

router = APIRouter(prefix="/admin/user-dict", tags=["Admin - User Dictionary"])


@router.get("", dependencies=[Depends(verify_internal_api_key)])
async def list_user_dict(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    user_email: str | None = Query(None),
):
    docs, total = await HotWordRepository().list_all(
        user_email=user_email,
        page=page,
        page_size=page_size,
    )
    total_pages = max(1, math.ceil(total / page_size))
    return {
        "items": docs,
        "total": total,
        "page": page,
        "page_size": page_size,
        "total_pages": total_pages,
    }


@router.delete("/{hw_id}", dependencies=[Depends(verify_internal_api_key)])
async def admin_delete_user_dict(hw_id: str, user_email: str = Query(...)):
    deleted = await HotWordRepository().delete(user_email, hw_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="User dictionary item not found")
    return {"message": "deleted"}
