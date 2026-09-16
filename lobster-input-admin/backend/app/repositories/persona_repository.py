import uuid
from datetime import datetime, timezone
from typing import Optional

from motor.motor_asyncio import AsyncIOMotorDatabase

BUILTIN_PERSONAS_COL = "builtin_personas"
PERSONA_STATES_COL = "user_persona_states"
SUPPORTED_LANGS = ("zh", "zh-Hant", "yue", "en", "ru", "ko")


class BuiltinPersonaRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.db = db
        self.col = db[BUILTIN_PERSONAS_COL]
        self.state_col = db[PERSONA_STATES_COL]

    async def ensure_indexes(self) -> None:
        await self.col.create_index("persona_id", unique=True)
        await self.col.create_index([("is_enabled", 1), ("created_at", -1)])
        await self.col.create_index([("created_at", -1)])
        await self.state_col.create_index("user_email", unique=True)

    async def list_all(self) -> list[dict]:
        docs = await self.col.find({}, {"_id": 0}).sort([("created_at", -1)]).to_list(length=None)
        return [_normalize(doc) for doc in docs]

    async def create(self, localized_names: dict, localized_descriptions: dict, prompts: dict) -> dict:
        now = datetime.now(timezone.utc)
        doc = {
            "persona_id": str(uuid.uuid4()),
            "localized_names": _clean_i18n(localized_names),
            "localized_descriptions": _clean_i18n(localized_descriptions),
            "prompts": _clean_prompts(prompts),
            "is_enabled": False,
            "created_at": now,
            "updated_at": now,
        }
        await self.col.insert_one(doc)
        return _normalize(doc)

    async def update(
        self,
        persona_id: str,
        localized_names: Optional[dict],
        localized_descriptions: Optional[dict],
        prompts: Optional[dict],
    ) -> Optional[dict]:
        update = {"updated_at": datetime.now(timezone.utc)}
        if localized_names is not None:
            update["localized_names"] = _clean_i18n(localized_names)
        if localized_descriptions is not None:
            update["localized_descriptions"] = _clean_i18n(localized_descriptions)
        if prompts is not None:
            update["prompts"] = _clean_prompts(prompts)
        if len(update) == 1:
            doc = await self.col.find_one({"persona_id": persona_id}, {"_id": 0})
            return _normalize(doc) if doc else None
        doc = await self.col.find_one_and_update(
            {"persona_id": persona_id},
            {"$set": update},
            return_document=True,
            projection={"_id": 0},
        )
        return _normalize(doc) if doc else None

    async def set_enabled(self, persona_id: str, is_enabled: bool) -> Optional[dict]:
        doc = await self.col.find_one_and_update(
            {"persona_id": persona_id},
            {"$set": {"is_enabled": bool(is_enabled), "updated_at": datetime.now(timezone.utc)}},
            return_document=True,
            projection={"_id": 0},
        )
        return _normalize(doc) if doc else None

    async def delete(self, persona_id: str) -> bool:
        result = await self.col.delete_one({"persona_id": persona_id})
        if result.deleted_count:
            await self.state_col.delete_many({"source": "builtin", "persona_id": persona_id})
            return True
        return False


def _clean(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    text = value.strip()
    return text or None


def _clean_prompts(prompts: dict) -> dict:
    transcribe = _clean(prompts.get("transcribe_prompt"))
    rewrite = _clean(prompts.get("rewrite_prompt"))
    intent = _clean(prompts.get("intent_hint"))
    return {
        "transcribe_prompt": transcribe,
        "transcribe_enabled": bool(transcribe),
        "rewrite_prompt": rewrite,
        "rewrite_enabled": bool(rewrite),
        "intent_hint": intent,
        "intent_enabled": bool(intent),
    }


def _clean_i18n(values: dict) -> dict:
    return {
        lang: cleaned
        for lang in SUPPORTED_LANGS
        if (cleaned := _clean(values.get(lang)))
    }


def _normalize(doc: dict) -> dict:
    doc = dict(doc)
    doc.pop("_id", None)
    doc["id"] = doc.pop("persona_id")
    doc["is_builtin"] = True
    doc["is_enabled"] = bool(doc.get("is_enabled", True))
    doc["is_active"] = False
    doc.setdefault("localized_names", {"zh": doc.get("name", "")})
    doc.setdefault("localized_descriptions", {"zh": doc.get("description", "")})
    doc["name"] = doc["localized_names"].get("zh") or next(iter(doc["localized_names"].values()), "")
    doc["description"] = doc["localized_descriptions"].get("zh") or ""
    doc.setdefault("prompts", {})
    return doc
