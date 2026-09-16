"""
登录态滑动续期测试。

覆盖:
  - 登录写入 expires_at = 上海时区 当天+15天 23:59:59,及 renewed_date
  - 过期 session 被 401;无 expires_at 的存量 session 放行
  - 平台 A 过期不影响平台 B
  - 续期同一天只触发一次;跨天节流缓存清空后可再次续期
  - 续期后 expires_at 前移
  - logout 清除该平台 session 后立即 401(其它平台不受影响)
  - WebSocket 鉴权共用 helper: 过期拒绝 / 通过后调度续期
  - SessionRenewalMiddleware 触发条件判定
"""
import asyncio
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import pytest
from fastapi.security import HTTPAuthorizationCredentials

from app.core.exceptions import UnauthorizedException
from app.middleware import auth as auth_middleware
from app.middleware import session_renewal as session_renewal_middleware
from app.services.account import session_service
from app.services.account.auth_service import AuthService, _create_token
from app.services.account.session_service import (
    SHANGHAI_TZ,
    compute_session_expiry,
    is_session_expired,
    schedule_renewal,
    shanghai_today,
    verify_websocket_user,
)


class _FakeUserRepo:
    def __init__(self, user=None):
        self.user = user or {}
        self.set_calls = []
        self.renew_calls = []

    async def find_by_email(self, email):
        return self.user

    async def set_active_session(self, email, platform, session_id, expires_at=None, renewed_date=None):
        self.set_calls.append((email, platform, session_id, expires_at, renewed_date))
        return True

    async def renew_active_session(self, email, platform, session_id, expires_at, renewed_date):
        self.renew_calls.append((email, platform, session_id, expires_at, renewed_date))
        session = (self.user.get("active_sessions") or {}).get(platform)
        if not isinstance(session, dict) or session.get("session_id") != session_id:
            return False
        session["expires_at"] = expires_at
        session["renewed_date"] = renewed_date
        return True

    async def clear_active_session(self, email, platform):
        (self.user.get("active_sessions") or {}).pop(platform, None)
        return True


class _FakeSecurityRepo:
    async def get_active_restriction(self, **_kwargs):
        return None


class _FakeWebSocket:
    def __init__(self, token):
        self.headers = {"authorization": f"Bearer {token}"}
        self.query_params = {}


def _credentials(token):
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


def _request(platform):
    return SimpleNamespace(headers={"X-Client-Platform": platform})


def _reset_throttle():
    session_service._renewal_throttle.clear()
    session_service._throttle_day = None


@pytest.fixture(autouse=True)
def _clean_throttle():
    _reset_throttle()
    yield
    _reset_throttle()


# ── 过期时间计算 ─────────────────────────────────────────────────────


def test_login_writes_expiry_today_plus_15_shanghai():
    repo = _FakeUserRepo()
    service = AuthService.__new__(AuthService)
    service.user_repo = repo

    asyncio.run(service._issue_login_token("user@example.com", "trial", "macos"))

    assert len(repo.set_calls) == 1
    _email, platform, _sid, expires_at, renewed_date = repo.set_calls[0]
    assert platform == "macos"

    today = shanghai_today()
    expiry_local = expires_at.astimezone(SHANGHAI_TZ)
    assert expiry_local.date() == today + timedelta(days=15)
    assert (expiry_local.hour, expiry_local.minute, expiry_local.second) == (23, 59, 59)
    assert renewed_date == today.isoformat()


def test_compute_session_expiry_is_utc_aware():
    expires_at = compute_session_expiry()
    assert expires_at.tzinfo == timezone.utc


def test_is_session_expired_semantics():
    now = datetime.now(timezone.utc)
    # 无 expires_at 的存量 session 视为有效
    assert is_session_expired({"session_id": "s"}) is False
    assert is_session_expired(None) is False
    assert is_session_expired({"expires_at": now + timedelta(days=1)}) is False
    assert is_session_expired({"expires_at": now - timedelta(seconds=5)}) is True
    # 兼容 Mongo 读出的 naive UTC datetime
    naive_past = (now - timedelta(days=1)).replace(tzinfo=None)
    assert is_session_expired({"expires_at": naive_past}) is True


# ── HTTP 鉴权: 过期拦截 / 存量放行 / 平台隔离 ────────────────────────


def _patched_auth(monkeypatch, user):
    monkeypatch.setattr(auth_middleware, "_user_repo", _FakeUserRepo(user))
    monkeypatch.setattr(auth_middleware, "_security_repo", _FakeSecurityRepo())


def test_verify_user_rejects_expired_session(monkeypatch):
    token = _create_token("user@example.com", "trial", "macos", "mac-session")
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {
            "macos": {
                "session_id": "mac-session",
                "expires_at": datetime.now(timezone.utc) - timedelta(minutes=1),
            },
        },
    }
    _patched_auth(monkeypatch, user)

    with pytest.raises(UnauthorizedException):
        asyncio.run(
            auth_middleware.verify_user(
                request=_request("macos"),
                credentials=_credentials(token),
            )
        )


def test_verify_user_allows_legacy_session_without_expiry(monkeypatch):
    token = _create_token("user@example.com", "trial", "macos", "mac-session")
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {"macos": {"session_id": "mac-session"}},
    }
    _patched_auth(monkeypatch, user)

    payload = asyncio.run(
        auth_middleware.verify_user(
            request=_request("macos"),
            credentials=_credentials(token),
        )
    )
    assert payload["sub"] == "user@example.com"


def test_platform_expiry_is_isolated(monkeypatch):
    mac_token = _create_token("user@example.com", "trial", "macos", "mac-session")
    ios_token = _create_token("user@example.com", "trial", "ios", "ios-session")
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {
            "macos": {
                "session_id": "mac-session",
                "expires_at": datetime.now(timezone.utc) - timedelta(days=1),
            },
            "ios": {
                "session_id": "ios-session",
                "expires_at": datetime.now(timezone.utc) + timedelta(days=10),
            },
        },
    }
    _patched_auth(monkeypatch, user)

    with pytest.raises(UnauthorizedException):
        asyncio.run(
            auth_middleware.verify_user(
                request=_request("macos"),
                credentials=_credentials(mac_token),
            )
        )
    ios_payload = asyncio.run(
        auth_middleware.verify_user(
            request=_request("ios"),
            credentials=_credentials(ios_token),
        )
    )
    assert ios_payload["platform"] == "ios"


# ── 续期节流与前移 ───────────────────────────────────────────────────


def test_schedule_renewal_once_per_day(monkeypatch):
    repo = _FakeUserRepo({
        "email": "user@example.com",
        "active_sessions": {"macos": {"session_id": "sid-1"}},
    })
    monkeypatch.setattr(session_service, "_user_repo", repo)

    async def main():
        task1 = schedule_renewal("user@example.com", "macos", "sid-1")
        assert task1 is not None
        await task1
        # 同日第二次: 直接被节流跳过,不再 update
        task2 = schedule_renewal("user@example.com", "macos", "sid-1")
        assert task2 is None

    asyncio.run(main())
    assert len(repo.renew_calls) == 1


def test_schedule_renewal_moves_expiry_forward(monkeypatch):
    old_expiry = datetime.now(timezone.utc) + timedelta(days=3)
    repo = _FakeUserRepo({
        "email": "user@example.com",
        "active_sessions": {
            "macos": {"session_id": "sid-1", "expires_at": old_expiry},
        },
    })
    monkeypatch.setattr(session_service, "_user_repo", repo)

    async def main():
        task = schedule_renewal("user@example.com", "macos", "sid-1")
        await task

    asyncio.run(main())
    new_expiry = repo.user["active_sessions"]["macos"]["expires_at"]
    assert new_expiry > old_expiry
    assert new_expiry == compute_session_expiry(shanghai_today())
    assert repo.user["active_sessions"]["macos"]["renewed_date"] == shanghai_today().isoformat()


def test_schedule_renewal_skips_replaced_session(monkeypatch):
    # 平台已重新登录(session 被覆盖) → 旧 token 的续期不作用到新 session
    repo = _FakeUserRepo({
        "email": "user@example.com",
        "active_sessions": {"macos": {"session_id": "new-session"}},
    })
    monkeypatch.setattr(session_service, "_user_repo", repo)

    async def main():
        task = schedule_renewal("user@example.com", "macos", "old-session")
        await task

    asyncio.run(main())
    assert "expires_at" not in repo.user["active_sessions"]["macos"]


def test_renewal_throttle_resets_on_new_day(monkeypatch):
    repo = _FakeUserRepo({
        "email": "user@example.com",
        "active_sessions": {"macos": {"session_id": "sid-1"}},
    })
    monkeypatch.setattr(session_service, "_user_repo", repo)

    day1 = shanghai_today()
    day2 = day1 + timedelta(days=1)

    async def main():
        monkeypatch.setattr(session_service, "shanghai_today", lambda: day1)
        task1 = schedule_renewal("user@example.com", "macos", "sid-1")
        await task1
        # 跨天: 节流缓存整体清空,再次触发续期
        monkeypatch.setattr(session_service, "shanghai_today", lambda: day2)
        task2 = schedule_renewal("user@example.com", "macos", "sid-1")
        assert task2 is not None
        await task2

    asyncio.run(main())
    assert len(repo.renew_calls) == 2
    # 缓存只保留当天(day2)的 key,防无限增长
    assert session_service._renewal_throttle == {("user@example.com", "macos"): day2}


# ── logout ───────────────────────────────────────────────────────────


def test_logout_clears_platform_session_then_401(monkeypatch):
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {
            "macos": {"session_id": "mac-session"},
            "ios": {"session_id": "ios-session"},
        },
    }
    repo = _FakeUserRepo(user)
    service = AuthService.__new__(AuthService)
    service.user_repo = repo
    _patched_auth(monkeypatch, user)
    monkeypatch.setattr(auth_middleware, "_user_repo", repo)

    mac_token = _create_token("user@example.com", "trial", "macos", "mac-session")
    ios_token = _create_token("user@example.com", "trial", "ios", "ios-session")

    # 退出前 macos 正常
    payload = asyncio.run(
        auth_middleware.verify_user(request=_request("macos"), credentials=_credentials(mac_token))
    )
    assert payload["platform"] == "macos"

    asyncio.run(service.logout("user@example.com", "macos"))

    # 退出后 macos 立即 401
    with pytest.raises(UnauthorizedException):
        asyncio.run(
            auth_middleware.verify_user(request=_request("macos"), credentials=_credentials(mac_token))
        )
    # 幂等: 重复退出不报错
    asyncio.run(service.logout("user@example.com", "macos"))
    # 其它平台不受影响
    ios_payload = asyncio.run(
        auth_middleware.verify_user(request=_request("ios"), credentials=_credentials(ios_token))
    )
    assert ios_payload["platform"] == "ios"


# ── WebSocket 鉴权共用 helper ────────────────────────────────────────


def test_ws_verify_rejects_expired_session(monkeypatch):
    token = _create_token("user@example.com", "trial", "macos", "mac-session")
    repo = _FakeUserRepo({
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {
            "macos": {
                "session_id": "mac-session",
                "expires_at": datetime.now(timezone.utc) - timedelta(days=1),
            },
        },
    })
    monkeypatch.setattr(session_service, "_user_repo", repo)

    with pytest.raises(UnauthorizedException):
        asyncio.run(verify_websocket_user(_FakeWebSocket(token), "macos"))


def test_ws_verify_pass_schedules_renewal(monkeypatch):
    token = _create_token("user@example.com", "trial", "ios", "ios-session")
    repo = _FakeUserRepo({
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {"ios": {"session_id": "ios-session"}},
    })
    monkeypatch.setattr(session_service, "_user_repo", repo)

    async def main():
        payload = await verify_websocket_user(_FakeWebSocket(token), "ios")
        assert payload["sub"] == "user@example.com"
        # 等待异步续期任务落库
        await asyncio.gather(*[
            t for t in asyncio.all_tasks() if t is not asyncio.current_task()
        ])

    asyncio.run(main())
    assert len(repo.renew_calls) == 1
    assert repo.renew_calls[0][1] == "ios"


# ── SessionRenewalMiddleware 触发条件 ────────────────────────────────


def _mw_request(path, token=None):
    headers = {}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    return SimpleNamespace(headers=headers, url=SimpleNamespace(path=path))


def test_middleware_schedules_for_bearer_api_request(monkeypatch):
    calls = []
    monkeypatch.setattr(
        session_renewal_middleware,
        "schedule_renewal",
        lambda email, platform, sid: calls.append((email, platform, sid)),
    )
    token = _create_token("user@example.com", "trial", "macos", "mac-session")

    session_renewal_middleware._maybe_schedule_renewal(_mw_request("/api/v1/hotwords", token), 200)
    assert calls == [("user@example.com", "macos", "mac-session")]


def test_middleware_skips_non_qualifying_requests(monkeypatch):
    calls = []
    monkeypatch.setattr(
        session_renewal_middleware,
        "schedule_renewal",
        lambda email, platform, sid: calls.append((email, platform, sid)),
    )
    token = _create_token("user@example.com", "trial", "macos", "mac-session")

    # 错误响应不算活跃
    session_renewal_middleware._maybe_schedule_renewal(_mw_request("/api/v1/hotwords", token), 401)
    # 管理端接口排除
    session_renewal_middleware._maybe_schedule_renewal(_mw_request("/api/v1/admin/reg/groups", token), 200)
    # 非 /api/ 路径排除
    session_renewal_middleware._maybe_schedule_renewal(_mw_request("/health", token), 200)
    # 无 Bearer 头(如内部服务间 X-API-Key 调用)排除
    session_renewal_middleware._maybe_schedule_renewal(_mw_request("/api/v1/hotwords"), 200)
    # 非法 JWT 排除
    session_renewal_middleware._maybe_schedule_renewal(_mw_request("/api/v1/hotwords", "not-a-jwt"), 200)

    assert calls == []
