import logging

from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase

from app.core.config import settings

logger = logging.getLogger(__name__)

_client: AsyncIOMotorClient | None = None


async def connect_db() -> None:
    global _client
    _client = AsyncIOMotorClient(settings.MONGODB_URI)
    logger.info("MongoDB connected")


async def close_db() -> None:
    global _client
    if _client:
        _client.close()
        _client = None
        logger.info("MongoDB disconnected")


def get_main_db() -> AsyncIOMotorDatabase:
    if _client is None:
        raise RuntimeError("Database not connected")
    return _client[settings.MONGODB_DB_NAME]

