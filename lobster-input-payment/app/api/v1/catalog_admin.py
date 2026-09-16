"""计费目录域(Catalog)管理接口 —— 计费域重构阶段 1。

挂载于 /api/v1/payments/admin/catalog,鉴权复用 payments.verify_callback_key
(X-API-Key + X-Callback-Timestamp + X-Callback-Signature HMAC 签名)。

catalog 只负责"价格"(billing_prices)与套餐的展示元数据(name/display);套餐定义
(可购性/积分/有效期/等级)的唯一真源是 system_config.plan_configs,由管理端 PlansView
编辑。/publish 只把在售价格物化为 system_config.payment_billing_config 一份投影
(不再触碰 plan_configs),现有读路径零改动。发布前请先 dry_run=true 查看 diff。
"""

from datetime import datetime
from typing import Any

from fastapi import APIRouter, HTTPException, Query, Security
from pydantic import BaseModel, Field

from app.api.v1.payments import verify_callback_key
from app.core.database import get_main_db
from app.services.billing import catalog as billing_catalog
from app.services.billing.catalog import CatalogError

router = APIRouter(prefix="/payments/admin/catalog", tags=["billing-catalog"])


class PlanUpsertRequest(BaseModel):
    # catalog 只维护套餐的展示元数据(name/display)与价格归属;可购性/积分/有效期/等级/
    # 退役状态均由 plan_configs(PlansView)管理,故此处不接收 entitlements/rank/
    # self_checkout_enabled/status 等套餐定义字段(status 改用 /plans/{code}/status 端点)。
    plan_code: str
    name: str | None = None
    display: dict[str, Any] | None = None
    paid: bool | None = None
    plan_family: str | None = None
    stackable: bool | None = None
    auto_renew_supported: bool | None = None
    paid_topup_enabled: bool | None = None


class PlanStatusRequest(BaseModel):
    status: str


class PriceCreateRequest(BaseModel):
    price_id: str = ""
    plan_code: str
    period: str
    duration_period: str = ""
    duration_count: int | None = None
    currency: str
    amount_cents: int = Field(ge=0)
    channel_bindings: dict[str, dict[str, Any]] = Field(default_factory=dict)
    payment_methods: list[str] = Field(default_factory=list)
    sellable: bool = False
    make_current: bool = False
    effective_from: datetime | None = None


class PublishRequest(BaseModel):
    operator: str = ""


def _bad_request(exc: CatalogError) -> HTTPException:
    return HTTPException(status_code=400, detail=str(exc))


@router.get("/plans")
async def list_catalog_plans(_: None = Security(verify_callback_key)):
    return {"plans": await billing_catalog.list_plans(get_main_db())}


@router.post("/plans")
async def upsert_catalog_plan(data: PlanUpsertRequest, _: None = Security(verify_callback_key)):
    try:
        plan, hints = await billing_catalog.upsert_plan(get_main_db(), data.model_dump(exclude_unset=True))
    except CatalogError as exc:
        raise _bad_request(exc)
    return {"plan": plan, "impact_hints": hints}


@router.post("/plans/{plan_code}/status")
async def set_catalog_plan_status(plan_code: str, data: PlanStatusRequest, _: None = Security(verify_callback_key)):
    try:
        plan = await billing_catalog.set_plan_status(get_main_db(), plan_code, data.status)
    except CatalogError as exc:
        raise _bad_request(exc)
    hints = []
    if plan.get("status") == "retired":
        hints.append(
            "retired 仅停止新购:发布后 billing_config 投影将移除该套餐的商品与渠道价;"
            "plan_configs(套餐定义真源)不受影响,存量用户续费/积分重置照旧"
        )
    return {"plan": plan, "impact_hints": hints}


@router.get("/prices")
async def list_catalog_prices(plan_code: str = Query(""), _: None = Security(verify_callback_key)):
    return {"prices": await billing_catalog.list_prices(get_main_db(), plan_code)}


@router.post("/prices")
async def create_catalog_price(data: PriceCreateRequest, _: None = Security(verify_callback_key)):
    db = get_main_db()
    payload = data.model_dump(exclude_unset=True)
    make_current = bool(payload.pop("make_current", False))
    if make_current:
        payload.pop("lookup_key", None)
    try:
        price = await billing_catalog.create_price(db, payload)
        if make_current:
            price = await billing_catalog.make_price_current(db, price["price_id"])
    except CatalogError as exc:
        raise _bad_request(exc)
    return {"price": price, "made_current": make_current}


@router.post("/prices/{price_id}/archive")
async def archive_catalog_price(price_id: str, _: None = Security(verify_callback_key)):
    try:
        price = await billing_catalog.archive_price(get_main_db(), price_id)
    except CatalogError as exc:
        raise _bad_request(exc)
    return {"price": price}


@router.post("/prices/{price_id}/make-current")
async def make_catalog_price_current(price_id: str, _: None = Security(verify_callback_key)):
    try:
        price = await billing_catalog.make_price_current(get_main_db(), price_id)
    except CatalogError as exc:
        raise _bad_request(exc)
    return {"price": price}


@router.post("/publish")
async def publish_catalog(
    dry_run: bool = Query(True, description="true=仅返回 diff,不落库;false=正式发布并写审计日志"),
    data: PublishRequest | None = None,
    _: None = Security(verify_callback_key),
):
    try:
        return await billing_catalog.publish_catalog(
            get_main_db(),
            operator=(data.operator if data else ""),
            dry_run=dry_run,
        )
    except CatalogError as exc:
        raise _bad_request(exc)


@router.get("/publish-log")
async def catalog_publish_log(limit: int = Query(50, ge=1, le=200), _: None = Security(verify_callback_key)):
    return {"logs": await billing_catalog.list_publish_log(get_main_db(), limit)}
