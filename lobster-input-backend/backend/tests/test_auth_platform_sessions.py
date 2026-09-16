import asyncio
from types import SimpleNamespace

import pytest
from fastapi.security import HTTPAuthorizationCredentials
from jose import jwt
from datetime import datetime, timedelta, timezone

from app.core.config import settings
from app.core.exceptions import UnauthorizedException
from app.middleware import auth as auth_middleware
from app.services.account.auth_service import AuthService, _create_token


class _FakeUserRepo:
    def __init__(self, user=None):
        self.user = user or {}
        self.sessions = []
        self.session_expiries = []

    async def find_by_email(self, email):
        return self.user

    async def set_active_session(self, email, platform, session_id, expires_at=None, renewed_date=None):
        self.sessions.append((email, platform, session_id))
        self.session_expiries.append((expires_at, renewed_date))
        return True


class _FakeSecurityRepo:
    async def get_active_restriction(self, **_kwargs):
        return None


def _decode(token):
    return jwt.decode(
        token,
        settings.jwt_secret_key,
        algorithms=[settings.jwt_algorithm],
    )


def _credentials(token):
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


def _request(platform):
    return SimpleNamespace(headers={"X-Client-Platform": platform})


def test_issue_login_token_records_platform_session():
    repo = _FakeUserRepo()
    service = AuthService.__new__(AuthService)
    service.user_repo = repo

    token = asyncio.run(service._issue_login_token("user@example.com", "trial", "macos"))
    payload = _decode(token)

    assert payload["sub"] == "user@example.com"
    assert payload["tier"] == "trial"
    assert payload["platform"] == "macos"
    assert payload["sid"]
    assert repo.sessions == [("user@example.com", "macos", payload["sid"])]


def test_verify_any_rejects_stale_same_platform_session(monkeypatch):
    old_token = _create_token("user@example.com", "trial", "macos", "old-session")
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {"macos": {"session_id": "new-session"}},
    }
    monkeypatch.setattr(auth_middleware, "_user_repo", _FakeUserRepo(user))
    monkeypatch.setattr(auth_middleware, "_security_repo", _FakeSecurityRepo())

    with pytest.raises(UnauthorizedException):
        asyncio.run(
            auth_middleware.verify_any(
                request=_request("macos"),
                api_key=None,
                credentials=_credentials(old_token),
            )
        )


def test_verify_any_rejects_legacy_token_without_session_claims(monkeypatch):
    payload = {
        "sub": "user@example.com",
        "tier": "trial",
        "exp": datetime.now(timezone.utc) + timedelta(minutes=5),
    }
    legacy_token = jwt.encode(payload, settings.jwt_secret_key, algorithm=settings.jwt_algorithm)
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {},
    }
    monkeypatch.setattr(auth_middleware, "_user_repo", _FakeUserRepo(user))
    monkeypatch.setattr(auth_middleware, "_security_repo", _FakeSecurityRepo())

    with pytest.raises(UnauthorizedException):
        asyncio.run(
            auth_middleware.verify_any(
                request=_request("macos"),
                api_key=None,
                credentials=_credentials(legacy_token),
            )
        )


def test_verify_any_allows_independent_platform_sessions(monkeypatch):
    mac_token = _create_token("user@example.com", "trial", "macos", "mac-session")
    ios_token = _create_token("user@example.com", "trial", "ios", "ios-session")
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {
            "macos": {"session_id": "mac-session"},
            "ios": {"session_id": "ios-session"},
        },
    }
    monkeypatch.setattr(auth_middleware, "_user_repo", _FakeUserRepo(user))
    monkeypatch.setattr(auth_middleware, "_security_repo", _FakeSecurityRepo())

    mac_payload = asyncio.run(
        auth_middleware.verify_any(
            request=_request("macos"),
            api_key=None,
            credentials=_credentials(mac_token),
        )
    )
    ios_payload = asyncio.run(
        auth_middleware.verify_any(
            request=_request("ios"),
            api_key=None,
            credentials=_credentials(ios_token),
        )
    )

    assert mac_payload["platform"] == "macos"
    assert ios_payload["platform"] == "ios"


def test_verify_any_rejects_token_used_from_other_platform(monkeypatch):
    token = _create_token("user@example.com", "trial", "macos", "mac-session")
    user = {
        "email": "user@example.com",
        "is_active": True,
        "active_sessions": {"macos": {"session_id": "mac-session"}},
    }
    monkeypatch.setattr(auth_middleware, "_user_repo", _FakeUserRepo(user))
    monkeypatch.setattr(auth_middleware, "_security_repo", _FakeSecurityRepo())

    with pytest.raises(UnauthorizedException):
        asyncio.run(
            auth_middleware.verify_any(
                request=_request("ios"),
                api_key=None,
                credentials=_credentials(token),
            )
        )
