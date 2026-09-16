"""
页面路由 — Jinja2 模板渲染。
"""
from fastapi import APIRouter, Request, Depends
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from app.core.config import settings
from app.core.security import decode_access_token

router = APIRouter(tags=["pages"])
templates = Jinja2Templates(directory="app/templates")


def _ctx(request: Request, **kwargs):
    return {
        "request": request,
        "base_url": settings.BASE_URL,
        **kwargs,
    }


def _check_auth(request: Request) -> bool:
    token = request.cookies.get(settings.AUTH_COOKIE_NAME)
    if not token:
        return False
    payload = decode_access_token(token)
    return payload is not None


@router.get("/", response_class=HTMLResponse)
async def index(request: Request):
    if not _check_auth(request):
        return RedirectResponse(
            url=f"{settings.BASE_URL}/login"
        )
    return RedirectResponse(
        url=f"{settings.BASE_URL}/dashboard"
    )


@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    return templates.TemplateResponse(
        "pages/login.html", _ctx(request)
    )


@router.get("/dashboard", response_class=HTMLResponse)
async def dashboard_page(request: Request):
    if not _check_auth(request):
        return RedirectResponse(
            url=f"{settings.BASE_URL}/login"
        )
    return templates.TemplateResponse(
        "pages/dashboard.html",
        _ctx(request, page="dashboard"),
    )


@router.get("/keys", response_class=HTMLResponse)
async def keys_page(request: Request):
    if not _check_auth(request):
        return RedirectResponse(
            url=f"{settings.BASE_URL}/login"
        )
    return templates.TemplateResponse(
        "pages/keys.html",
        _ctx(request, page="keys"),
    )


@router.get("/usage", response_class=HTMLResponse)
async def usage_page(request: Request):
    if not _check_auth(request):
        return RedirectResponse(
            url=f"{settings.BASE_URL}/login"
        )
    return templates.TemplateResponse(
        "pages/usage.html",
        _ctx(request, page="usage"),
    )


@router.get("/account", response_class=HTMLResponse)
async def account_page(request: Request):
    if not _check_auth(request):
        return RedirectResponse(
            url=f"{settings.BASE_URL}/login"
        )
    return templates.TemplateResponse(
        "pages/account.html",
        _ctx(request, page="account"),
    )
