from datetime import datetime
from typing import List, Optional
from motor.motor_asyncio import AsyncIOMotorDatabase


ACCOUNT_EMAIL_QUERY = {
    "$type": "string",
    "$regex": r"^[^@\s]+@[^@\s]+\.[^@\s]+$",
}


def _fmt_utc(dt) -> str:
    """将 datetime 对象格式化为带 Z 的 ISO 字符串，确保前端能正确识别为 UTC。"""
    if isinstance(dt, datetime):
        return dt.strftime("%Y-%m-%dT%H:%M:%S.%f") + "Z"
    return str(dt) if dt else ""


class StatsRepository:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.col = db["usage_stats"]

    async def count(self, query: dict) -> int:
        return await self.col.count_documents(query)

    async def find_paginated(self, query: dict, page: int, page_size: int) -> List[dict]:
        skip = (page - 1) * page_size
        # 优先按 created_at 倒排（精确时间），其次按 date + _id 兜底
        cursor = self.col.find(query).sort(
            [("created_at", -1), ("date", -1), ("_id", -1)]
        ).skip(skip).limit(page_size)
        items = await cursor.to_list(length=page_size)
        for item in items:
            if "created_at" in item:
                item["created_at"] = _fmt_utc(item["created_at"])
            if "updated_at" in item:
                item["updated_at"] = _fmt_utc(item["updated_at"])
        return items

    async def get_summary(self, query: dict = None) -> dict:
        pipeline = []
        if query:
            pipeline.append({"$match": query})
        pipeline.append({"$group": {
            "_id": None,
            "total_requests": {"$sum": "$request_count"},
            "total_input_tokens": {"$sum": "$input_tokens"},
            "total_output_tokens": {"$sum": "$output_tokens"},
            "total_audio_sec": {"$sum": "$audio_duration_sec"},
            "total_search": {"$sum": "$search_count"},
        }})
        result = await self.col.aggregate(pipeline).to_list(length=1)
        if not result:
            return {
                "total_requests": 0, "total_input_tokens": 0,
                "total_output_tokens": 0, "total_audio_sec": 0,
                "total_search": 0,
            }
        data = result[0]
        data.pop("_id", None)
        return data

    async def get_daily_requests(self, days: int = 30) -> List[dict]:
        pipeline = [
            {"$group": {
                "_id": "$date",
                "request_count": {"$sum": "$request_count"},
                "input_tokens": {"$sum": "$input_tokens"},
                "output_tokens": {"$sum": "$output_tokens"},
            }},
            {"$sort": {"_id": -1}},
            {"$limit": days}
        ]
        return await self.col.aggregate(pipeline).to_list(length=days)

    async def get_platform_distribution(self) -> List[dict]:
        pipeline = [
            {"$group": {"_id": "$platform", "count": {"$sum": "$request_count"}}},
            {"$sort": {"count": -1}}
        ]
        return await self.col.aggregate(pipeline).to_list(length=20)

    async def get_top_users(self, limit: int = 10) -> List[dict]:
        pipeline = [
            {"$match": {"user_email": ACCOUNT_EMAIL_QUERY}},
            {"$group": {
                "_id": "$user_email",
                "total_requests": {"$sum": "$request_count"},
                "total_tokens": {"$sum": {"$add": ["$input_tokens", "$output_tokens"]}},
            }},
            {"$sort": {"total_requests": -1}},
            {"$limit": limit}
        ]
        return await self.col.aggregate(pipeline).to_list(length=limit)

    async def get_api_key_stats(self, query: dict = None) -> List[dict]:
        pipeline = []
        if query:
            pipeline.append({"$match": query})
        pipeline += [
            {"$group": {
                "_id": "$api_key_hint",
                "total_requests": {"$sum": "$request_count"},
                "total_input_tokens": {"$sum": "$input_tokens"},
                "total_output_tokens": {"$sum": "$output_tokens"},
                "total_audio_sec": {"$sum": "$audio_duration_sec"},
                "total_search": {"$sum": "$search_count"},
                "total_latency_ms": {"$sum": "$latency_ms"},
                "user_count": {"$addToSet": "$user_email"},
            }},
            {"$project": {
                "_id": 1,
                "total_requests": 1,
                "total_input_tokens": 1,
                "total_output_tokens": 1,
                "total_audio_sec": 1,
                "total_search": 1,
                "total_latency_ms": 1,
                "user_count": {"$size": "$user_count"},
            }},
            {"$sort": {"total_requests": -1}},
        ]
        return await self.col.aggregate(pipeline).to_list(length=200)
