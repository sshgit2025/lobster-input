"""协议接口（无需鉴权）。

  GET /api/v1/agreements?type=privacy|terms&lang=xx

直接读共享主库 agreements 集合，按语言取，缺失回退 en。供官网隐私政策/用户协议
页按右上角选中语言展示。
"""
from fastapi import APIRouter

from app.core.errors import AppError
from app.repositories.agreement_repository import AgreementRepository

router = APIRouter(prefix="/api/v1/agreements", tags=["agreements"])
agreement_repo = AgreementRepository()

_ALLOWED_TYPES = {"terms", "privacy"}


@router.get("")
async def get_agreement(type: str, lang: str = "en"):
    if type not in _ALLOWED_TYPES:
        raise AppError(400, "INVALID_AGREEMENT_TYPE", "未知的协议类型")
    return await agreement_repo.get_with_fallback(type, lang)
