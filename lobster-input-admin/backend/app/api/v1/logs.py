"""
管理端日志查看 API。
  GET /api/v1/logs  — 分页查询客户端上报日志
  DELETE /api/v1/logs/{log_id} — 删除单条客户端上报日志
"""
import logging
from typing import Optional
from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException, Query
from app.api.v1.deps import get_current_admin, get_main_db

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1/logs", tags=["logs"])

COLLECTION = "client_logs"


def serialize_log(item: dict) -> dict:
    if "_id" in item:
        item["id"] = str(item.pop("_id"))
    if "created_at" in item and item["created_at"] is not None:
        if hasattr(item["created_at"], "isoformat"):
            item["created_at"] = item["created_at"].isoformat()
        else:
            item["created_at"] = str(item["created_at"])
    return item


@router.get("")
async def list_logs(
    email: Optional[str] = Query(None),
    level: Optional[str] = Query(None),
    tag: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    _: str = Depends(get_current_admin),
    db=Depends(get_main_db),
):
    col = db[COLLECTION]
    filt: dict = {}
    if email:
        filt["user_email"] = {"$regex": email, "$options": "i"}
    if level:
        filt["level"] = level
    if tag:
        filt["tag"] = {"$regex": tag, "$options": "i"}

    skip = (page - 1) * page_size
    total = await col.count_documents(filt)
    cursor = col.find(filt).sort("created_at", -1).skip(skip).limit(page_size)
    items = [serialize_log(item) for item in await cursor.to_list(length=page_size)]

    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.delete("/{log_id}")
async def delete_log(
    log_id: str,
    _: str = Depends(get_current_admin),
    db=Depends(get_main_db),
):
    if not ObjectId.is_valid(log_id):
        raise HTTPException(status_code=400, detail="无效日志ID")

    result = await db[COLLECTION].delete_one({"_id": ObjectId(log_id)})
    if result.deleted_count == 0:
        raise HTTPException(status_code=404, detail="日志不存在")
    return {"message": "ok"}
