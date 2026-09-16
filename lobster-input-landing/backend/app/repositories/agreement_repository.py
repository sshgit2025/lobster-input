"""AgreementRepository — 共享主库 agreements 集合（官网协议只读）。

隐私政策 / 用户协议按 (type, lang) 存储，content 为 Markdown 文本。官网直接
读这里，不再走主后端内部接口；按访问语言取，缺失时回退 en（与主后端
app/api/v1/agreements.py 的回退逻辑一致）。
"""
from app.core.database import get_db

COLLECTION = "agreements"
SUPPORTED_LANGS = ("zh", "zh-Hant", "yue", "en", "ru", "ko")
DEFAULT_LANG = "en"


class AgreementRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def get(self, agreement_type: str, lang: str):
        return await self.col.find_one(
            {"type": agreement_type, "lang": lang},
            {"_id": 0},
        )

    async def get_with_fallback(self, agreement_type: str, lang: str) -> dict:
        """取指定语言协议；不支持的语言或缺失时回退 en，仍无则返回空内容。"""
        if lang not in SUPPORTED_LANGS:
            lang = DEFAULT_LANG
        doc = await self.get(agreement_type, lang)
        if not doc and lang != DEFAULT_LANG:
            doc = await self.get(agreement_type, DEFAULT_LANG)
        if not doc:
            return {"type": agreement_type, "lang": lang, "content": ""}
        return doc
