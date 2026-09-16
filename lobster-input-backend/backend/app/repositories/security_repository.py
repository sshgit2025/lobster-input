"""
安全风控数据访问层。
记录对外接口的限流、临时封禁和攻击特征，供管理端排查。
"""
import math
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

from pymongo import ReturnDocument
from pymongo.errors import DuplicateKeyError

from app.core.database import get_db

IDENTITIES_COLLECTION = "security_identities"
EVENTS_COLLECTION = "security_events"
COUNTERS_COLLECTION = "security_counters"
ACCOUNT_IP_SEEN_COLLECTION = "security_account_ip_seen"
COOLDOWNS_COLLECTION = "security_cooldowns"


class SecurityRepository:
    """风控仓库，负责短窗口计数、身份状态和攻击事件。"""

    @property
    def identities_col(self):
        return get_db()[IDENTITIES_COLLECTION]

    @property
    def events_col(self):
        return get_db()[EVENTS_COLLECTION]

    @property
    def counters_col(self):
        return get_db()[COUNTERS_COLLECTION]

    @property
    def account_ip_seen_col(self):
        return get_db()[ACCOUNT_IP_SEEN_COLLECTION]

    @property
    def cooldowns_col(self):
        return get_db()[COOLDOWNS_COLLECTION]

    async def ensure_indexes(self) -> None:
        await self.identities_col.create_index(
            [("identity_type", 1), ("identity_value", 1)],
            unique=True,
        )
        await self.identities_col.create_index("status")
        await self.identities_col.create_index("user_email")
        await self.identities_col.create_index([("last_seen_at", -1)])
        await self.events_col.create_index([("created_at", -1)])
        await self.events_col.create_index("user_email")
        await self.events_col.create_index("ip")
        await self.events_col.create_index("reason_code")
        await self.events_col.create_index("action")
        await self.counters_col.create_index(
            [("scope", 1), ("key", 1), ("path_group", 1), ("bucket", 1)],
            unique=True,
        )
        await self.counters_col.create_index("expires_at", expireAfterSeconds=0)
        await self.account_ip_seen_col.create_index(
            [("user_email", 1), ("ip", 1)],
            unique=True,
        )
        await self.account_ip_seen_col.create_index([("user_email", 1), ("last_seen_at", -1)])
        await self.account_ip_seen_col.create_index("expires_at", expireAfterSeconds=0)
        await self.cooldowns_col.create_index("key", unique=True)
        await self.cooldowns_col.create_index("expires_at", expireAfterSeconds=0)

    async def hit_counter(
        self,
        *,
        scope: str,
        key: str,
        path_group: str,
        window_seconds: int,
    ) -> int:
        now = datetime.now(timezone.utc)
        bucket_start = int(now.timestamp() // window_seconds) * window_seconds
        result = await self.counters_col.find_one_and_update(
            {
                "scope": scope,
                "key": key,
                "path_group": path_group,
                "bucket": bucket_start,
            },
            {
                "$inc": {"count": 1},
                "$set": {"updated_at": now},
                "$setOnInsert": {
                    "created_at": now,
                    "expires_at": now + timedelta(seconds=window_seconds + 120),
                },
            },
            upsert=True,
            return_document=ReturnDocument.AFTER,
        )
        return int(result.get("count", 0)) if result else 0

    async def acquire_cooldown_slot(self, *, key: str, cooldown_seconds: int) -> int:
        """
        原子获取一个冷却发送许可（滑动窗口）。

        返回值：
          - 0  ：获取成功，本次允许发送（已写入/刷新冷却记录，有效期 cooldown_seconds 秒）
          - >0 ：仍处于冷却期，返回剩余等待秒数（向上取整，最小 1）

        实现：以 key 唯一索引 + 带 TTL 的记录，通过“仅匹配已过期记录”的条件 upsert
        保证并发下同一 key 在冷却期内只有一次能成功写入。
        """
        now = datetime.now(timezone.utc)
        try:
            await self.cooldowns_col.find_one_and_update(
                {"key": key, "expires_at": {"$lte": now}},
                {
                    "$set": {
                        "key": key,
                        "created_at": now,
                        "expires_at": now + timedelta(seconds=cooldown_seconds),
                    }
                },
                upsert=True,
                return_document=ReturnDocument.AFTER,
            )
            return 0
        except DuplicateKeyError:
            doc = await self.cooldowns_col.find_one({"key": key})
            if not doc:
                return cooldown_seconds
            expires_at = doc["expires_at"]
            # Motor 默认读回 naive UTC datetime，补上时区以便与 aware now 相减
            if expires_at.tzinfo is None:
                expires_at = expires_at.replace(tzinfo=timezone.utc)
            remaining = (expires_at - now).total_seconds()
            return max(1, int(math.ceil(remaining)))

    async def touch_identity(
        self,
        *,
        user_email: Optional[str],
        ip: str,
        user_agent: str,
    ) -> None:
        now = datetime.now(timezone.utc)
        await self._upsert_identity(
            identity_type="ip",
            identity_value=ip,
            user_email=user_email,
            ip=ip,
            user_agent=user_agent,
            now=now,
        )
        if user_email:
            await self._upsert_identity(
                identity_type="account",
                identity_value=user_email,
                user_email=user_email,
                ip=ip,
                user_agent=user_agent,
                now=now,
            )
            await self._touch_account_ip_seen(
                user_email=user_email,
                ip=ip,
                user_agent=user_agent,
                now=now,
            )

    async def get_active_restriction(
        self,
        *,
        user_email: Optional[str],
        ip: str,
    ) -> Optional[dict[str, Any]]:
        now = datetime.now(timezone.utc)
        candidates = [
            {"identity_type": "ip", "identity_value": ip},
        ]
        if user_email:
            candidates.append({"identity_type": "account", "identity_value": user_email})
        doc = await self.identities_col.find_one({
            "$and": [
                {"$or": candidates},
                {"status": {"$in": ["limited", "blocked"]}},
                {"$or": [
                    {"limited_until": {"$gt": now}},
                    {"blocked_until": {"$gt": now}},
                ]},
            ],
        })
        return doc

    async def record_event(
        self,
        *,
        user_email: Optional[str],
        ip: str,
        method: str,
        path: str,
        reason_code: str,
        reason_label: str,
        severity: str,
        action: str,
        window_seconds: int,
        request_count: int,
        user_agent: str,
        status_code: Optional[int] = None,
    ) -> None:
        now = datetime.now(timezone.utc)
        until = self._action_until(action, now)
        event = {
            "user_email": user_email,
            "ip": ip,
            "method": method,
            "path": path,
            "reason_code": reason_code,
            "reason_label": reason_label,
            "severity": severity,
            "action": action,
            "window_seconds": window_seconds,
            "request_count": request_count,
            "status_code": status_code,
            "user_agent": user_agent,
            "created_at": now,
        }
        await self.events_col.insert_one(event)
        await self._apply_action(
            identity_type="ip",
            identity_value=ip,
            user_email=user_email,
            ip=ip,
            reason_code=reason_code,
            action=action,
            severity=severity,
            until=until,
            now=now,
            user_agent=user_agent,
        )
        if user_email:
            await self._apply_action(
                identity_type="account",
                identity_value=user_email,
                user_email=user_email,
                ip=ip,
                reason_code=reason_code,
                action=action,
                severity=severity,
                until=until,
                now=now,
                user_agent=user_agent,
            )

    async def count_account_ips(
        self,
        *,
        user_email: str,
        window_seconds: int,
    ) -> int:
        since = datetime.now(timezone.utc) - timedelta(seconds=window_seconds)
        return int(await self.account_ip_seen_col.count_documents({
            "user_email": user_email,
            "last_seen_at": {"$gte": since},
        }))

    async def get_account_ip_count(self, user_email: str) -> int:
        doc = await self.identities_col.find_one(
            {"identity_type": "account", "identity_value": user_email},
            {"ips": 1},
        )
        return len(doc.get("ips", [])) if doc else 0

    @staticmethod
    def _risk_delta(severity: str) -> int:
        return {"low": 1, "medium": 3, "high": 8, "critical": 20}.get(severity, 1)

    @staticmethod
    def _action_until(action: str, now: datetime) -> Optional[datetime]:
        if action == "limited":
            return now + timedelta(minutes=15)
        if action == "blocked":
            return now + timedelta(hours=1)
        return None

    async def _upsert_identity(
        self,
        *,
        identity_type: str,
        identity_value: str,
        user_email: Optional[str],
        ip: str,
        user_agent: str,
        now: datetime,
    ) -> None:
        update: dict[str, Any] = {
            "$set": {
                "last_seen_at": now,
                "last_user_agent": user_agent,
            },
            "$setOnInsert": {
                "identity_type": identity_type,
                "identity_value": identity_value,
                "status": "normal",
                "risk_score": 0,
                "first_seen_at": now,
                "limited_until": None,
                "blocked_until": None,
                "reasons": [],
            },
            "$addToSet": {"ips": ip},
        }
        if user_email:
            update["$set"]["user_email"] = user_email
            update["$addToSet"]["user_emails"] = user_email
        await self.identities_col.update_one(
            {"identity_type": identity_type, "identity_value": identity_value},
            update,
            upsert=True,
        )

    async def _touch_account_ip_seen(
        self,
        *,
        user_email: str,
        ip: str,
        user_agent: str,
        now: datetime,
    ) -> None:
        await self.account_ip_seen_col.update_one(
            {"user_email": user_email, "ip": ip},
            {
                "$set": {
                    "last_seen_at": now,
                    "last_user_agent": user_agent,
                    "expires_at": now + timedelta(hours=1),
                },
                "$setOnInsert": {
                    "created_at": now,
                },
            },
            upsert=True,
        )

    async def _apply_action(
        self,
        *,
        identity_type: str,
        identity_value: str,
        user_email: Optional[str],
        ip: str,
        reason_code: str,
        action: str,
        severity: str,
        until: Optional[datetime],
        now: datetime,
        user_agent: str,
    ) -> None:
        await self._upsert_identity(
            identity_type=identity_type,
            identity_value=identity_value,
            user_email=user_email,
            ip=ip,
            user_agent=user_agent,
            now=now,
        )
        set_fields: dict[str, Any] = {
            "status": action if action in ("limited", "blocked") else "normal",
            "last_reason": reason_code,
            "last_action": action,
            "last_seen_at": now,
        }
        if action == "limited":
            set_fields["limited_until"] = until
        if action == "blocked":
            set_fields["blocked_until"] = until
        await self.identities_col.update_one(
            {"identity_type": identity_type, "identity_value": identity_value},
            {
                "$inc": {"risk_score": self._risk_delta(severity)},
                "$set": set_fields,
                "$addToSet": {
                    "reasons": reason_code,
                    "ips": ip,
                    **({"user_emails": user_email} if user_email else {}),
                },
            },
        )
