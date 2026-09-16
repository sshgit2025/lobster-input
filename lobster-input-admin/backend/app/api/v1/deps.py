from fastapi import Depends, HTTPException, Cookie, status
from typing import Annotated, Optional
from app.core.security import decode_access_token
from app.core.config import settings
from app.core.database import get_admin_db, get_main_db  # noqa: F401  re-exported for routers
from app.repositories.admin_repository import AdminRepository
from app.repositories.user_repository import UserRepository
from app.repositories.invite_repository import InviteRepository
from app.repositories.stats_repository import StatsRepository
from app.repositories.ledger_repository import LedgerRepository
from app.repositories.config_repository import ConfigRepository
from app.repositories.agreement_repository import AgreementRepository
from app.repositories.alert_repository import AlertRepository
from app.repositories.security_repository import SecurityRepository
from app.repositories.persona_repository import BuiltinPersonaRepository

AdminAuthCookie = Annotated[Optional[str], Cookie(alias=settings.AUTH_COOKIE_NAME)]


async def get_current_admin(
    access_token: AdminAuthCookie = None,
):
    if not access_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="未登录",
            headers={"WWW-Authenticate": "Bearer"},
        )
    payload = decode_access_token(access_token)
    if not payload:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token无效或已过期",
        )
    return payload.get("sub")


def get_admin_repo() -> AdminRepository:
    return AdminRepository(get_admin_db())


def get_user_repo() -> UserRepository:
    return UserRepository(get_main_db())


def get_invite_repo() -> InviteRepository:
    return InviteRepository(get_main_db())


def get_stats_repo() -> StatsRepository:
    return StatsRepository(get_main_db())


def get_ledger_repo() -> LedgerRepository:
    return LedgerRepository(get_main_db())


def get_config_repo() -> ConfigRepository:
    return ConfigRepository(get_main_db())


def get_agreement_repo() -> AgreementRepository:
    return AgreementRepository(get_main_db())


def get_alert_repo() -> AlertRepository:
    return AlertRepository(get_admin_db())


def get_security_repo() -> SecurityRepository:
    return SecurityRepository(get_main_db())


def get_builtin_persona_repo() -> BuiltinPersonaRepository:
    return BuiltinPersonaRepository(get_main_db())
