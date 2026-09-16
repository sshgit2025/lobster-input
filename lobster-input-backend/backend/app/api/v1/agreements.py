"""
协议接口（公开，无需鉴权）。
  GET /api/v1/agreements?type=terms&lang=zh   — 获取指定语言的协议 MD 文本
"""
from fastapi import APIRouter, Query
from app.repositories.agreement_repository import AgreementRepository

router = APIRouter(prefix="/agreements", tags=["Agreements"])

SUPPORTED_TYPES = {"terms", "privacy"}
SUPPORTED_LANGS = {"zh", "zh-Hant", "yue", "en", "ru", "ko"}
FALLBACK_LANG = "en"


@router.get("", summary="获取协议 Markdown 文本")
async def get_agreement(
    type: str = Query(..., description="协议类型: terms | privacy"),
    lang: str = Query(..., description="语言代码: zh / en / zh-Hant / yue / ru / ko"),
):
    if type not in SUPPORTED_TYPES:
        return {"type": type, "lang": lang, "content": ""}

    target_lang = lang if lang in SUPPORTED_LANGS else FALLBACK_LANG
    repo = AgreementRepository()
    doc = await repo.get(type, target_lang)

    if not doc:
        doc = await repo.get(type, FALLBACK_LANG)

    content = doc["content"] if doc else ""
    return {"type": type, "lang": target_lang, "content": content}
