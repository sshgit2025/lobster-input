"""
协议管理接口（管理员专用）。
  GET    /api/v1/agreements              — 列出所有协议
  GET    /api/v1/agreements/content      — 获取单条协议内容
  POST   /api/v1/agreements              — 新增/更新协议
  DELETE /api/v1/agreements/{type}/{lang} — 删除协议
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from app.api.v1.deps import get_current_admin, get_agreement_repo
from app.repositories.agreement_repository import AgreementRepository

router = APIRouter(prefix="/api/v1/agreements", tags=["agreements"])


class UpsertAgreementRequest(BaseModel):
    type: str
    lang: str
    content: str


@router.get("")
async def list_agreements(
    _: str = Depends(get_current_admin),
    repo: AgreementRepository = Depends(get_agreement_repo),
):
    return await repo.list_all()


@router.get("/content")
async def get_agreement_content(
    type: str,
    lang: str,
    _: str = Depends(get_current_admin),
    repo: AgreementRepository = Depends(get_agreement_repo),
):
    doc = await repo.get(type, lang)
    if not doc:
        return {"type": type, "lang": lang, "content": ""}
    return doc


@router.post("")
async def upsert_agreement(
    body: UpsertAgreementRequest,
    _: str = Depends(get_current_admin),
    repo: AgreementRepository = Depends(get_agreement_repo),
):
    await repo.upsert(body.type, body.lang, body.content)
    return {"message": f"协议 {body.type}/{body.lang} 已保存"}


@router.delete("/{agreement_type}/{lang}")
async def delete_agreement(
    agreement_type: str,
    lang: str,
    _: str = Depends(get_current_admin),
    repo: AgreementRepository = Depends(get_agreement_repo),
):
    ok = await repo.delete(agreement_type, lang)
    if not ok:
        raise HTTPException(status_code=404, detail="协议不存在")
    return {"message": f"协议 {agreement_type}/{lang} 已删除"}
