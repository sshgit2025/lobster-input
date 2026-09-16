import logging
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from app.core.config import settings
from app.core.database import connect_db, close_db, get_main_db, get_admin_db
from app.core.init_admin import init_admin_account
from app.api.v1 import (
    auth, users, invites, stats, ledger, config, pages, logs, agreements,
    user_dict, alerts, security, plans, feedback, personas, provider_config,
    payment_provider_config, apple_iap_config, billing_catalog_admin,
    billing_margin_admin,
)
from app.repositories.alert_repository import AlertRepository
from app.repositories.security_repository import SecurityRepository
from app.repositories.persona_repository import BuiltinPersonaRepository
from app.repositories.provider_config_repository import ProviderConfigRepository

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger(__name__)


async def _ensure_indexes() -> None:
    """确保集合索引存在（幂等）。"""
    col = get_main_db()["invite_codes"]
    await col.create_index("code", unique=True)
    await col.create_index("owner_email")
    await col.create_index("used_by")
    await AlertRepository(get_admin_db()).ensure_indexes()
    await SecurityRepository(get_main_db()).ensure_indexes()
    await BuiltinPersonaRepository(get_main_db()).ensure_indexes()
    await ProviderConfigRepository(get_main_db()).ensure_default()
    await get_main_db()["credit_grants"].create_index([("user_email", 1), ("credit_type", 1), ("status", 1)])
    await get_main_db()["credit_grants"].create_index([("user_email", 1), ("credit_type", 1), ("expires_at", 1)])
    await get_main_db()["credit_grants"].create_index([("user_email", 1), ("metadata.expires_at_mode", 1), ("status", 1)])
    await get_main_db()["payment_callback_events"].create_index("payment_event_id", unique=True)
    await get_main_db()["payment_callback_events"].create_index([("provider", 1), ("provider_payment_id", 1)])
    await get_main_db()["payment_callback_events"].create_index([("payment_order_id", 1), ("created_at", -1)])
    await get_main_db()["subscription_refund_events"].create_index("refund_event_id", unique=True)
    await get_main_db()["subscription_refund_events"].create_index("original_payment_event_id")
    await get_main_db()["subscription_refund_events"].create_index([("provider", 1), ("provider_refund_id", 1)])
    await get_main_db()["subscription_events"].create_index([("email", 1), ("created_at", -1)])
    await get_main_db()["user_feedback"].create_index([("status", 1), ("created_at", -1)])
    await get_main_db()["user_feedback"].create_index("user_email")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await connect_db()
    await init_admin_account()
    await _ensure_indexes()
    yield
    await close_db()


app = FastAPI(
    title="Lobster Admin",
    description="Lobster Input 管理后台",
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/api/docs" if settings.EXPOSE_API_DOCS else None,
    redoc_url=None,
)

app.mount("/static", StaticFiles(directory="app/static"), name="static")

app.include_router(pages.router)
app.include_router(auth.router)
app.include_router(users.router)
app.include_router(invites.router)
app.include_router(stats.router)
app.include_router(ledger.router)
app.include_router(config.router)
app.include_router(plans.router)
app.include_router(logs.router)
app.include_router(agreements.router)
app.include_router(user_dict.router)
app.include_router(alerts.router)
app.include_router(security.router)
app.include_router(feedback.router)
app.include_router(personas.router)
app.include_router(provider_config.router)
app.include_router(payment_provider_config.router)
app.include_router(apple_iap_config.router)
app.include_router(billing_catalog_admin.router)
app.include_router(billing_catalog_admin.webhook_router)
app.include_router(billing_margin_admin.router)
