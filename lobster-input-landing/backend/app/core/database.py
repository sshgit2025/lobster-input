"""MongoDB 连接管理（共享主库 voice_input，与后端/管理端同库）。"""
import logging
from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase
from app.core.config import settings

logger = logging.getLogger("lobster_landing.db")

_client: AsyncIOMotorClient | None = None


async def connect_db() -> None:
    global _client
    _client = AsyncIOMotorClient(settings.MONGODB_URI)
    logger.info("MongoDB connected (db=%s)", settings.MONGODB_DB_NAME)


async def close_db() -> None:
    global _client
    if _client:
        _client.close()
        logger.info("MongoDB disconnected")


def get_db() -> AsyncIOMotorDatabase:
    if _client is None:
        raise RuntimeError("MongoDB client not initialized; call connect_db() first")
    return _client[settings.MONGODB_DB_NAME]
