"""
客户端配置接口。
返回客户端运行时需要的服务端配置参数，避免硬编码。
需要登录态，防止未授权调用。
"""
import json

from fastapi import APIRouter, Depends, Body, HTTPException, Header
from app.core.config import settings
from app.core.content_i18n import normalize_language
from app.core.database import get_db
from app.middleware.auth import verify_user, verify_internal_api_key
from app.models.schemas import AppStartupConfig, UserPlanInfo
from app.repositories.plan_repository import PlanRepository
from app.services.billing.plan_service import PlanService
from app.services.billing import margin_engine
from app.api.v1.payments import _payment_provider_catalog

router = APIRouter(prefix="/config", tags=["Config"])

DIY_SETTINGS_COL = "user_settings"
MAX_DIY_CONFIG_BYTES = 16 * 1024


@router.get("/startup", response_model=AppStartupConfig, summary="获取 App 启动全局配置（无需鉴权）")
async def get_startup_config():
    """
    App 启动时调用，无需登录态。
    返回邀请码开关、注册人数限制等全局配置，客户端据此决定是否展示邀请码界面。
    """
    plan_repo = PlanRepository()
    invite_enabled = await plan_repo.get_invite_code_enabled()
    registration_enabled = await plan_repo.get_registration_enabled()
    show_invite_codes_enabled = await plan_repo.get_show_invite_codes_enabled()
    show_subscription_module_enabled = await plan_repo.get_show_subscription_module_enabled()
    reg_limit_enabled = await plan_repo.get_registration_limit_enabled()
    reg_limit_count = await plan_repo.get_registration_limit_count()
    return AppStartupConfig(
        registration_enabled=registration_enabled,
        invite_code_enabled=invite_enabled,
        show_invite_codes_enabled=show_invite_codes_enabled,
        show_subscription_module_enabled=show_subscription_module_enabled,
        registration_limit_enabled=reg_limit_enabled,
        registration_limit_count=reg_limit_count,
    )


@router.get("/plan", response_model=UserPlanInfo, summary="获取当前用户套餐积分信息")
async def get_user_plan(
    payload: dict = Depends(verify_user),
    x_accept_language: str | None = Header(default=None, alias="X-Accept-Language"),
):
    """
    获取当前登录用户的套餐积分信息（含剩余积分、重置时间）。
    同时触发积分重置检查（如已到重置周期则自动重置）。
    套餐展示名 plan_name 按 X-Accept-Language 本地化返回（对齐 persona 国际化策略）。
    """
    email = payload.get("sub", "")
    plan_service = PlanService()
    info = await plan_service.get_user_plan_info(email, language=normalize_language(x_accept_language))
    return UserPlanInfo(**info)


@router.get("/recording", summary="获取录音相关配置")
async def get_recording_config(_: dict = Depends(verify_user)):
    return {
        "max_duration_sec": settings.audio_max_duration_sec - 5,
    }


@router.get("/diy", summary="获取用户 DIY 配置")
async def get_diy_config(payload: dict = Depends(verify_user)):
    user_email = payload.get("sub", "")
    if not user_email:
        return {"diy_config": None}
    col = get_db()[DIY_SETTINGS_COL]
    doc = await col.find_one({"user_email": user_email})
    if doc and "diy_config" in doc:
        return {"diy_config": doc["diy_config"]}
    return {"diy_config": None}


@router.put("/diy", summary="保存用户 DIY 配置")
async def save_diy_config(
    body: dict = Body(...),
    payload: dict = Depends(verify_user),
):
    user_email = payload.get("sub", "")
    if not user_email:
        return {"ok": False, "message": "no user"}
    try:
        encoded = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
    except (TypeError, ValueError):
        raise HTTPException(400, {"code": "INVALID_DIY_CONFIG", "message": "DIY 配置格式不合法"})
    if len(encoded.encode("utf-8")) > MAX_DIY_CONFIG_BYTES:
        raise HTTPException(413, {"code": "DIY_CONFIG_TOO_LARGE", "message": "DIY 配置过大"})
    col = get_db()[DIY_SETTINGS_COL]
    await col.update_one(
        {"user_email": user_email},
        {"$set": {"diy_config": body}},
        upsert=True,
    )
    return {"ok": True}


# ---------------------------------------------------------------------------- #
# 计费经济性管理（管理端，内部鉴权 verify_internal_api_key）                     #
# ---------------------------------------------------------------------------- #
async def _assemble_billing_prices(plan_repo: PlanRepository) -> list[dict]:
    """组装每套餐每积分售价：优先支付端商品价，套餐积分额度回退 plan_configs.credits。"""
    plan_configs = await plan_repo.get_plan_configs()
    catalog = await _payment_provider_catalog()
    subscription_products = (catalog or {}).get("subscription_products") or {}
    return margin_engine.assemble_plan_prices(plan_configs, subscription_products)


@router.get("/billing-rules", summary="[管理端] 获取积分扣费规则（节点单价）与计费策略")
async def get_billing_rules(_: dict = Depends(verify_internal_api_key)):
    """返回按业务节点单一价的扣费规则与全局计费策略（阈值仅供监控着色）。"""
    plan_repo = PlanRepository()
    return {
        "rules": await plan_repo.get_credit_pricing_rules(),
        "policy": await plan_repo.get_credit_pricing_policy(),
    }


@router.post("/billing-rules", summary="[管理端] 保存积分扣费规则（节点单价）与计费策略")
async def save_billing_rules(
    body: dict = Body(...),
    _: dict = Depends(verify_internal_api_key),
):
    """
    保存节点单价扣费规则/策略。**只校验字段合法性，不做毛利地板拦截、无 force**
    （阶段A：成本/毛利降级为只读监控，不阻断任何配置）。
    """
    plan_repo = PlanRepository()
    incoming_rules = body.get("rules")
    incoming_policy = body.get("policy")

    if incoming_rules is not None and not isinstance(incoming_rules, list):
        raise HTTPException(400, {"code": "INVALID_RULES", "message": "rules 必须为数组"})
    if incoming_policy is not None and not isinstance(incoming_policy, dict):
        raise HTTPException(400, {"code": "INVALID_POLICY", "message": "policy 必须为对象"})

    if incoming_rules is not None:
        await plan_repo.set_credit_pricing_rules(incoming_rules)
    if isinstance(incoming_policy, dict):
        await plan_repo.set_credit_pricing_policy(incoming_policy)

    return {"saved": True}


@router.get("/billing-provider-costs", summary="[管理端] 获取上游参考成本表（仅供毛利监控）")
async def get_billing_provider_costs(_: dict = Depends(verify_internal_api_key)):
    """返回各 provider 的上游参考成本（独立成本表，不参与用户扣费）。"""
    plan_repo = PlanRepository()
    return {"costs": await plan_repo.get_credit_provider_costs()}


@router.post("/billing-provider-costs", summary="[管理端] 保存上游参考成本表（仅供毛利监控）")
async def save_billing_provider_costs(
    body: dict = Body(...),
    _: dict = Depends(verify_internal_api_key),
):
    """保存 provider 参考成本表。只校验字段合法性，不参与扣费、不做拦截。"""
    incoming_costs = body.get("costs")
    if not isinstance(incoming_costs, list):
        raise HTTPException(400, {"code": "INVALID_COSTS", "message": "costs 必须为数组"})
    plan_repo = PlanRepository()
    await plan_repo.set_credit_provider_costs(incoming_costs)
    return {"saved": True}


@router.get("/billing-margin-report", summary="[管理端] 计费毛利只读监控看板")
async def get_billing_margin_report(_: dict = Depends(verify_internal_api_key)):
    """只读监控：每节点单价 × 每 provider 成本 → 毛利率红绿灯，附全局最低每积分售价。不拦截。"""
    plan_repo = PlanRepository()
    rules = await plan_repo.get_credit_pricing_rules()
    provider_costs = await plan_repo.get_credit_provider_costs()
    policy = await plan_repo.get_credit_pricing_policy()
    plan_prices = await _assemble_billing_prices(plan_repo)
    return margin_engine.build_margin_report(rules, provider_costs, plan_prices, policy)
