"""PersonaRepository: user personas, builtin personas, and per-(user, platform) activation state.

人设定义（user_personas / builtin_personas）在同一用户的所有端之间共享，
但「激活了哪个人设」是逐端独立的状态：以 (user_email, platform) 为键存储，
mac / ios / windows / android 各自管理各自的激活指针，互不影响。
"""
import logging
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import status

from app.core.content_i18n import clean_i18n, localized_text, normalize_language
from app.core.database import get_db
from app.core.exceptions import AppException
from app.models.schemas import (
    BuiltinPersonaCreateRequest,
    BuiltinPersonaUpdateRequest,
    PERSONA_MAX_COUNT,
    PersonaCreateRequest,
    PersonaItem,
    PersonaPrompts,
    PersonaUpdateRequest,
)

logger = logging.getLogger(__name__)

USER_PERSONAS_COL = "user_personas"
BUILTIN_PERSONAS_COL = "builtin_personas"
PERSONA_STATES_COL = "user_persona_states"
SOURCE_USER = "user"
SOURCE_BUILTIN = "builtin"
BUILTIN_ENABLED_FILTER = {"is_enabled": {"$ne": False}}
# 四端合法平台标识，与 X-Client-Platform / JWT payload.platform 取值一致
VALID_PLATFORMS = ("macos", "ios", "windows", "android", "harmony")
# 旧版仅按 user_email 唯一的激活状态索引名（自动生成）；多端隔离后必须移除
_LEGACY_STATE_INDEX = "user_email_1"


def _builtin_available_filter(**extra: object) -> dict:
    return {**extra, **BUILTIN_ENABLED_FILTER}


class PersonaRepository:
    """Repository for all persona types.

    Builtin personas are global records managed by admins. User activation is stored
    separately, so a public builtin record is never mutated for one user's state.
    """

    @property
    def user_col(self):
        return get_db()[USER_PERSONAS_COL]

    @property
    def builtin_col(self):
        return get_db()[BUILTIN_PERSONAS_COL]

    @property
    def state_col(self):
        return get_db()[PERSONA_STATES_COL]

    async def ensure_indexes(self) -> None:
        await self.user_col.create_index([("user_email", 1), ("persona_id", 1)], unique=True)
        await self.user_col.create_index([("user_email", 1), ("created_at", -1)])
        await self.builtin_col.create_index("persona_id", unique=True)
        await self.builtin_col.create_index([("is_enabled", 1), ("created_at", -1)])
        await self.builtin_col.create_index([("created_at", -1)])
        # 激活状态按 (user_email, platform) 隔离，每端各自一条记录
        await self._drop_legacy_state_index()
        await self.state_col.create_index([("user_email", 1), ("platform", 1)], unique=True)

    async def _drop_legacy_state_index(self) -> None:
        """移除旧版仅按 user_email 唯一的索引，否则同一用户多端激活会冲突。"""
        try:
            existing = await self.state_col.index_information()
        except Exception:
            return
        if _LEGACY_STATE_INDEX in existing:
            await self.state_col.drop_index(_LEGACY_STATE_INDEX)
            logger.info("Dropped legacy persona-state index %s", _LEGACY_STATE_INDEX)

    async def list_personas(
        self, user_email: str, platform: str, language: str = "zh"
    ) -> list[PersonaItem]:
        active = await self._get_active_ref(user_email, platform)
        builtin_docs = await self.builtin_col.find(BUILTIN_ENABLED_FILTER, {"_id": 0}).sort(
            [("created_at", -1)]
        ).to_list(length=None)
        user_docs = await self.user_col.find(
            {"user_email": user_email},
            {"_id": 0, "user_email": 0},
        ).sort([("created_at", -1)]).to_list(length=PERSONA_MAX_COUNT)

        items = [
            _doc_to_item(doc, is_builtin=True, active_ref=active, redact_prompts=True, language=language)
            for doc in builtin_docs
        ] + [
            _doc_to_item(doc, is_builtin=False, active_ref=active)
            for doc in user_docs
        ]
        return sorted(items, key=lambda p: (not p.is_active, not p.is_builtin, p.name.lower()))

    async def get_persona(
        self, user_email: str, platform: str, persona_id: str, language: str = "zh"
    ) -> Optional[PersonaItem]:
        active = await self._get_active_ref(user_email, platform)
        user_doc = await self.user_col.find_one(
            {"user_email": user_email, "persona_id": persona_id},
            {"_id": 0, "user_email": 0},
        )
        if user_doc:
            return _doc_to_item(user_doc, is_builtin=False, active_ref=active)

        builtin_doc = await self.builtin_col.find_one(_builtin_available_filter(persona_id=persona_id), {"_id": 0})
        if builtin_doc:
            return _doc_to_item(
                builtin_doc, is_builtin=True, active_ref=active, redact_prompts=True, language=language
            )
        return None

    async def get_active_prompts(self, user_email: str, platform: str) -> Optional[PersonaPrompts]:
        active = await self._get_active_ref(user_email, platform)
        if not active:
            return None

        if active["source"] == SOURCE_BUILTIN:
            doc = await self.builtin_col.find_one(
                _builtin_available_filter(persona_id=active["persona_id"]),
                {"_id": 0, "prompts": 1},
            )
        else:
            doc = await self.user_col.find_one(
                {"user_email": user_email, "persona_id": active["persona_id"]},
                {"_id": 0, "prompts": 1},
            )
        if not doc:
            await self.deactivate_all(user_email, platform)
            return None
        return PersonaPrompts(**doc.get("prompts", {}))

    async def create_persona(
        self, user_email: str, platform: str, req: PersonaCreateRequest
    ) -> PersonaItem:
        count = await self.user_col.count_documents({"user_email": user_email})
        if count >= PERSONA_MAX_COUNT:
            raise AppException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                "PERSONA_LIMIT_EXCEEDED",
                f"最多 {PERSONA_MAX_COUNT} 个人设",
            )

        persona_id = str(uuid.uuid4())
        cleaned = _clean_prompts(req.prompts)
        now = datetime.now(timezone.utc)
        doc = {
            "user_email": user_email,
            "persona_id": persona_id,
            "name": req.name.strip(),
            "description": req.description.strip() if req.description else None,
            "prompts": cleaned.model_dump(),
            "created_at": now,
            "updated_at": now,
        }
        await self.user_col.insert_one(doc)
        # 新建即带启用模块时，仅在当前端激活，不影响该用户其它端
        if _has_any_enabled(cleaned):
            await self._set_active(user_email, platform, SOURCE_USER, persona_id)

        logger.info(
            "Persona created: user=%s platform=%s id=%s name=%s",
            user_email, platform, persona_id, req.name,
        )
        return _doc_to_item(
            doc, is_builtin=False, active_ref=await self._get_active_ref(user_email, platform)
        )

    async def update_persona(
        self, user_email: str, platform: str, persona_id: str, req: PersonaUpdateRequest
    ) -> Optional[PersonaItem]:
        current = await self.user_col.find_one(
            {"user_email": user_email, "persona_id": persona_id},
            {"_id": 0, "persona_id": 1, "prompts": 1},
        )
        if not current:
            return None

        update: dict = {"updated_at": datetime.now(timezone.utc)}
        if req.name is not None:
            update["name"] = req.name.strip()
        if req.description is not None:
            update["description"] = req.description.strip() or None
        new_prompts = None
        if req.prompts is not None:
            new_prompts = _clean_prompts(req.prompts)
            update["prompts"] = new_prompts.model_dump()
        if len(update) == 1:
            return await self.get_persona(user_email, platform, persona_id)

        # 人设内容是全端共享配置；启用/停用导致的激活态切换只作用于当前端
        active = await self._get_active_ref(user_email, platform)
        if new_prompts:
            if _has_any_enabled(new_prompts):
                await self._set_active(user_email, platform, SOURCE_USER, persona_id)
            elif _is_active_ref(active, SOURCE_USER, persona_id):
                await self.deactivate_all(user_email, platform)

        result = await self.user_col.find_one_and_update(
            {"user_email": user_email, "persona_id": persona_id},
            {"$set": update},
            return_document=True,
            projection={"_id": 0, "user_email": 0},
        )
        logger.info("Persona updated: user=%s platform=%s id=%s", user_email, platform, persona_id)
        return _doc_to_item(
            result, is_builtin=False, active_ref=await self._get_active_ref(user_email, platform)
        ) if result else None

    async def activate_persona(self, user_email: str, platform: str, persona_id: str) -> bool:
        user_doc = await self.user_col.find_one(
            {"user_email": user_email, "persona_id": persona_id},
            {"_id": 0, "prompts": 1},
        )
        if user_doc:
            prompts = _enable_configured_prompts(PersonaPrompts(**user_doc.get("prompts", {})))
            if not _has_any_enabled(prompts):
                return False
            await self.user_col.update_one(
                {"user_email": user_email, "persona_id": persona_id},
                {
                    "$set": {
                        "prompts": prompts.model_dump(),
                        "updated_at": datetime.now(timezone.utc),
                    }
                },
            )
            await self._set_active(user_email, platform, SOURCE_USER, persona_id)
            return True

        builtin_exists = await self.builtin_col.count_documents(_builtin_available_filter(persona_id=persona_id))
        if builtin_exists:
            await self._set_active(user_email, platform, SOURCE_BUILTIN, persona_id)
            return True
        return False

    async def deactivate_all(self, user_email: str, platform: str) -> None:
        """取消当前端的激活：只清除本端激活指针。

        激活态逐端隔离，故这里绝不改动 user_personas 上的 enabled 配置——那是全端
        共享的人设配置，若在此处置 False 会泄漏到仍指向该人设的其它端。指针清除后，
        本端的语音识别自然回退到内置提示词。
        """
        await self.state_col.delete_one({"user_email": user_email, "platform": platform})
        logger.info("Personas deactivated: user=%s platform=%s", user_email, platform)

    async def delete_persona(self, user_email: str, platform: str, persona_id: str) -> bool:
        result = await self.user_col.delete_one(
            {"user_email": user_email, "persona_id": persona_id}
        )
        if not result.deleted_count:
            return False
        # 人设全端共享，删除后需清掉该用户所有端指向它的激活指针
        await self.state_col.delete_many(
            {"user_email": user_email, "source": SOURCE_USER, "persona_id": persona_id}
        )
        logger.info("Persona deleted: user=%s id=%s", user_email, persona_id)
        return True

    async def list_builtin_personas(self) -> list[PersonaItem]:
        docs = await self.builtin_col.find({}, {"_id": 0}).sort(
            [("created_at", -1)]
        ).to_list(length=None)
        return [_doc_to_item(doc, is_builtin=True, active_ref=None) for doc in docs]

    async def create_builtin_persona(self, req: BuiltinPersonaCreateRequest) -> PersonaItem:
        persona_id = str(uuid.uuid4())
        cleaned = _clean_prompts(req.prompts, enable_when_present=True)
        now = datetime.now(timezone.utc)
        doc = {
            "persona_id": persona_id,
            "localized_names": _clean_i18n(req.localized_names.model_dump(by_alias=True)),
            "localized_descriptions": _clean_i18n(req.localized_descriptions.model_dump(by_alias=True)),
            "prompts": cleaned.model_dump(),
            "is_enabled": False,
            "created_at": now,
            "updated_at": now,
        }
        await self.builtin_col.insert_one(doc)
        logger.info("Builtin persona created: id=%s", persona_id)
        return _doc_to_item(doc, is_builtin=True, active_ref=None)

    async def update_builtin_persona(
        self, persona_id: str, req: BuiltinPersonaUpdateRequest
    ) -> Optional[PersonaItem]:
        update: dict = {"updated_at": datetime.now(timezone.utc)}
        if req.localized_names is not None:
            update["localized_names"] = _clean_i18n(req.localized_names.model_dump(by_alias=True))
        if req.localized_descriptions is not None:
            update["localized_descriptions"] = _clean_i18n(req.localized_descriptions.model_dump(by_alias=True))
        if req.prompts is not None:
            update["prompts"] = _clean_prompts(req.prompts, enable_when_present=True).model_dump()
        if len(update) == 1:
            doc = await self.builtin_col.find_one({"persona_id": persona_id}, {"_id": 0})
            return _doc_to_item(doc, is_builtin=True, active_ref=None) if doc else None

        result = await self.builtin_col.find_one_and_update(
            {"persona_id": persona_id},
            {"$set": update},
            return_document=True,
            projection={"_id": 0},
        )
        logger.info("Builtin persona updated: id=%s", persona_id)
        return _doc_to_item(result, is_builtin=True, active_ref=None) if result else None

    async def delete_builtin_persona(self, persona_id: str) -> bool:
        result = await self.builtin_col.delete_one({"persona_id": persona_id})
        if not result.deleted_count:
            return False
        await self.state_col.delete_many({"source": SOURCE_BUILTIN, "persona_id": persona_id})
        logger.info("Builtin persona deleted: id=%s", persona_id)
        return True

    async def _get_active_ref(self, user_email: str, platform: str) -> Optional[dict]:
        doc = await self.state_col.find_one(
            {"user_email": user_email, "platform": platform}, {"_id": 0}
        )
        if not doc:
            return None
        source = doc.get("source")
        persona_id = doc.get("persona_id")
        if source not in (SOURCE_USER, SOURCE_BUILTIN) or not persona_id:
            return None
        if source == SOURCE_BUILTIN:
            exists = await self.builtin_col.count_documents(_builtin_available_filter(persona_id=persona_id))
            if not exists:
                await self.deactivate_all(user_email, platform)
                logger.info(
                    "Disabled builtin persona state cleared lazily: user=%s platform=%s id=%s",
                    user_email,
                    platform,
                    persona_id,
                )
                return None
        return {"source": source, "persona_id": persona_id}

    async def _set_active(self, user_email: str, platform: str, source: str, persona_id: str) -> None:
        now = datetime.now(timezone.utc)
        await self.state_col.update_one(
            {"user_email": user_email, "platform": platform},
            {
                "$set": {
                    "user_email": user_email,
                    "platform": platform,
                    "source": source,
                    "persona_id": persona_id,
                    "updated_at": now,
                },
                "$setOnInsert": {"created_at": now},
            },
            upsert=True,
        )


def _clean(val: Optional[str]) -> Optional[str]:
    if val is None:
        return None
    s = val.strip()
    return s if s else None


def _clean_prompts(p: PersonaPrompts, *, enable_when_present: bool = False) -> PersonaPrompts:
    t = _clean(p.transcribe_prompt)
    r = _clean(p.rewrite_prompt)
    i = _clean(p.intent_hint)
    return PersonaPrompts(
        transcribe_prompt=t, transcribe_enabled=bool(t) and (enable_when_present or p.transcribe_enabled),
        rewrite_prompt=r, rewrite_enabled=bool(r) and (enable_when_present or p.rewrite_enabled),
        intent_hint=i, intent_enabled=bool(i) and (enable_when_present or p.intent_enabled),
    )


def _enable_configured_prompts(p: PersonaPrompts) -> PersonaPrompts:
    return PersonaPrompts(
        transcribe_prompt=p.transcribe_prompt,
        transcribe_enabled=bool(_clean(p.transcribe_prompt)),
        rewrite_prompt=p.rewrite_prompt,
        rewrite_enabled=bool(_clean(p.rewrite_prompt)),
        intent_hint=p.intent_hint,
        intent_enabled=bool(_clean(p.intent_hint)),
    )


# persona 文案本地化统一委托 core.content_i18n(persona/plan 等共享同一套 i18n 机制)。
# 保留下列薄封装以维持既有函数名(personas.py 等按名引用)。
def _clean_i18n(values: dict) -> dict:
    return clean_i18n(values)


def normalize_persona_language(language: Optional[str]) -> str:
    return normalize_language(language)


def _localized_text(doc: dict, field: str, language: str) -> Optional[str]:
    fallback = doc.get("name") if field == "localized_names" else doc.get("description")
    return localized_text(doc.get(field), language, fallback=fallback)


def _has_any_enabled(p: PersonaPrompts) -> bool:
    return p.transcribe_enabled or p.rewrite_enabled or p.intent_enabled


def _is_active_ref(active_ref: Optional[dict], source: str, persona_id: str) -> bool:
    return bool(
        active_ref
        and active_ref.get("source") == source
        and active_ref.get("persona_id") == persona_id
    )


def _doc_to_item(
    doc: dict,
    *,
    is_builtin: bool,
    active_ref: Optional[dict],
    redact_prompts: bool = False,
    language: str = "zh",
) -> PersonaItem:
    source = SOURCE_BUILTIN if is_builtin else SOURCE_USER
    name = _localized_text(doc, "localized_names", language) if is_builtin else doc["name"]
    return PersonaItem(
        id=doc["persona_id"],
        name=name or doc.get("name") or "",
        description=_localized_text(doc, "localized_descriptions", language) if is_builtin else doc.get("description"),
        is_active=_is_active_ref(active_ref, source, doc["persona_id"]),
        is_builtin=is_builtin,
        is_enabled=bool(doc.get("is_enabled", True)) if is_builtin else True,
        prompts=PersonaPrompts() if redact_prompts else PersonaPrompts(**doc.get("prompts", {})),
    )
