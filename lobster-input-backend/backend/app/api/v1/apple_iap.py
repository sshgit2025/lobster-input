"""Apple IAP(iOS 应用内购买)客户端入口。

定位与现有支付入口一致:后端只做登录态校验、商品映射下发和轻量内部签名转发,
signedTransaction 的验签与权益发放由 payment 服务负责。
与 web checkout(/payments/subscription/checkout 等)链路完全独立,互不影响。
"""
import uuid

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.api.v1.payments import _request_payment_service
from app.core.database import get_db
from app.middleware.auth import verify_user
from app.repositories.plan_repository import PlanRepository
from app.services.billing.plan_service import PlanService

router = APIRouter(prefix="/payments/apple", tags=["Payments-Apple"])

MAX_RESTORE_TRANSACTIONS = 20


class AppleVerifyRequest(BaseModel):
    signed_transaction: str = Field(min_length=1, max_length=64 * 1024)
    source: str = "purchase"


class AppleRestoreRequest(BaseModel):
    signed_transactions: list[str] = Field(default_factory=list)


async def _ensure_app_account_token(email: str) -> str:
    """为用户生成/取回 appAccountToken(UUID),购买时随 StoreKit 交易携带,用于服务器通知归属映射。"""
    users = get_db()["users"]
    user = await users.find_one({"email": email}, {"apple_app_account_token": 1})
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    token = str(user.get("apple_app_account_token") or "").strip().lower()
    if token:
        return token
    token = str(uuid.uuid4()).lower()
    result = await users.update_one(
        {"email": email, "apple_app_account_token": {"$in": [None, ""]}},
        {"$set": {"apple_app_account_token": token}},
    )
    if not result.modified_count:
        # 并发下已被其他请求写入,读回既有值
        user = await users.find_one({"email": email}, {"apple_app_account_token": 1})
        token = str((user or {}).get("apple_app_account_token") or token).lower()
    return token


def _merge_plan_display(products: list[dict], plan_configs: dict) -> list[dict]:
    merged = []
    for product in products:
        row = dict(product)
        if row.get("type") == "subscription":
            plan = plan_configs.get(row.get("plan_code") or "") or {}
            if not plan or not plan.get("enabled", True):
                continue
            option = (plan.get("billing_options") or {}).get(row.get("billing_cycle") or "") or {}
            if option.get("enabled") is False:
                continue
            row["plan_name"] = plan.get("name") or row.get("plan_code")
            row["plan_credits"] = int(plan.get("credits") or 0)
            row["plan_reset_period"] = plan.get("reset_period") or "month"
            row["plan_rank"] = int(plan.get("rank") or 0)
            row["duration_period"] = option.get("duration_period") or "month"
            row["duration_count"] = int(option.get("duration_count") or 1)
        merged.append(row)
    return merged


@router.get("/products", summary="获取 iOS 内购商品映射(含 appAccountToken)")
async def apple_products(payload: dict = Depends(verify_user)):
    email = payload.get("sub", "")
    catalog = await _request_payment_service("GET", "/api/v1/payments/apple/products")
    if not catalog.get("enabled"):
        return {"enabled": False, "products": [], "app_account_token": ""}
    plan_configs = await PlanRepository().get_plan_configs()
    products = _merge_plan_display(catalog.get("products") or [], plan_configs)
    token = await _ensure_app_account_token(email)
    return {
        "enabled": True,
        "bundle_id": catalog.get("bundle_id") or "",
        "products": products,
        "app_account_token": token,
    }


async def _verify_one(email: str, signed_transaction: str, source: str) -> dict:
    return await _request_payment_service(
        "POST",
        "/api/v1/payments/apple/verify-transaction",
        {"user_email": email, "signed_transaction": signed_transaction, "source": source},
    )


@router.post("/verify", summary="提交 StoreKit 交易凭证并发放权益")
async def apple_verify(data: AppleVerifyRequest, payload: dict = Depends(verify_user)):
    email = payload.get("sub", "")
    source = data.source if data.source in {"purchase", "restore", "listener"} else "purchase"
    result = await _verify_one(email, data.signed_transaction, source)
    plan = await PlanService().get_user_plan_info(email)
    return {"result": result, "plan": plan}


@router.post("/restore", summary="恢复购买:批量提交当前有效交易凭证")
async def apple_restore(data: AppleRestoreRequest, payload: dict = Depends(verify_user)):
    email = payload.get("sub", "")
    transactions = [item for item in data.signed_transactions if isinstance(item, str) and item.strip()]
    if len(transactions) > MAX_RESTORE_TRANSACTIONS:
        transactions = transactions[:MAX_RESTORE_TRANSACTIONS]
    results = []
    for signed_transaction in transactions:
        try:
            results.append(await _verify_one(email, signed_transaction, "restore"))
        except HTTPException as exc:
            results.append({"status": "failed", "detail": exc.detail})
    plan = await PlanService().get_user_plan_info(email)
    return {"results": results, "plan": plan}
