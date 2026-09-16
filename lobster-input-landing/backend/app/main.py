"""官网后端入口（FastAPI）。

对外路径形如 https://example.com/lobster/site/api/v1/...，Nginx 把
/lobster/site 前缀 rewrite 掉后转发到本服务（端口 8891），因此内部路由全部
挂在 /api/v1/... 下，与管理端 lobster-input-admin 的模式一致。

官网与主后端共享同一个 MongoDB，但自管会话、自管登录态。所有集合的索引由
主后端在共享库上建立，本服务只读写既有集合，不重复建索引。
"""
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.core.config import settings
from app.core.database import connect_db, close_db
from app.core.errors import AppError, app_error_handler
from app.api.v1 import health, auth, config, account, agreements

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("lobster_landing")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await connect_db()
    logger.info("Lobster Landing API started")
    yield
    await close_db()


app = FastAPI(
    title="Lobster Landing API",
    description="龙虾输入法官网后端（前后端分离）",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/api/docs" if settings.EXPOSE_API_DOCS else None,
    redoc_url=None,
)

app.add_exception_handler(AppError, app_error_handler)

app.include_router(health.router)
app.include_router(auth.router)
app.include_router(config.router)
app.include_router(account.router)
app.include_router(agreements.router)
