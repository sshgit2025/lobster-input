"""
LedgerRepository — 积分账本数据访问层（管理端）。

查询 credit_ledger 集合，支持分页和汇总统计。
"""
from typing import List, Optional
from motor.motor_asyncio import AsyncIOMotorDatabase


CONSUMPTION_OPERATIONS = ("transcribe", "rewrite", "agent")
UNALLOCATED_PLATFORM = "unallocated"


def with_consumption_filter(query: Optional[dict] = None) -> dict:
    """默认只统计真实消耗，奖励/赠送类记录需显式按 operation 查询。"""
    q = dict(query or {})
    q.setdefault("operation", {"$in": list(CONSUMPTION_OPERATIONS)})
    return q


class LedgerRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["credit_ledger"]

    async def count(self, query: dict) -> int:
        return await self.col.count_documents(query)

    async def find_paginated(self, query: dict, page: int, page_size: int) -> List[dict]:
        skip = (page - 1) * page_size
        cursor = self.col.find(query).sort("created_at", -1).skip(skip).limit(page_size)
        return await cursor.to_list(length=page_size)

    async def get_daily_credits(self, days: int = 30) -> List[dict]:
        """近 N 天每日积分消耗趋势。"""
        pipeline = [
            {"$match": with_consumption_filter()},
            {"$group": {
                "_id": "$date",
                "total_credits": {"$sum": "$total_credits"},
                "record_count": {"$sum": 1},
            }},
            {"$sort": {"_id": -1}},
            {"$limit": days},
        ]
        return await self.col.aggregate(pipeline).to_list(length=days)

    async def get_platform_breakdown(self, query: Optional[dict] = None) -> List[dict]:
        """各平台积分消耗占比（展开 breakdown 数组聚合）。"""
        match = {"$match": with_consumption_filter(query)}
        pipeline = [match]
        pipeline += [
            {"$unwind": "$breakdown"},
            {"$group": {
                "_id": "$breakdown.platform",
                "total_credits": {"$sum": "$breakdown.credits"},
            }},
            {"$sort": {"total_credits": -1}},
        ]
        data = await self.col.aggregate(pipeline).to_list(length=50)
        missing = await self.col.aggregate([
            match,
            {"$project": {
                "missing": {"$subtract": ["$total_credits", {"$sum": "$breakdown.credits"}]},
            }},
            {"$match": {"missing": {"$gt": 0}}},
            {"$group": {"_id": UNALLOCATED_PLATFORM, "total_credits": {"$sum": "$missing"}}},
        ]).to_list(length=1)
        data.extend(missing)
        data.sort(key=lambda item: item["total_credits"], reverse=True)
        return data

    async def get_top_users(self, limit: int = 10, query: Optional[dict] = None) -> List[dict]:
        """积分消耗 Top 用户。"""
        pipeline = [{"$match": with_consumption_filter(query)}]
        pipeline += [
            {"$group": {
                "_id": "$user_email",
                "total_credits": {"$sum": "$total_credits"},
                "record_count": {"$sum": 1},
            }},
            {"$sort": {"total_credits": -1}},
            {"$limit": limit},
        ]
        return await self.col.aggregate(pipeline).to_list(length=limit)

    async def get_summary(self, query: Optional[dict] = None) -> dict:
        pipeline = [{"$match": with_consumption_filter(query)}]
        pipeline.append({"$group": {
            "_id": None,
            "total_credits": {"$sum": "$total_credits"},
            "total_records": {"$sum": 1},
        }})
        result = await self.col.aggregate(pipeline).to_list(length=1)
        if not result:
            return {"total_credits": 0, "total_records": 0}
        data = result[0]
        data.pop("_id", None)
        return data
