import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.api.v1 import router as v1_router
from app.core.config import settings
from app.core.database import close_db, connect_db, get_main_db
from app.services.webhook.ingest import ensure_indexes as ensure_webhook_event_indexes

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger(__name__)


async def _ensure_indexes() -> None:
    db = get_main_db()
    await db["payment_callback_events"].create_index("payment_event_id", unique=True)
    await db["payment_callback_events"].create_index([("provider", 1), ("provider_payment_id", 1)])
    await db["payment_callback_events"].create_index([("payment_order_id", 1), ("created_at", -1)])
    await db["payment_callback_events"].create_index([("user_email", 1), ("created_at", -1)])
    await db["payment_checkout_sessions"].create_index("request_id", unique=True)
    await db["payment_checkout_sessions"].create_index("checkout_id", unique=True, sparse=True)
    await db["payment_checkout_sessions"].create_index([("provider", 1), ("created_at", -1)])
    await db["payment_orders"].create_index("order_id", unique=True)
    await db["payment_orders"].create_index([("user_email", 1), ("created_at", -1)])
    await db["payment_orders"].create_index([("status", 1), ("created_at", -1)])
    await db["payment_attempts"].create_index("request_id", unique=True)
    await db["payment_attempts"].create_index([("order_id", 1), ("created_at", -1)])
    await db["payment_transactions"].create_index([("order_id", 1), ("created_at", -1)])
    await db["payment_refunds"].create_index("refund_id", unique=True)
    await db["payment_refunds"].create_index([("order_id", 1), ("created_at", -1)])
    await db["subscription_refund_events"].create_index("refund_event_id", unique=True)
    await db["subscription_refund_events"].create_index("original_payment_event_id")
    await db["subscription_refund_events"].create_index([("provider", 1), ("provider_refund_id", 1)])
    await db["credit_grants"].create_index([("user_email", 1), ("credit_type", 1), ("status", 1)])
    await db["credit_grants"].create_index([("user_email", 1), ("credit_type", 1), ("expires_at", 1)])
    await db["credit_grants"].create_index([("user_email", 1), ("metadata.expires_at_mode", 1), ("status", 1)])
    await db["apple_iap_subscriptions"].create_index("original_transaction_id", unique=True)
    await db["apple_iap_subscriptions"].create_index([("user_email", 1), ("updated_at", -1)])
    await db["apple_iap_subscriptions"].create_index("app_account_token", sparse=True)
    # 计费目录域(catalog):plan/price 唯一键;lookup_key 每币种唯一指向在售版(空串不参与)
    await db["billing_plans"].create_index("plan_code", unique=True)
    await db["billing_prices"].create_index("price_id", unique=True)
    await db["billing_prices"].create_index([("plan_code", 1), ("period", 1), ("currency", 1), ("version", -1)])
    await db["billing_prices"].create_index(
        [("lookup_key", 1), ("currency", 1)],
        unique=True,
        partialFilterExpression={"lookup_key": {"$gt": ""}},
    )
    await db["catalog_publish_log"].create_index([("published_at", -1)])
    await ensure_webhook_event_indexes(db)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await connect_db()
    await _ensure_indexes()
    yield
    await close_db()


app = FastAPI(
    title="Lobster Payment",
    description="Lobster Input payment callback and subscription write service",
    version="0.1.0",
    lifespan=lifespan,
    docs_url="/api/docs" if settings.EXPOSE_API_DOCS else None,
    redoc_url=None,
)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "lobster-payment"}


app.include_router(v1_router)
