import logging
from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase
from app.core.config import settings

logger = logging.getLogger(__name__)

_client: AsyncIOMotorClient = None


async def connect_db():
    global _client
    _client = AsyncIOMotorClient(settings.MONGODB_URI)
    logger.info("MongoDB connected")


async def close_db():
    global _client
    if _client:
        _client.close()
        logger.info("MongoDB disconnected")


def get_main_db() -> AsyncIOMotorDatabase:
    return _client[settings.MONGODB_DB_NAME]


def get_admin_db() -> AsyncIOMotorDatabase:
    return _client[settings.ADMIN_DB_NAME]
