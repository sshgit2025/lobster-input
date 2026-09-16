"""OrderRepository — 共享主库 subscription_purchase_events 集合（官网订单只读）。

主后端没有对外的订单历史查询接口，订单真实数据落在 subscription_purchase_events。
官网个人中心据此展示用户的订阅支付订单明细与状态；只读，不提供退款入口，
并屏蔽支付渠道内部 id 等敏感字段。
"""
from pymongo import DESCENDING
from app.core.database import get_db

COLLECTION = "subscription_purchase_events"

# 屏蔽敏感/内部字段
SAFE_PROJECTION = {
    "_id": 0,
    "raw_event": 0,
    "provider_payment_id": 0,
    "payment_event_id": 0,
    "previous_subscription": 0,
}


class OrderRepository:
    @property
    def col(self):
        return get_db()[COLLECTION]

    async def list_by_user(self, user_email: str, limit: int = 100) -> list[dict]:
        cursor = (
            self.col.find({"user_email": user_email}, SAFE_PROJECTION)
            .sort("created_at", DESCENDING)
            .limit(limit)
        )
        return await cursor.to_list(length=limit)
