"""
用户词典管理接口。

词典只保存用户手工配置的标准词，后端执行 ASR 后处理时自动基于标准词
派生发音索引。这里不再生成向量，也不再写独立索引服务。
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from pymongo.errors import DuplicateKeyError

from app.core.exceptions import HotwordLimitReachedException
from app.middleware.auth import verify_user
from app.models.schemas import (
    HotWord,
    HotWordCreateRequest,
    HotWordListResponse,
    HotWordUpdateRequest,
)
from app.repositories.distributed_lock_repository import DistributedLockRepository
from app.repositories.hotword_repository import HotWordRepository
from app.services.audio.asr_correction import invalidate_user_dictionary_cache

router = APIRouter(prefix="/hotwords", tags=["HotWords"])

_repo = HotWordRepository()
_lock_repo = DistributedLockRepository()


def _email(payload: dict) -> str:
    return payload.get("sub", "")


@router.get("", response_model=HotWordListResponse, summary="查询词典（支持翻页 + 模糊搜索）")
async def list_hotwords(
    page: int = Query(1, ge=1, description="页码，从1开始"),
    page_size: int = Query(50, ge=1, le=200, description="每页条数，最大200"),
    search: str = Query("", description="模糊搜索关键词（大小写不敏感，包含匹配）"),
    payload: dict = Depends(verify_user),
):
    user_email = _email(payload)
    docs = await _repo.list_by_user(user_email)
    keyword = search.strip().lower()
    if keyword:
        docs = [item for item in docs if keyword in item.word.lower()]
    docs_sorted = sorted(docs, key=lambda item: item.created_at or "", reverse=True)
    total = len(docs_sorted)
    offset = (page - 1) * page_size
    page_docs = docs_sorted[offset: offset + page_size]
    return HotWordListResponse(
        hotwords=page_docs,
        total=total,
        page=page,
        page_size=page_size,
        has_more=(offset + page_size) < total,
    )


@router.post("", response_model=HotWord, status_code=201, summary="新增词汇")
async def create_hotword(
    body: HotWordCreateRequest,
    payload: dict = Depends(verify_user),
):
    user_email = _email(payload)
    word = body.word.strip()
    async with _lock_repo.lock(f"hotwords:{user_email}", ttl_seconds=15, wait_seconds=8):
        if await _repo.count_by_user(user_email) >= _repo.max_count:
            raise HotwordLimitReachedException()
        try:
            item = await _repo.create(user_email, word)
            invalidate_user_dictionary_cache(user_email)
            return item
        except DuplicateKeyError:
            raise HTTPException(
                status_code=409,
                detail={"code": "HOTWORD_DUPLICATED", "message": "词典中已存在该词汇"},
            ) from None


@router.put("/{hw_id}", response_model=HotWord, summary="更新词汇")
async def update_hotword(
    hw_id: str,
    body: HotWordUpdateRequest,
    payload: dict = Depends(verify_user),
):
    user_email = _email(payload)
    word = body.word.strip()
    async with _lock_repo.lock(f"hotwords:{user_email}", ttl_seconds=15, wait_seconds=8):
        try:
            item = await _repo.update(user_email, hw_id, word)
        except DuplicateKeyError:
            raise HTTPException(
                status_code=409,
                detail={"code": "HOTWORD_DUPLICATED", "message": "词典中已存在该词汇"},
            ) from None
        if not item:
            raise HTTPException(
                status_code=404,
                detail={"code": "HOTWORD_NOT_FOUND", "message": "词典词汇不存在"},
            )
        invalidate_user_dictionary_cache(user_email)
        return item


@router.delete("/{hw_id}", summary="删除词汇")
async def delete_hotword(
    hw_id: str,
    payload: dict = Depends(verify_user),
):
    user_email = _email(payload)
    async with _lock_repo.lock(f"hotwords:{user_email}", ttl_seconds=15, wait_seconds=8):
        deleted = await _repo.delete(user_email, hw_id)
        if not deleted:
            raise HTTPException(
                status_code=404,
                detail={"code": "HOTWORD_NOT_FOUND", "message": "词典词汇不存在"},
            )
        invalidate_user_dictionary_cache(user_email)
    return {"message": "deleted"}
