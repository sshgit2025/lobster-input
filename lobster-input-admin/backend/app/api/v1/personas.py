from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

from app.api.v1.deps import get_builtin_persona_repo, get_current_admin
from app.repositories.persona_repository import BuiltinPersonaRepository

router = APIRouter(prefix="/api/v1/personas/builtin", tags=["builtin-personas"])

PROMPT_MAX_LEN = 4000
NAME_MAX_LEN = 60
DESC_MAX_LEN = 200
SUPPORTED_LANGS = ("zh", "zh-Hant", "yue", "en", "ru", "ko")


class PersonaPromptsBody(BaseModel):
    transcribe_prompt: Optional[str] = Field(None, max_length=PROMPT_MAX_LEN)
    transcribe_enabled: bool = False
    rewrite_prompt: Optional[str] = Field(None, max_length=PROMPT_MAX_LEN)
    rewrite_enabled: bool = False
    intent_hint: Optional[str] = Field(None, max_length=PROMPT_MAX_LEN)
    intent_enabled: bool = False


class BuiltinPersonaNamesBody(BaseModel):
    zh: str = Field(..., min_length=1, max_length=NAME_MAX_LEN)
    zh_hant: Optional[str] = Field(None, alias="zh-Hant", max_length=NAME_MAX_LEN)
    yue: Optional[str] = Field(None, max_length=NAME_MAX_LEN)
    en: Optional[str] = Field(None, max_length=NAME_MAX_LEN)
    ru: Optional[str] = Field(None, max_length=NAME_MAX_LEN)
    ko: Optional[str] = Field(None, max_length=NAME_MAX_LEN)


class BuiltinPersonaDescriptionsBody(BaseModel):
    zh: Optional[str] = Field(None, max_length=DESC_MAX_LEN)
    zh_hant: Optional[str] = Field(None, alias="zh-Hant", max_length=DESC_MAX_LEN)
    yue: Optional[str] = Field(None, max_length=DESC_MAX_LEN)
    en: Optional[str] = Field(None, max_length=DESC_MAX_LEN)
    ru: Optional[str] = Field(None, max_length=DESC_MAX_LEN)
    ko: Optional[str] = Field(None, max_length=DESC_MAX_LEN)


class BuiltinPersonaCreateBody(BaseModel):
    localized_names: BuiltinPersonaNamesBody
    localized_descriptions: BuiltinPersonaDescriptionsBody = Field(default_factory=BuiltinPersonaDescriptionsBody)
    prompts: PersonaPromptsBody = Field(default_factory=PersonaPromptsBody)


class BuiltinPersonaUpdateBody(BaseModel):
    localized_names: Optional[BuiltinPersonaNamesBody] = None
    localized_descriptions: Optional[BuiltinPersonaDescriptionsBody] = None
    prompts: Optional[PersonaPromptsBody] = None


class BuiltinPersonaEnabledBody(BaseModel):
    is_enabled: bool


@router.get("")
async def list_builtin_personas(
    _: str = Depends(get_current_admin),
    repo: BuiltinPersonaRepository = Depends(get_builtin_persona_repo),
):
    return {"personas": await repo.list_all()}


@router.post("")
async def create_builtin_persona(
    body: BuiltinPersonaCreateBody,
    _: str = Depends(get_current_admin),
    repo: BuiltinPersonaRepository = Depends(get_builtin_persona_repo),
):
    return await repo.create(
        body.localized_names.model_dump(by_alias=True),
        body.localized_descriptions.model_dump(by_alias=True),
        body.prompts.model_dump(),
    )


@router.put("/{persona_id}")
async def update_builtin_persona(
    persona_id: str,
    body: BuiltinPersonaUpdateBody,
    _: str = Depends(get_current_admin),
    repo: BuiltinPersonaRepository = Depends(get_builtin_persona_repo),
):
    item = await repo.update(
        persona_id,
        body.localized_names.model_dump(by_alias=True) if body.localized_names else None,
        body.localized_descriptions.model_dump(by_alias=True) if body.localized_descriptions else None,
        body.prompts.model_dump() if body.prompts else None,
    )
    if not item:
        raise HTTPException(status_code=404, detail="内置人设不存在")
    return item


@router.patch("/{persona_id}/enabled")
async def set_builtin_persona_enabled(
    persona_id: str,
    body: BuiltinPersonaEnabledBody,
    _: str = Depends(get_current_admin),
    repo: BuiltinPersonaRepository = Depends(get_builtin_persona_repo),
):
    item = await repo.set_enabled(persona_id, body.is_enabled)
    if not item:
        raise HTTPException(status_code=404, detail="内置人设不存在")
    return item


@router.delete("/{persona_id}")
async def delete_builtin_persona(
    persona_id: str,
    _: str = Depends(get_current_admin),
    repo: BuiltinPersonaRepository = Depends(get_builtin_persona_repo),
):
    ok = await repo.delete(persona_id)
    if not ok:
        raise HTTPException(status_code=404, detail="内置人设不存在")
    return {"message": "deleted"}
