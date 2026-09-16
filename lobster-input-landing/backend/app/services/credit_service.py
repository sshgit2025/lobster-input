"""CreditService — 奖励积分发放（与主后端 CreditAccountService 的 grant 子集一致）。

注册奖励 / 邀请奖励均由 system_config.bonus_credit_policy 控制是否发放、发放多少、
有效期多少天；用幂等键防重复发放。
"""
from datetime import datetime, timedelta, timezone

from app.repositories.system_config_repository import SystemConfigRepository
from app.repositories.credit_grant_repository import CreditGrantRepository, BONUS_CREDIT_TYPE


class CreditService:
    def __init__(self):
        self.config_repo = SystemConfigRepository()
        self.grant_repo = CreditGrantRepository()

    async def grant_bonus(
        self,
        email: str,
        amount: int,
        source: str,
        expires_days: int | None = None,
        idempotency_key: str = "",
    ) -> bool:
        expires_at = datetime.now(timezone.utc) + timedelta(days=max(1, int(expires_days or 365)))
        return await self.grant_repo.grant(
            email, amount, source, expires_at, None, BONUS_CREDIT_TYPE, idempotency_key
        )

    async def grant_by_policy(self, email: str, source: str, idempotency_key: str = "") -> int:
        policy = await self.config_repo.get_bonus_credit_policy()
        cfg = policy.get(source, {})
        if not cfg.get("enabled", False):
            return 0
        amount = int(cfg.get("credits", 0) or 0)
        if amount <= 0:
            return 0
        created = await self.grant_bonus(
            email, amount, source, int(cfg.get("expires_days", 0) or 0), idempotency_key=idempotency_key
        )
        return amount if (created or idempotency_key) else 0
