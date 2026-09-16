"""
管理端反馈查看 API。
  GET /api/v1/feedback — 分页查询用户反馈
  POST /api/v1/feedback/{feedback_id}/status — 修改反馈状态
"""
from typing import Optional
from datetime import datetime, timezone
from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from app.api.v1.deps import get_current_admin, get_main_db

router = APIRouter(prefix="/api/v1/feedback", tags=["feedback"])
COLLECTION = "user_feedback"
VALID_STATUSES = {"未处理", "挂起", "忽略", "实现中", "已实现"}


class FeedbackStatusUpdate(BaseModel):
    status: str


def serialize_feedback(item: dict) -> dict:
    item["id"] = str(item.pop("_id"))
    for key in ("created_at", "updated_at"):
        if key in item and hasattr(item[key], "isoformat"):
            item[key] = item[key].isoformat()
    return item


@router.get("")
async def list_feedback(
    email: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    platform: Optional[str] = Query(None),
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    _: str = Depends(get_current_admin),
    db=Depends(get_main_db),
):
    filt: dict = {}
    if email:
        filt["user_email"] = {"$regex": email, "$options": "i"}
    if status:
        filt["status"] = status
    if platform:
        filt["client_platform"] = platform

    skip = (page - 1) * page_size
    col = db[COLLECTION]
    total = await col.count_documents(filt)
    cursor = col.find(filt).sort("created_at", -1).skip(skip).limit(page_size)
    items = [serialize_feedback(item) for item in await cursor.to_list(length=page_size)]
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.post("/{feedback_id}/status")
async def update_feedback_status(
    feedback_id: str,
    body: FeedbackStatusUpdate,
    _: str = Depends(get_current_admin),
    db=Depends(get_main_db),
):
    if body.status not in VALID_STATUSES:
        raise HTTPException(status_code=400, detail="无效状态")
    if not ObjectId.is_valid(feedback_id):
        raise HTTPException(status_code=400, detail="无效反馈ID")

    result = await db[COLLECTION].update_one(
        {"_id": ObjectId(feedback_id)},
        {"$set": {"status": body.status, "updated_at": datetime.now(timezone.utc)}},
    )
    if result.matched_count == 0:
        raise HTTPException(status_code=404, detail="反馈不存在")
    return {"message": "ok"}
