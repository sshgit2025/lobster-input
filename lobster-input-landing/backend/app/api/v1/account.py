"""个人中心接口（需登录态）。

  GET /api/v1/account/plan         — 账号与各项积分（只读）
  GET /api/v1/account/orders       — 订阅支付订单明细与状态（只读，无退款入口）
  GET /api/v1/account/invite-codes — 我的邀请码（按配置展示入口）
"""
from fastapi import APIRouter, Depends

from app.middleware.deps import get_current_email
from app.repositories.order_repository import OrderRepository
from app.repositories.system_config_repository import SystemConfigRepository
from app.services.plan_service import PlanService
from app.services.auth_service import AuthService

router = APIRouter(prefix="/api/v1/account", tags=["account"])
plan_service = PlanService()
order_repo = OrderRepository()
config_repo = SystemConfigRepository()
auth_service = AuthService()


@router.get("/plan")
async def get_plan(email: str = Depends(get_current_email)):
    return await plan_service.get_points(email)


@router.get("/orders")
async def get_orders(email: str = Depends(get_current_email)):
    return {"orders": await order_repo.list_by_user(email)}


@router.get("/invite-codes")
async def get_invite_codes(email: str = Depends(get_current_email)):
    show = await config_repo.get_show_invite_codes_enabled()
    if not show:
        return {"show": False, "invite_codes": []}
    return {"show": True, "invite_codes": await auth_service.get_my_invite_codes(email)}
