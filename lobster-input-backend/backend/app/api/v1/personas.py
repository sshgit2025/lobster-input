"""
人设接口（需鉴权）。

人设定义按 user_email 隔离，全端共享；「激活了哪个人设」按 (user_email, platform)
隔离——四端（mac / ios / windows / android）各自管理各自的激活态，互不影响。
平台取自 JWT payload.platform（已由鉴权中间件校验与 X-Client-Platform 一致）。

  GET    /api/v1/personas            — 获取人设列表（is_active 为当前端激活态）
  POST   /api/v1/personas            — 新建人设（最多 10 个）
  PUT    /api/v1/personas/{id}       — 更新人设（名称/描述/提示词）
  DELETE /api/v1/personas/{id}       — 删除人设
  POST   /api/v1/personas/{id}/activate   — 在当前端激活指定人设
  POST   /api/v1/personas/deactivate-all  — 取消当前端激活（回退内置提示词）
"""
from fastapi import APIRouter, Depends, Header, HTTPException

from app.middleware.auth import verify_user
from app.models.schemas import (
    PersonaItem, PersonaListResponse,
    PersonaCreateRequest, PersonaUpdateRequest,
)
from app.repositories.persona_repository import PersonaRepository, normalize_persona_language
from app.core.exceptions import AppException

router = APIRouter(prefix="/personas", tags=["Personas"])


def _repo() -> PersonaRepository:
    return PersonaRepository()


def _email(payload: dict) -> str:
    return payload.get("sub", "")


def _platform(payload: dict) -> str:
    return payload.get("platform", "")


@router.get("", response_model=PersonaListResponse, summary="获取人设列表")
async def list_personas(
    x_accept_language: str | None = Header(default=None, alias="X-Accept-Language"),
    payload: dict = Depends(verify_user),
    repo: PersonaRepository = Depends(_repo),
):
    personas = await repo.list_personas(
        _email(payload), _platform(payload), normalize_persona_language(x_accept_language)
    )
    return PersonaListResponse(personas=personas)


@router.post("", response_model=PersonaItem, status_code=201, summary="新建人设")
async def create_persona(
    body: PersonaCreateRequest,
    payload: dict = Depends(verify_user),
    repo: PersonaRepository = Depends(_repo),
):
    try:
        return await repo.create_persona(_email(payload), _platform(payload), body)
    except AppException as e:
        raise HTTPException(status_code=e.status_code, detail=e.detail)


@router.put("/{persona_id}", response_model=PersonaItem, summary="更新人设")
async def update_persona(
    persona_id: str,
    body: PersonaUpdateRequest,
    payload: dict = Depends(verify_user),
    repo: PersonaRepository = Depends(_repo),
):
    item = await repo.update_persona(_email(payload), _platform(payload), persona_id, body)
    if not item:
        raise HTTPException(status_code=404, detail={"code": "PERSONA_NOT_FOUND", "message": "人设不存在"})
    return item


@router.delete("/{persona_id}", summary="删除人设")
async def delete_persona(
    persona_id: str,
    payload: dict = Depends(verify_user),
    repo: PersonaRepository = Depends(_repo),
):
    ok = await repo.delete_persona(_email(payload), _platform(payload), persona_id)
    if not ok:
        raise HTTPException(status_code=404, detail={"code": "PERSONA_NOT_FOUND", "message": "人设不存在"})
    return {"message": "deleted"}


@router.post("/{persona_id}/activate", response_model=PersonaItem, summary="激活人设")
async def activate_persona(
    persona_id: str,
    x_accept_language: str | None = Header(default=None, alias="X-Accept-Language"),
    payload: dict = Depends(verify_user),
    repo: PersonaRepository = Depends(_repo),
):
    ok = await repo.activate_persona(_email(payload), _platform(payload), persona_id)
    if not ok:
        raise HTTPException(status_code=404, detail={"code": "PERSONA_NOT_FOUND", "message": "人设不存在"})
    item = await repo.get_persona(
        _email(payload), _platform(payload), persona_id, normalize_persona_language(x_accept_language)
    )
    return item


@router.post("/deactivate-all", summary="取消当前端激活（使用内置提示词）")
async def deactivate_all(
    payload: dict = Depends(verify_user),
    repo: PersonaRepository = Depends(_repo),
):
    await repo.deactivate_all(_email(payload), _platform(payload))
    return {"message": "deactivated"}
