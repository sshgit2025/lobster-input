"""
CreditLedgerRepository — 积分账本 MongoDB 数据访问层。

集合：credit_ledger
每条记录对应一次请求的完整积分扣减信息，含各平台 breakdown。
"""
import logging
from pymongo import ASCENDING, DESCENDING
from pymongo.errors import DuplicateKeyError
from app.core.database import get_db
from app.data.credits.models import CreditLedgerEntry

logger = logging.getLogger("voice_input.credits.repository")

_COLLECTION = "credit_ledger"


class CreditLedgerRepository:

    def _col(self):
        return get_db()[_COLLECTION]

    async def ensure_indexes(self) -> None:
        col = self._col()
        await col.create_index(
            [("user_email", ASCENDING), ("created_at", DESCENDING)],
            name="ledger_user_time",
        )
        await col.create_index(
            [("date", DESCENDING)],
            name="ledger_date",
        )
        await col.create_index(
            [("idempotency_key", ASCENDING)],
            name="ledger_idempotency_key",
            unique=True,
            partialFilterExpression={"idempotency_key": {"$exists": True, "$gt": ""}},
        )
        logger.info("CreditLedgerRepository: indexes ensured.")

    async def insert(self, entry: CreditLedgerEntry) -> bool:
        col = self._col()
        try:
            await col.insert_one(entry.to_dict())
        except DuplicateKeyError:
            return False
        return True
