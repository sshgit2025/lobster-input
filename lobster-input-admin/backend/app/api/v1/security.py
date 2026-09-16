from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from app.api.v1.deps import get_current_admin, get_security_repo
from app.repositories.security_repository import SecurityRepository

router = APIRouter(prefix="/api/v1/security", tags=["security"])


@router.get("/identities")
async def list_security_identities(
    status: Optional[str] = Query(None),
    email: Optional[str] = Query(None),
    ip: Optional[str] = Query(None),
    reason: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
    repo: SecurityRepository = Depends(get_security_repo),
):
    total, items = await repo.list_identities(
        status=status,
        email=email,
        ip=ip,
        reason=reason,
        page=page,
        page_size=page_size,
    )
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.get("/identities/{identity_id}")
async def get_security_identity_detail(
    identity_id: str,
    _: str = Depends(get_current_admin),
    repo: SecurityRepository = Depends(get_security_repo),
):
    item = await repo.get_identity_detail(identity_id)
    if not item:
        raise HTTPException(status_code=404, detail="风控身份不存在")
    return item


@router.get("/events")
async def list_security_events(
    email: Optional[str] = Query(None),
    ip: Optional[str] = Query(None),
    reason: Optional[str] = Query(None),
    action: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
    repo: SecurityRepository = Depends(get_security_repo),
):
    total, items = await repo.list_events(
        email=email,
        ip=ip,
        reason=reason,
        action=action,
        page=page,
        page_size=page_size,
    )
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.post("/identities/{identity_id}/clear")
async def clear_security_identity(
    identity_id: str,
    _: str = Depends(get_current_admin),
    repo: SecurityRepository = Depends(get_security_repo),
):
    ok = await repo.clear_identity(identity_id)
    if not ok:
        raise HTTPException(status_code=404, detail="风控身份不存在")
    return {"message": "已解除限制"}
