from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from typing import Optional
from app.core.security import decode_access_token
from app.core.config import settings
from app.api.v1.deps import AdminAuthCookie

router = APIRouter(tags=["pages"])
templates = Jinja2Templates(directory="app/templates")

_base = settings.BASE_URL.rstrip("/")


def _check_auth(access_token: Optional[str]) -> Optional[str]:
    if not access_token:
        return None
    payload = decode_access_token(access_token)
    if not payload:
        return None
    return payload.get("sub")


def _ctx(request: Request, **extra) -> dict:
    """构建模板上下文，统一注入 base_url。"""
    return {
        "request": request,
        "base_url": _base,
        "auth_cookie_name": settings.AUTH_COOKIE_NAME,
        **extra,
    }


@router.get("/", response_class=HTMLResponse)
async def index(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return RedirectResponse(url=f"{_base}/dashboard")


@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if username:
        return RedirectResponse(url=f"{_base}/dashboard")
    return templates.TemplateResponse("pages/login.html", _ctx(request))


@router.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/dashboard.html", _ctx(
        request, username=username, active="dashboard",
    ))


@router.get("/users", response_class=HTMLResponse)
async def users_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/users.html", _ctx(
        request, username=username, active="users",
    ))


@router.get("/invites", response_class=HTMLResponse)
async def invites_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/invites.html", _ctx(
        request, username=username, active="invites",
    ))


@router.get("/stats", response_class=HTMLResponse)
async def stats_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/stats.html", _ctx(
        request, username=username, active="stats",
    ))


# NOTE: 旧 Jinja 版「系统配置」(/config) 与「套餐配置」(/plans) 页已下线,
# 避免与 Vue 管理端(ConfigView/PlansView)双写同一份生产配置。
# 系统配置/套餐配置统一由 Vue 端管理,节点计费由「计费经济性」(billing-margin 代理)管理。


@router.get("/provider-config", response_class=HTMLResponse)
async def provider_config_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/provider_config.html", _ctx(
        request, username=username, active="provider_config",
    ))


@router.get("/payment-providers", response_class=HTMLResponse)
async def payment_providers_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/payment_providers.html", _ctx(
        request, username=username, active="payment_providers",
    ))


@router.get("/payment-orders", response_class=HTMLResponse)
async def payment_orders_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/payment_orders.html", _ctx(
        request, username=username, active="payment_orders",
    ))


@router.get("/payment-transactions", response_class=HTMLResponse)
async def payment_transactions_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/payment_transactions.html", _ctx(
        request, username=username, active="payment_transactions",
    ))


@router.get("/payment-refunds", response_class=HTMLResponse)
async def payment_refunds_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/payment_refunds.html", _ctx(
        request, username=username, active="payment_refunds",
    ))


@router.get("/plan-accounts", response_class=HTMLResponse)
async def plan_accounts_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/plan_accounts.html", _ctx(
        request, username=username, active="plan_accounts",
    ))


@router.get("/ledger", response_class=HTMLResponse)
async def ledger_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/ledger.html", _ctx(
        request, username=username, active="ledger",
    ))


@router.get("/account", response_class=HTMLResponse)
async def account_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/account.html", _ctx(
        request, username=username, active="account",
    ))


@router.get("/logs", response_class=HTMLResponse)
async def logs_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/logs.html", _ctx(
        request, username=username, active="logs",
    ))


@router.get("/feedback", response_class=HTMLResponse)
async def feedback_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/feedback.html", _ctx(
        request, username=username, active="feedback",
    ))


@router.get("/agreements", response_class=HTMLResponse)
async def agreements_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/agreements.html", _ctx(
        request, username=username, active="agreements",
    ))


@router.get("/rewards", response_class=HTMLResponse)
async def rewards_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/rewards.html", _ctx(
        request, username=username, active="rewards",
    ))


@router.get("/alerts", response_class=HTMLResponse)
async def alerts_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/alerts.html", _ctx(
        request, username=username, active="alerts",
    ))


@router.get("/security", response_class=HTMLResponse)
async def security_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/security.html", _ctx(
        request, username=username, active="security",
    ))


@router.get("/user-dict", response_class=HTMLResponse)
async def user_dict_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/user_dict.html", _ctx(
        request, username=username, active="user_dict",
    ))


@router.get("/personas", response_class=HTMLResponse)
async def personas_page(request: Request, access_token: AdminAuthCookie = None):
    username = _check_auth(access_token)
    if not username:
        return RedirectResponse(url=f"{_base}/login")
    return templates.TemplateResponse("pages/personas.html", _ctx(
        request, username=username, active="personas",
    ))
