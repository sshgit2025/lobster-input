"""
SessionService — 登录态滑动续期核心逻辑。

滑动窗口登录态设计:
  - 登录态失效条件只有两个: 用户主动退出(logout) / 连续 15 天未调用任何含登录态的业务接口
  - 活跃用户自动无限续期,不再受 JWT 硬过期踢出(jwt_expire_minutes 已调整为 10 年兜底)
  - 失效时间精确到"天": expires_at = 续期当天(Asia/Shanghai) + 15 天的 23:59:59,
    以 UTC datetime 存入 Mongo(active_sessions.{platform}.expires_at)
  - 同一 (账号, 平台) 一天最多续期一次: 内存 dict 节流,只保留"当天"的 key,
    跨天整体清空,防止无限增长
  - 续期通过 asyncio.create_task 异步延迟执行,时效性不敏感,绝不阻塞请求;
    续期 update 以 active_sessions.{platform}.session_id == session_id 条件过滤,
    防止旧 token 给新 session 续期
  - 无 expires_at 的存量 session 视为有效(平滑迁移,由续期链路补写)
  - 同一账号各平台(macos/ios/windows/android/harmony)的 session 各自独立管理
"""
from __future__ import annotations

import asyncio
import logging
from datetime import date, datetime, time, timedelta, timezone
from typing import Any, Optional
from zoneinfo import ZoneInfo

from fastapi import WebSocket
from jose import JWTError, jwt

from app.core.config import settings
from app.core.exceptions import UnauthorizedException, UserBannedException
from app.repositories.user_repository import UserRepository

logger = logging.getLogger("voice_input.session")

SHANGHAI_TZ = ZoneInfo("Asia/Shanghai")
# 滑动窗口天数: 连续 N 天无任何含登录态的接口调用则登录态失效
SESSION_SLIDING_WINDOW_DAYS = 15

_user_repo = UserRepository()

# 内存续期节流: (email, platform) → 上次续期的上海时区日期。
# 只保留"当天"的记录,跨天时整体清空(见 _reset_throttle_if_new_day),防止无限增长。
_renewal_throttle: dict[tuple[str, str], date] = {}
_throttle_day: Optional[date] = None


# ── 时间计算(统一以 Asia/Shanghai 为业务时区,存储为 UTC) ────────────


def shanghai_today() -> date:
    """当前 Asia/Shanghai 时区的日期。"""
    return datetime.now(SHANGHAI_TZ).date()


def compute_session_expiry(base_day: Optional[date] = None) -> datetime:
    """
    计算 session 过期时间: (base_day 或上海今天) + 15 天的 23:59:59(上海时区),
    转换为 UTC datetime 返回(Mongo 统一存 UTC),精确到天,不含更细粒度。
    """
    day = base_day if base_day is not None else shanghai_today()
    expiry_local = datetime.combine(
        day + timedelta(days=SESSION_SLIDING_WINDOW_DAYS),
        time(23, 59, 59),
        tzinfo=SHANGHAI_TZ,
    )
    return expiry_local.astimezone(timezone.utc)


def is_session_expired(session: Any) -> bool:
    """
    判断平台 session 是否已过期。
    无 expires_at 的存量 session 视为有效(平滑迁移,由续期链路补写 expires_at)。
    Mongo(motor 默认)读出的 datetime 为 naive UTC,需兼容 naive/aware 两种形态。
    """
    if not isinstance(session, dict):
        return False
    expires_at = session.get("expires_at")
    if not isinstance(expires_at, datetime):
        return False
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) > expires_at


# ── 异步延迟续期(带同日节流) ─────────────────────────────────────────


def _reset_throttle_if_new_day(today: date) -> None:
    """跨天时清空节流缓存,保证缓存只保留当天的 key,防止无限增长。"""
    global _throttle_day
    if _throttle_day != today:
        _renewal_throttle.clear()
        _throttle_day = today


def schedule_renewal(email: str, platform: str, session_id: str) -> Optional[asyncio.Task]:
    """
    异步调度一次登录态续期(asyncio.create_task,不阻塞当前请求)。
    同一 (账号, 平台) 一天(上海时区)最多触发一次,同日重复调用直接跳过。
    返回创建的 Task(被节流或参数缺失时返回 None),便于测试等待。
    """
    if not email or not platform or not session_id:
        return None
    today = shanghai_today()
    _reset_throttle_if_new_day(today)
    key = (email, platform)
    if _renewal_throttle.get(key) == today:
        return None
    _renewal_throttle[key] = today
    try:
        return asyncio.create_task(_renew_session(email, platform, session_id, today))
    except RuntimeError:
        # 无运行中事件循环(理论上不会发生);释放节流标记,后续请求可重试
        _renewal_throttle.pop(key, None)
        return None


async def _renew_session(email: str, platform: str, session_id: str, today: date) -> None:
    """
    实际执行续期: expires_at 前移到 今天+15天 23:59:59,并写 renewed_date。
    update 条件带 session_id 过滤 —— 若期间该平台已重新登录(session 被覆盖),
    旧 token 的续期请求不会作用到新 session。
    """
    try:
        expires_at = compute_session_expiry(today)
        renewed = await _user_repo.renew_active_session(
            email=email,
            platform=platform,
            session_id=session_id,
            expires_at=expires_at,
            renewed_date=today.isoformat(),
        )
        if renewed:
            logger.info(
                "[session] renewed email=%s platform=%s expires_at=%s",
                email, platform, expires_at.isoformat(),
            )
    except Exception as exc:
        # 续期失败绝不影响业务;释放节流标记,让当天后续请求有机会重试
        _renewal_throttle.pop((email, platform), None)
        logger.warning(
            "[session] renewal failed email=%s platform=%s err=%s",
            email, platform, exc,
        )


# ── WebSocket 鉴权(五端共用) ─────────────────────────────────────────


async def verify_websocket_user(websocket: WebSocket, platform: str) -> dict[str, Any]:
    """
    五端(macos/ios/windows/android/harmony)实时 ASR WebSocket 鉴权共用逻辑:
      JWT 解码 → 用户存在/未封禁 → token 平台与端点平台一致 → sid 与活跃 session 一致
      → 滑动窗口过期校验(无 expires_at 的存量 session 放行) → 异步调度续期
    """
    auth = websocket.headers.get("authorization", "")
    token = ""
    if auth.lower().startswith("bearer "):
        token = auth.split(" ", 1)[1].strip()
    if not token:
        token = websocket.query_params.get("token") or ""
    if not token:
        raise UnauthorizedException()
    try:
        payload = jwt.decode(token, settings.jwt_secret_key, algorithms=[settings.jwt_algorithm])
    except JWTError as exc:
        raise UnauthorizedException() from exc

    email = (payload.get("sub") or "").strip().lower()
    if not email or email == "api_key_user":
        raise UnauthorizedException()
    user = await _user_repo.find_by_email(email)
    if not user:
        raise UnauthorizedException("User not found")
    if not user.get("is_active", True):
        raise UserBannedException()
    token_platform = payload.get("platform") or ""
    token_session_id = payload.get("sid") or ""
    if not token_platform or not token_session_id:
        raise UnauthorizedException("Session expired")
    if token_platform != platform:
        raise UnauthorizedException("Session expired")
    active_session = (user.get("active_sessions") or {}).get(platform, {})
    active_session_id = active_session.get("session_id") if isinstance(active_session, dict) else None
    if not active_session_id or active_session_id != token_session_id:
        raise UnauthorizedException("Session expired")
    if is_session_expired(active_session):
        raise UnauthorizedException("Session expired")
    payload["sub"] = email
    # WS 也是"含登录态"的业务接口,鉴权通过即异步调度续期(同日节流)
    schedule_renewal(email, platform, token_session_id)
    return payload
