import asyncio
import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from app.core.config import settings
from app.core.database import connect_db, close_db, get_db
from app.core.init_admin import init_admin_account
from app.repositories.api_key_repository import ApiKeyRepository
from app.repositories.admin_repository import AdminRepository
from app.api.v1 import auth, keys, pool, stats, pages

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger(__name__)

_quota_reset_task = None


async def _quota_auto_reset_loop():
    """每小时扫描一次，执行到期额度自动重置。"""
    while True:
        await asyncio.sleep(3600)
        try:
            db = get_db()
            repo = ApiKeyRepository(db)
            count = await repo.run_auto_reset()
            if count > 0:
                logger.info("Quota auto reset: %d dimensions reset", count)
        except Exception as e:
            logger.error("Quota auto reset error: %s", e)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _quota_reset_task
    await connect_db()
    try:
        db = get_db()
        await db.command("ping")
        logger.info("MongoDB ping ok")
        await init_admin_account()
        repo = ApiKeyRepository(db)
        await repo.ensure_indexes(seed_default_catalog=settings.SEED_DEFAULT_CATALOG)
        await AdminRepository(db).ensure_indexes()
        init_count = await repo.init_last_reset_at()
        if init_count > 0:
            logger.info("Initialized last_reset_at for %d quota dimensions", init_count)
        logger.info("Database indexes ensured")
    except Exception as e:
        logger.error("MongoDB init failed: %s (will retry on first request)", e)

    _quota_reset_task = asyncio.create_task(_quota_auto_reset_loop())
    logger.info("Quota auto reset task started")
    yield
    if _quota_reset_task:
        _quota_reset_task.cancel()
    await close_db()


app = FastAPI(
    title="Lobster API Pool Manager",
    description="API Key 号池管理平台",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/api/docs" if settings.EXPOSE_API_DOCS else None,
    redoc_url=None,
)

app.mount(
    "/static",
    StaticFiles(directory="app/static"),
    name="static",
)

app.include_router(pages.router)
app.include_router(auth.router)
app.include_router(keys.router)
app.include_router(pool.router)
app.include_router(stats.router)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "api-pool-manager"}
