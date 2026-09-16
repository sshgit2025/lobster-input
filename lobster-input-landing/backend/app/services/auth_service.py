"""AuthService — 官网邮箱验证码登录/注册编排。

设计：与主后端登录注册逻辑对齐，但**官网自管登录态**——验证身份后由路由层
签发官网独立的 lobster_site_token Cookie，绝不调用主后端的平台会话签发，
因此不会顶掉用户的 Mac/Win/安卓/iOS 客户端登录。

身份与注册全部基于共享主库：
  - 发码：代理主后端 /auth/send-code（复用真实邮件与限频）；
  - 校验码：读共享 verify_codes；
  - 老用户：直接登录；
  - 新用户：按 system_config 配置门控（注册开关 / 人数上限 / 邀请码开关），
    通过三维风控后创建账号、初始化试用套餐、发放奖励积分、生成邀请码，
    与主后端注册结果一致。
"""
import logging
from datetime import datetime, timezone

from pymongo.errors import DuplicateKeyError

from app.core.errors import AppError
from app.repositories.system_config_repository import SystemConfigRepository
from app.repositories.user_repository import UserRepository
from app.repositories.verify_code_repository import VerifyCodeRepository
from app.repositories.invite_repository import (
    InviteRepository,
    INVITE_CODE_LENGTH,
    normalize_invite_code,
)
from app.repositories.pending_registration_repository import PendingRegistrationRepository
from app.services.plan_service import PlanService
from app.services.credit_service import CreditService
from app.services.backend_proxy import proxy_send_code

logger = logging.getLogger("lobster_landing.auth")


def _mask_email(email: str) -> str:
    parts = email.split("@")
    if len(parts) != 2:
        return "***"
    local, domain = parts
    if len(local) <= 3:
        return f"{'*' * len(local)}@{domain}"
    return f"{local[:3]}{'*' * (len(local) - 3)}@{domain}"


class AuthService:
    def __init__(self):
        self.config_repo = SystemConfigRepository()
        self.user_repo = UserRepository()
        self.code_repo = VerifyCodeRepository()
        self.invite_repo = InviteRepository()
        self.pending_repo = PendingRegistrationRepository()
        self.plan_service = PlanService()
        self.credit_service = CreditService()

    @staticmethod
    def _normalize_email(email: str) -> str:
        return (email or "").strip().lower()

    # ── 发码 ──────────────────────────────────────────────
    async def send_code(self, email: str, client_ip: str) -> None:
        email = self._normalize_email(email)
        if "@" not in email:
            raise AppError(400, "INVALID_EMAIL", "请输入有效的邮箱地址")
        await proxy_send_code(email, client_ip)

    # ── 登录/注册统一校验 ─────────────────────────────────
    async def verify(self, email: str, code: str, device_id: str, client_ip: str, hw_fingerprint: str) -> dict:
        email = self._normalize_email(email)
        device_id = (device_id or "").strip().lower()
        hw_fingerprint = (hw_fingerprint or "").strip().lower()

        valid = await self.code_repo.verify_and_delete(email, code)
        if not valid:
            raise AppError(400, "INVALID_VERIFICATION_CODE", "验证码错误或已过期")

        user = await self.user_repo.find_by_email(email)
        if user:
            if not user.get("is_active", True):
                raise AppError(403, "USER_BANNED", "账号已被封禁，如有疑问请联系客服")
            return self._auth_result(user, is_new_user=False)

        # 新用户
        await self._ensure_registration_enabled(email)
        await self._ensure_registration_limit_count(email)
        invite_enabled = await self.config_repo.get_invite_code_enabled()
        await self.pending_repo.save(email)
        if not invite_enabled:
            return await self._register(email, device_id, client_ip, hw_fingerprint, invite_code="")
        return {
            "authenticated": False,
            "email": email,
            "tier": "",
            "is_new_user": True,
            "require_invite": True,
        }

    # ── 邀请码完成注册 ────────────────────────────────────
    async def verify_invite(self, email: str, invite_code: str, device_id: str, client_ip: str, hw_fingerprint: str) -> dict:
        email = self._normalize_email(email)
        invite_code = normalize_invite_code(invite_code)
        if len(invite_code) != INVITE_CODE_LENGTH:
            raise AppError(400, "INVALID_INVITE_CODE", "邀请码无效或已被使用")
        device_id = (device_id or "").strip().lower()
        hw_fingerprint = (hw_fingerprint or "").strip().lower()

        invite_enabled = await self.config_repo.get_invite_code_enabled()
        if not invite_enabled:
            raise AppError(400, "INVITE_CODE_DISABLED", "邀请码功能已关闭，请直接注册")
        await self._ensure_registration_enabled(email)

        if not await self.pending_repo.exists(email):
            raise AppError(400, "INVITE_SESSION_EXPIRED", "注册会话已过期，请重新获取验证码")

        user = await self.user_repo.find_by_email(email)
        if user:
            if not user.get("is_active", True):
                raise AppError(403, "USER_BANNED", "账号已被封禁，如有疑问请联系客服")
            return self._auth_result(user, is_new_user=False)

        return await self._register(email, device_id, client_ip, hw_fingerprint, invite_code=invite_code)

    # ── 注册落地 ──────────────────────────────────────────
    async def _register(self, email: str, device_id: str, client_ip: str, hw_fingerprint: str, invite_code: str) -> dict:
        await self._ensure_registration_enabled(email)
        await self._ensure_registration_limit_count(email)
        if not device_id:
            raise AppError(400, "INVALID_DEVICE_ID", "设备标识缺失，请刷新页面后重试")
        await self._check_registration_limits(device_id, client_ip, hw_fingerprint, email)

        invited_by = ""
        if invite_code:
            invite = await self.invite_repo.find_available_code(invite_code)
            if not invite:
                raise AppError(400, "INVALID_INVITE_CODE", "邀请码无效或已被使用")
            invited_by = invite.get("owner_email", "")

        try:
            new_user = await self.user_repo.create(
                email=email,
                reg_device_id=device_id,
                reg_ip=client_ip,
                reg_hw_fingerprint=hw_fingerprint,
                invited_by=invited_by,
                used_invite_code=invite_code,
            )
        except DuplicateKeyError:
            existing = await self.user_repo.find_by_email(email)
            if existing:
                if not existing.get("is_active", True):
                    raise AppError(403, "USER_BANNED", "账号已被封禁，如有疑问请联系客服")
                return self._auth_result(existing, is_new_user=False)
            raise AppError(400, "INVALID_INVITE_CODE", "邀请码无效或已被使用")

        await self._complete_registration_setup(new_user, invite_code)
        await self.pending_repo.delete(email)
        refreshed = await self.user_repo.find_by_email(email) or new_user
        logger.info("[auth] new user registered email=%s", email)
        return self._auth_result(refreshed, is_new_user=True)

    async def _complete_registration_setup(self, user: dict, invite_code: str = "") -> None:
        email = user["email"]
        created_at = user.get("created_at")
        await self.plan_service.init_user_plan(email, created_at or datetime.now(timezone.utc))
        await self.credit_service.grant_by_policy(email, "registration_reward", idempotency_key=f"registration_reward:{email}")
        normalized = normalize_invite_code(invite_code or user.get("used_invite_code", ""))
        if normalized:
            await self.credit_service.grant_by_policy(email, "invite_reward", idempotency_key=f"invite_reward:{email}")
            await self.invite_repo.mark_code_used(normalized, email)
        await self.invite_repo.create_codes_for_user(email)
        await self.user_repo.mark_registration_complete(email)

    # ── 门控与风控 ────────────────────────────────────────
    async def _ensure_registration_enabled(self, email: str) -> None:
        if not await self.config_repo.get_registration_enabled():
            logger.warning("[auth] registration disabled email=%s", email)
            raise AppError(403, "REGISTRATION_DISABLED", "当前未开放注册")

    async def _ensure_registration_limit_count(self, email: str) -> None:
        if await self.config_repo.get_registration_limit_enabled():
            limit = await self.config_repo.get_registration_limit_count()
            current = await self.config_repo.get_current_user_count()
            if current >= limit:
                logger.warning("[auth] registration limit reached current=%d limit=%d", current, limit)
                raise AppError(403, "REGISTRATION_CLOSED", "注册人数已达上限，暂停开放注册")

    async def _check_registration_limits(self, device_id: str, client_ip: str, hw_fingerprint: str, email: str) -> None:
        max_accounts = await self.config_repo.get_max_accounts_per_device()
        device_count = await self.user_repo.count_by_device_id(device_id)
        ip_valid = client_ip not in ("unknown", "", None)
        ip_count = await self.user_repo.count_by_ip(client_ip) if ip_valid else 0
        fp_count = await self.user_repo.count_by_hw_fingerprint(hw_fingerprint) if hw_fingerprint else 0

        device_blocked = device_count >= max_accounts
        ip_blocked = ip_valid and ip_count >= max_accounts
        fp_blocked = bool(hw_fingerprint) and fp_count >= max_accounts
        if device_blocked or ip_blocked or fp_blocked:
            logger.warning("[auth] reg limit reached device=%d ip=%d fp=%d max=%d email=%s",
                           device_count, ip_count, fp_count, max_accounts, email)
            raise AppError(403, "REG_LIMIT_REACHED", "该设备或网络注册账号已达上限，无法继续注册")

    # ── 我的邀请码 ────────────────────────────────────────
    async def get_my_invite_codes(self, email: str) -> list[dict]:
        codes = await self.invite_repo.create_codes_for_user(email)
        result = []
        for c in codes:
            used_by_raw = c.get("used_by")
            result.append({
                "code": c["code"],
                "is_used": bool(c.get("is_used", False)),
                "used_by": _mask_email(used_by_raw) if used_by_raw else None,
                "used_at": c.get("used_at"),
            })
        return result

    @staticmethod
    def _auth_result(user: dict, is_new_user: bool) -> dict:
        return {
            "authenticated": True,
            "email": user["email"],
            "tier": user.get("subscription_plan_code") or user.get("plan_code") or user.get("tier") or "trial",
            "is_new_user": is_new_user,
            "require_invite": False,
        }
