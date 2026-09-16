"""
AuthService — 统一验证码登录/注册逻辑。
流程:
  老用户: 发送验证码 → 验证码校验通过 → 直接签发 JWT 返回
  新用户: 发送验证码 → 验证码校验通过 → 返回 require_invite=True
       → 用户填写邀请码 → 多维度限制校验 → 创建账号 → 签发 JWT

防滥注册策略（三维联动封禁）:
  - IOPlatformUUID（设备码）
  - 硬件指纹 SHA-256（UUID + CPU核数 + 内存大小 + 硬盘序列号）
  - 注册 IP
  任意一维达到上限 → 三维全部封禁，拒绝新注册

防滥用发码策略:
  - 同邮箱 60 秒冷却（限制同邮箱重复发码）
  - 同 IP 每小时最多 MAX_CODE_SEND_PER_IP_HOURLY 次（限制单 IP 批量探测）
  - 临时邮箱域名黑名单（阻断一次性邮箱批量注册）
"""
import logging
import random
import re
import secrets
import string
from datetime import datetime, timezone, timedelta

from fastapi import Request
from jose import jwt
from pymongo.errors import DuplicateKeyError
from app.core.config import settings
from app.core.exceptions import InvalidVerificationCodeException, AppException, UserBannedException
from app.core.request_utils import client_ip as trusted_client_ip
from app.repositories.user_repository import UserRepository
from app.repositories.verify_code_repository import VerifyCodeRepository
from app.repositories.invite_repository import INVITE_CODE_LENGTH, InviteRepository, normalize_invite_code
from app.repositories.plan_repository import PlanRepository
from app.repositories.pending_registration_repository import PendingRegistrationRepository
from app.repositories.security_repository import SecurityRepository
from app.repositories.distributed_lock_repository import DistributedLockRepository
from app.services.account.email_service import EmailService
from app.services.account.session_service import compute_session_expiry, shanghai_today
from app.services.billing.plan_service import PlanService
from app.services.billing.credit_account_service import CreditAccountService
from app.data.credits.models import CreditLedgerEntry, BreakdownItem
from app.data.credits.repository import CreditLedgerRepository

logger = logging.getLogger("voice_input.auth")

PURPOSE_UNIFIED = "unified"
VALID_CLIENT_PLATFORMS = frozenset({"macos", "ios", "windows", "android", "harmony"})
# uat 在列表内:历史上 uat(原 preview)一直启用固定验证码通道,且该通道仅对
# AUTH_FIXED_VERIFY_CODE_EMAILS 白名单邮箱生效;production 永不启用
FIXED_VERIFY_CODE_ENVS = frozenset({"development", "uat", "preview", "test"})

# 同邮箱两次发码最小间隔（秒）
RESEND_COOLDOWN_SEC = 60
# 同 IP 每小时最多发码次数
MAX_CODE_SEND_PER_IP_HOURLY = 20

# ── 临时邮箱域名黑名单 ────────────────────────────────────────────
# 业界常见一次性/临时邮箱服务域名，持续更新即可，无需重启
DISPOSABLE_EMAIL_DOMAINS: frozenset[str] = frozenset({
    "mailinator.com", "guerrillamail.com", "guerrillamail.net",
    "guerrillamail.org", "guerrillamail.biz", "guerrillamail.de",
    "guerrillamail.info", "sharklasers.com", "guerrillamailblock.com",
    "grr.la", "spam4.me", "trashmail.com", "trashmail.me",
    "trashmail.net", "trashmail.io", "trashmail.at", "trashmail.xyz",
    "10minutemail.com", "10minutemail.net", "10minutemail.org",
    "tempmail.com", "tempmail.net", "temp-mail.org", "temp-mail.ru",
    "dispostable.com", "yopmail.com", "yopmail.fr", "cool.fr.nf",
    "jetable.fr.nf", "nospam.ze.tc", "nomail.xl.cx", "mega.zik.dj",
    "speed.1s.fr", "courriel.fr.nf", "moncourrier.fr.nf",
    "monemail.fr.nf", "monmail.fr.nf", "getairmail.com",
    "filzmail.com", "throwam.com", "throwaway.email",
    "fakeinbox.com", "maildrop.cc", "mailnull.com", "mailnesia.com",
    "mailnew.com", "mailsac.com", "discard.email", "spamgourmet.com",
    "spamgourmet.net", "spamgourmet.org", "spamhole.com",
    "spamoff.de", "spamspot.com", "spamthis.co.uk",
    "mailnot.io", "inboxalias.com", "spamex.com", "tempr.email",
    "dispostable.com", "getnada.com", "mohmal.com", "owlpic.com",
    "spamhereplease.com", "binkmail.com", "bobmail.info",
    "chammy.info", "devnullmail.com", "dingbone.com",
    "fudgerub.com", "lookugly.com", "smellfear.com",
    "fakedemail.com", "trashmail.fr", "spamfree24.org",
})


def _generate_code(length: int = 6) -> str:
    return "".join(random.choices(string.digits, k=length))


def _fixed_verification_code_for_email(email: str) -> str | None:
    """
    返回显式配置的测试验证码。
    该能力只允许在非 production 环境打开，且必须同时配置开关、邮箱白名单和 6 位数字验证码。
    """
    if not settings.auth_fixed_verify_code_enabled:
        return None
    if settings.app_env not in FIXED_VERIFY_CODE_ENVS:
        logger.error(
            "[auth] fixed verification code disabled outside non-production env app_env=%s",
            settings.app_env,
        )
        return None

    fixed_code = (settings.auth_fixed_verify_code_value or "").strip()
    if not re.fullmatch(r"\d{6}", fixed_code):
        logger.error("[auth] fixed verification code config ignored: value must be 6 digits")
        return None

    allowed_emails = {
        item.strip().lower()
        for item in (settings.auth_fixed_verify_code_emails or "").split(",")
        if item.strip()
    }
    if email in allowed_emails:
        return fixed_code
    return None


def _create_session_id() -> str:
    return secrets.token_urlsafe(24)


def _create_token(email: str, tier: str, client_platform: str, session_id: str) -> str:
    payload = {
        "sub": email,
        "tier": tier,
        "platform": client_platform,
        "sid": session_id,
        "exp": datetime.now(timezone.utc) + timedelta(minutes=settings.jwt_expire_minutes),
    }
    return jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)


def _mask_email(email: str) -> str:
    """脱敏邮箱：前3位保留，其余用 * 替换。"""
    parts = email.split("@")
    if len(parts) != 2:
        return "***"
    local, domain = parts
    if len(local) <= 3:
        return f"{'*' * len(local)}@{domain}"
    return f"{local[:3]}{'*' * (len(local) - 3)}@{domain}"


def _get_client_ip(request: Request) -> str:
    """提取客户端真实 IP，仅信任来自可信代理的转发头。"""
    return trusted_client_ip(request)


def _check_disposable_email(email: str) -> None:
    """检查是否为临时/一次性邮箱域名，是则抛出异常。"""
    domain = email.lower().split("@")[-1] if "@" in email else ""
    if domain in DISPOSABLE_EMAIL_DOMAINS:
        logger.warning("[auth] disposable email blocked: %s", email)
        raise AppException(400, "DISPOSABLE_EMAIL", "不支持使用临时邮箱，请使用真实邮箱地址")


async def _check_send_rate_limit(email: str, client_ip: str, client_platform: str) -> None:
    """
    发码频率检查：
      1. 同「邮箱 + IP + 客户端类型」组合 60s 内仅允许发 1 次
         （同 IP 但客户端类型不同的间隔相互独立，客户端类型必须为合法枚举）
      2. 同 IP 每小时发码上限（防刷）
    """
    repo = SecurityRepository()
    # 客户端类型兜底校验：非法类型不参与独立计时，归一到 "unknown"
    # （正常情况下 ClientPlatformMiddleware 已拦截非法类型）
    platform = client_platform if client_platform in VALID_CLIENT_PLATFORMS else "unknown"
    ip_part = client_ip if (client_ip and client_ip != "unknown") else "unknown"
    cooldown_key = f"send_code:{email}|{ip_part}|{platform}"
    remaining = await repo.acquire_cooldown_slot(
        key=cooldown_key,
        cooldown_seconds=RESEND_COOLDOWN_SEC,
    )
    if remaining > 0:
        logger.warning(
            "[auth] send_code cooldown email=%s ip=%s platform=%s remaining=%ds",
            email, ip_part, platform, remaining,
        )
        raise AppException(429, "SEND_CODE_TOO_FREQUENT", f"发送太频繁，请 {remaining} 秒后重试")

    if client_ip and client_ip != "unknown":
        ip_count = await repo.hit_counter(
            scope="ip",
            key=client_ip,
            path_group="auth_send_code",
            window_seconds=3600,
        )
        if ip_count > MAX_CODE_SEND_PER_IP_HOURLY:
            logger.warning("[auth] send_code rate limit (ip) %s, count=%d", client_ip, ip_count)
            raise AppException(429, "SEND_CODE_TOO_FREQUENT", "该网络发送验证码过于频繁，请稍后再试")


class AuthService:
    """认证服务，封装验证码发送、校验和用户注册/登录逻辑。"""

    def __init__(self):
        self.user_repo = UserRepository()
        self.code_repo = VerifyCodeRepository()
        self.invite_repo = InviteRepository()
        self.pending_registration_repo = PendingRegistrationRepository()
        self.plan_repo = PlanRepository()
        self.plan_service = PlanService()
        self.credit_account = CreditAccountService()
        self.email_service = EmailService()
        self.ledger_repo = CreditLedgerRepository()
        self.security_repo = SecurityRepository()
        self.lock_repo = DistributedLockRepository()

    @staticmethod
    def _normalize_email(email: str) -> str:
        return (email or "").strip().lower()

    async def _issue_login_token(self, email: str, tier: str, client_platform: str) -> str:
        """为指定平台签发登录 token，并使该平台旧 token 失效。"""
        if client_platform not in VALID_CLIENT_PLATFORMS:
            logger.warning("[auth] invalid client platform for login: %s", client_platform)
            raise AppException(403, "INVALID_CLIENT_PLATFORM", "Missing or invalid X-Client-Platform header")
        session_id = _create_session_id()
        # 滑动窗口登录态：登录即写入 expires_at（上海时区 当天+15天 23:59:59）与 renewed_date
        today = shanghai_today()
        await self.user_repo.set_active_session(
            email,
            client_platform,
            session_id,
            expires_at=compute_session_expiry(today),
            renewed_date=today.isoformat(),
        )
        return _create_token(email, tier, client_platform, session_id)

    async def logout(self, email: str, client_platform: str) -> None:
        """退出登录：清除该账号该平台的活跃 session（幂等），旧 token 立即失效。"""
        await self.user_repo.clear_active_session(email, client_platform)
        logger.info("[auth] logout email=%s platform=%s", email, client_platform)

    async def _grant_registration_reward(self, email: str) -> None:
        """
        发放注册积分奖励。
        开关开启且奖励积分>0时才执行，写入 credit_ledger 记录。
        """
        key = f"registration_reward:{email}"
        credits = await self.credit_account.grant_by_policy(email, "registration_reward", idempotency_key=key)
        if credits <= 0:
            return
        entry = CreditLedgerEntry(
            user_email=email,
            operation="registration_reward",
            client_platform="system",
            total_credits=credits,
            breakdown=[BreakdownItem(platform="registration_reward", credits=credits)],
            idempotency_key=f"ledger:{key}",
        )
        await self.ledger_repo.insert(entry)
        logger.info("[auth] registration_reward email=%s credits=%d", email, credits)

    async def _grant_invite_reward(self, email: str) -> None:
        """
        发放邀请码注册积分奖励（在使用了邀请码注册时额外发放）。
        开关开启且奖励积分>0时才执行，写入 credit_ledger 记录。
        """
        key = f"invite_reward:{email}"
        credits = await self.credit_account.grant_by_policy(email, "invite_reward", idempotency_key=key)
        if credits <= 0:
            return
        entry = CreditLedgerEntry(
            user_email=email,
            operation="invite_reward",
            client_platform="system",
            total_credits=credits,
            breakdown=[BreakdownItem(platform="invite_reward", credits=credits)],
            idempotency_key=f"ledger:{key}",
        )
        await self.ledger_repo.insert(entry)
        logger.info("[auth] invite_reward email=%s credits=%d", email, credits)

    @staticmethod
    def _needs_registration_recovery(user: dict) -> bool:
        if not user:
            return False
        if user.get("registration_status") and user.get("registration_status") != "complete":
            return True
        return not user.get("subscription_plan_code") or not user.get("plan_current_period_start")

    async def _complete_registration_setup(self, user: dict, invite_code: str = "") -> dict:
        email = user["email"]
        if not user.get("subscription_plan_code") or not user.get("plan_current_period_start"):
            await self.plan_service.init_user_plan(email, user.get("created_at") or datetime.now(timezone.utc))

        await self._grant_registration_reward(email)

        normalized_code = normalize_invite_code(invite_code or user.get("used_invite_code", ""))
        if normalized_code:
            await self._grant_invite_reward(email)
            await self.invite_repo.mark_code_used(normalized_code, email)

        await self.invite_repo.create_codes_for_user(email)
        await self.user_repo.mark_registration_complete(email)
        return await self.user_repo.find_by_email(email) or user

    async def _record_invalid_verify(self, email: str, client_ip: str) -> None:
        email_count = await self.security_repo.hit_counter(
            scope="email",
            key=email,
            path_group="auth_verify_failed",
            window_seconds=300,
        )
        ip_count = 0
        if client_ip and client_ip != "unknown":
            ip_count = await self.security_repo.hit_counter(
                scope="ip",
                key=client_ip,
                path_group="auth_verify_failed",
                window_seconds=300,
            )
        if email_count > 8 or ip_count > 50:
            raise AppException(429, "VERIFY_CODE_TOO_FREQUENT", "验证码错误次数过多，请稍后再试")

    async def _ensure_registration_enabled(self, email: str) -> None:
        registration_enabled = await self.plan_repo.get_registration_enabled()
        if not registration_enabled:
            logger.warning("[auth] registration disabled email=%s", email)
            raise AppException(403, "REGISTRATION_DISABLED", "未开放注册")

    async def _check_registration_limits(
        self,
        device_id: str,
        client_ip: str,
        hw_fingerprint: str,
        email: str,
    ) -> None:
        await self._ensure_registration_enabled(email)

        if not device_id:
            logger.error("[auth] registration called with empty device_id for email=%s", email)
            raise AppException(400, "INVALID_DEVICE_ID", "设备标识不合法，请更新客户端后重试")

        reg_limit_enabled = await self.plan_repo.get_registration_limit_enabled()
        if reg_limit_enabled:
            limit_count = await self.plan_repo.get_registration_limit_count()
            current_count = await self.plan_repo.get_current_user_count()
            if current_count >= limit_count:
                raise AppException(403, "REGISTRATION_CLOSED", "注册人数已达上限，暂停开放注册")

        max_accounts = await self.user_repo.get_max_accounts_per_device()
        device_count = await self.user_repo.count_by_device_id(device_id)
        ip_count = await self.user_repo.count_by_ip(client_ip) if client_ip not in ("unknown", "", None) else 0
        fp_count = await self.user_repo.count_by_hw_fingerprint(hw_fingerprint) if hw_fingerprint else 0

        device_blocked = device_count >= max_accounts
        ip_blocked = client_ip not in ("unknown", "", None) and ip_count >= max_accounts
        fp_blocked = bool(hw_fingerprint) and fp_count >= max_accounts

        if device_blocked or ip_blocked or fp_blocked:
            trigger = []
            if device_blocked:
                trigger.append(f"device_id={device_count}")
            if ip_blocked:
                trigger.append(f"ip={ip_count}")
            if fp_blocked:
                trigger.append(f"hw_fp={fp_count}")
            logger.warning(
                "[auth] reg limit reached — %s max=%d email=%s",
                ", ".join(trigger), max_accounts, email,
            )
            raise AppException(403, "REG_LIMIT_REACHED", "该设备或网络注册账号已达上限，无法继续注册")

    async def send_unified_code(
        self,
        email: str,
        client_ip: str = "unknown",
        client_platform: str = "unknown",
    ) -> int:
        """
        发送验证码前执行三道前置校验：
          1. 临时邮箱域名黑名单
          2. 同「邮箱 + IP + 客户端类型」发码冷却（60s，客户端类型间相互独立）
          3. 同 IP 每小时发码上限

        返回本次发码后的冷却秒数，供客户端展示倒计时。
        """
        email = self._normalize_email(email)
        logger.info("[auth] send_code email=%s ip=%s platform=%s", email, client_ip, client_platform)
        _check_disposable_email(email)
        await _check_send_rate_limit(email, client_ip, client_platform)

        fixed_code = _fixed_verification_code_for_email(email)
        if fixed_code:
            logger.info("[auth] fixed verification code test channel applied email=%s env=%s", email, settings.app_env)
        code = fixed_code or _generate_code()
        await self.code_repo.save(email, code, PURPOSE_UNIFIED)
        await self.email_service.send_verification_code(email, code, purpose="登录/注册")
        logger.info("[auth] email sent to %s", email)
        return RESEND_COOLDOWN_SEC

    async def verify_unified(
        self,
        email: str,
        code: str,
        client_platform: str,
        device_id: str = "",
        client_ip: str = "unknown",
        hw_fingerprint: str = "",
    ) -> dict:
        """
        验证码校验：
        - 老用户：直接签发 token，require_invite=False
        - 新用户：不签发 token，require_invite=True
        """
        email = self._normalize_email(email)
        device_id = (device_id or "").strip().lower()
        hw_fingerprint = (hw_fingerprint or "").strip().lower()
        logger.info("[auth] verify email=%s", email)
        valid = await self.code_repo.verify_and_delete(email, code, PURPOSE_UNIFIED)
        if not valid:
            logger.warning("[auth] invalid code for %s", email)
            await self._record_invalid_verify(email, client_ip)
            raise InvalidVerificationCodeException()

        user = await self.user_repo.find_by_email(email)
        if user:
            if not user.get("is_active", True):
                logger.warning("[auth] banned user login attempt email=%s", email)
                raise UserBannedException()
            logger.info("[auth] existing user login email=%s", email)
            if self._needs_registration_recovery(user):
                user = await self._complete_registration_setup(user)
            user = await self.plan_service.check_and_reset_credits(email, user)
            token = await self._issue_login_token(user["email"], user["tier"], client_platform)
            await self.invite_repo.create_codes_for_user(email)
            return {
                "token": token,
                "email": user["email"],
                "tier": user["tier"],
                "is_new_user": False,
                "require_invite": False,
            }
        else:
            await self._ensure_registration_enabled(email)

            # 检查注册总人数限制
            reg_limit_enabled = await self.plan_repo.get_registration_limit_enabled()
            if reg_limit_enabled:
                limit_count = await self.plan_repo.get_registration_limit_count()
                current_count = await self.plan_repo.get_current_user_count()
                if current_count >= limit_count:
                    logger.warning(
                        "[auth] registration limit reached count=%d limit=%d email=%s",
                        current_count, limit_count, email
                    )
                    raise AppException(403, "REGISTRATION_CLOSED", "注册人数已达上限，暂停开放注册")

            # 检查邀请码开关
            invite_enabled = await self.plan_repo.get_invite_code_enabled()
            logger.info("[auth] new user pending email=%s invite_enabled=%s", email, invite_enabled)
            await self.pending_registration_repo.save(email)

            if not invite_enabled:
                return await self._register_without_invite(
                    email,
                    client_platform,
                    device_id=device_id,
                    client_ip=client_ip,
                    hw_fingerprint=hw_fingerprint,
                )

            return {
                "token": "",
                "email": email,
                "tier": "",
                "is_new_user": True,
                "require_invite": True,
            }

    async def verify_invite(
        self,
        email: str,
        invite_code: str,
        device_id: str,
        client_ip: str,
        hw_fingerprint: str = "",
        client_platform: str = "",
    ) -> dict:
        """
        新用户邀请码校验并完成注册。
        三维联动封禁策略：
          设备码 / 硬件指纹 / 注册 IP 三者任意一个达到上限
          → 三者全部视为封禁，统一拒绝注册
        """
        email = self._normalize_email(email)
        invite_code = normalize_invite_code(invite_code)
        if len(invite_code) != INVITE_CODE_LENGTH:
            raise AppException(400, "INVALID_INVITE_CODE", "邀请码无效或已被使用")
        device_id = (device_id or "").strip().lower()
        hw_fingerprint = (hw_fingerprint or "").strip().lower()
        logger.info(
            "[auth] verify_invite email=%s code=%s device=%s ip=%s fp=%s",
            email, invite_code, device_id[:8] if device_id else "-",
            client_ip, hw_fingerprint[:12] if hw_fingerprint else "-",
        )

        # 实时检查邀请码开关（即使客户端跳过了邀请码界面，后端也会校验）
        invite_enabled = await self.plan_repo.get_invite_code_enabled()
        if not invite_enabled:
            logger.warning("[auth] invite code disabled, rejecting verify_invite for %s", email)
            raise AppException(400, "INVITE_CODE_DISABLED", "邀请码功能已关闭，请直接注册")

        await self._ensure_registration_enabled(email)

        pending = await self.pending_registration_repo.exists(email)
        if not pending:
            logger.warning("[auth] no pending invite state for %s", email)
            raise AppException(400, "INVITE_SESSION_EXPIRED", "邀请码填写会话已过期，请重新登录")

        user = await self.user_repo.find_by_email(email)
        if user and not user.get("is_active", True):
            logger.warning("[auth] user already exists email=%s", email)
            logger.warning("[auth] banned user invite-login attempt email=%s", email)
            raise UserBannedException()

        async with self.lock_repo.lock("registration_limits", ttl_seconds=20, wait_seconds=8):
            user = await self.user_repo.find_by_email(email)
            if user:
                new_user = user
            else:
                await self._check_registration_limits(device_id, client_ip, hw_fingerprint, email)
                invite = await self.invite_repo.find_available_code(invite_code)
                if not invite:
                    logger.warning("[auth] invalid or used invite code: %s", invite_code)
                    raise AppException(400, "INVALID_INVITE_CODE", "邀请码无效或已被使用")
                try:
                    new_user = await self.user_repo.create(
                        email=email,
                        reg_device_id=device_id,
                        reg_ip=client_ip,
                        reg_hw_fingerprint=hw_fingerprint,
                        invited_by=invite.get("owner_email", ""),
                        used_invite_code=invite_code,
                    )
                except DuplicateKeyError:
                    existing_for_code = await self.user_repo.find_by_invite_code(invite_code)
                    if existing_for_code and existing_for_code.get("email") == email:
                        new_user = existing_for_code
                    else:
                        logger.warning("[auth] invite code already claimed by another user: %s", invite_code)
                        raise AppException(400, "INVALID_INVITE_CODE", "邀请码无效或已被使用")
                logger.info("[auth] new user created email=%s", email)

        new_user = await self._complete_registration_setup(new_user, new_user.get("used_invite_code") or "")
        await self.pending_registration_repo.delete(email)

        token = await self._issue_login_token(new_user["email"], new_user["tier"], client_platform)
        return {
            "token": token,
            "email": new_user["email"],
            "tier": new_user["tier"],
            "is_new_user": True,
            "require_invite": False,
        }

    async def _register_without_invite(
        self,
        email: str,
        client_platform: str,
        device_id: str,
        client_ip: str,
        hw_fingerprint: str = "",
    ) -> dict:
        """
        邀请码关闭时直接完成注册，但仍执行设备/IP/硬件指纹注册限制。
        pending registration 状态已在 verify_unified 中保存，此处完成注册后清理。
        """
        email = self._normalize_email(email)
        device_id = (device_id or "").strip().lower()
        hw_fingerprint = (hw_fingerprint or "").strip().lower()
        user = await self.user_repo.find_by_email(email)
        if user:
            if self._needs_registration_recovery(user):
                user = await self._complete_registration_setup(user)
            token = await self._issue_login_token(user["email"], user["tier"], client_platform)
            return {
                "token": token,
                "email": user["email"],
                "tier": user["tier"],
                "is_new_user": False,
                "require_invite": False,
            }

        pending = await self.pending_registration_repo.exists(email)
        if not pending:
            raise AppException(400, "INVITE_SESSION_EXPIRED", "注册会话已过期，请重新登录")

        async with self.lock_repo.lock("registration_limits", ttl_seconds=20, wait_seconds=8):
            await self._check_registration_limits(device_id, client_ip, hw_fingerprint, email)
            new_user = await self.user_repo.create(
                email=email,
                reg_device_id=device_id,
                reg_ip=client_ip,
                reg_hw_fingerprint=hw_fingerprint,
            )
        logger.info("[auth] new user created (no invite) email=%s", email)
        new_user = await self._complete_registration_setup(new_user)
        await self.pending_registration_repo.delete(email)

        token = await self._issue_login_token(new_user["email"], new_user["tier"], client_platform)
        return {
            "token": token,
            "email": new_user["email"],
            "tier": new_user["tier"],
            "is_new_user": True,
            "require_invite": False,
        }

    async def get_my_invite_codes(self, email: str) -> list[dict]:
        """获取用户自己的邀请码列表（含使用状态）。"""
        codes = await self.invite_repo.create_codes_for_user(email)
        result = []
        for c in codes:
            used_by_raw = c.get("used_by")
            result.append({
                "code": c["code"],
                "is_used": c.get("is_used", False),
                "used_by": _mask_email(used_by_raw) if used_by_raw else None,
                "used_at": c.get("used_at"),
            })
        return result
