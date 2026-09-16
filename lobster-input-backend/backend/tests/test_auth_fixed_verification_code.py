import asyncio
import os

os.environ.setdefault("QDRANT_HOST", "127.0.0.1")
os.environ.setdefault("QDRANT_PORT", "6333")

from app.core.config import settings
from app.services.account import auth_service as auth_module
from app.services.account.auth_service import AuthService, PURPOSE_UNIFIED, _fixed_verification_code_for_email


class _FakeCodeRepo:
    def __init__(self):
        self.saved = []
        self.current = {}

    async def save(self, email, code, purpose):
        self.saved.append((email, code, purpose))
        self.current[(email, purpose)] = code

    async def verify_and_delete(self, email, code, purpose):
        key = (email, purpose)
        if self.current.get(key) != code:
            return False
        del self.current[key]
        return True


class _FakeEmailService:
    def __init__(self):
        self.sent = []

    async def send_verification_code(self, to, code, purpose="验证"):
        self.sent.append((to, code, purpose))


class _FakeUserRepo:
    async def find_by_email(self, email):
        return None


class _FakePendingRegistrationRepo:
    def __init__(self):
        self.saved = []

    async def save(self, email):
        self.saved.append(email)


class _FakePlanRepo:
    async def get_registration_enabled(self):
        return True

    async def get_registration_limit_enabled(self):
        return False

    async def get_invite_code_enabled(self):
        return True


def _configure_fixed_code(monkeypatch, *, app_env="preview", enabled=True, emails="414587170@qq.com", code="123456"):
    monkeypatch.setattr(settings, "app_env", app_env)
    monkeypatch.setattr(settings, "auth_fixed_verify_code_enabled", enabled)
    monkeypatch.setattr(settings, "auth_fixed_verify_code_emails", emails)
    monkeypatch.setattr(settings, "auth_fixed_verify_code_value", code)


def test_fixed_verification_code_requires_non_production_env(monkeypatch):
    _configure_fixed_code(monkeypatch, app_env="production")

    assert _fixed_verification_code_for_email("414587170@qq.com") is None


def test_fixed_verification_code_requires_explicit_email_match(monkeypatch):
    _configure_fixed_code(monkeypatch, emails="414587170@qq.com")

    assert _fixed_verification_code_for_email("414587170@qq.com") == "123456"
    assert _fixed_verification_code_for_email("other@example.com") is None


def test_send_unified_code_saves_and_sends_fixed_code(monkeypatch):
    _configure_fixed_code(monkeypatch)
    monkeypatch.setattr(auth_module, "_check_send_rate_limit", lambda email, client_ip, client_platform: _noop())
    service = AuthService.__new__(AuthService)
    service.code_repo = _FakeCodeRepo()
    service.email_service = _FakeEmailService()

    asyncio.run(service.send_unified_code("  414587170@qq.com  ", "127.0.0.1"))

    assert service.code_repo.saved == [("414587170@qq.com", "123456", PURPOSE_UNIFIED)]
    assert service.email_service.sent == [("414587170@qq.com", "123456", "登录/注册")]
    assert asyncio.run(service.code_repo.verify_and_delete("414587170@qq.com", "123456", PURPOSE_UNIFIED)) is True
    assert asyncio.run(service.code_repo.verify_and_delete("414587170@qq.com", "123456", PURPOSE_UNIFIED)) is False


def test_fixed_code_flows_into_new_user_registration_branch(monkeypatch):
    _configure_fixed_code(monkeypatch)
    monkeypatch.setattr(auth_module, "_check_send_rate_limit", lambda email, client_ip, client_platform: _noop())
    service = AuthService.__new__(AuthService)
    service.code_repo = _FakeCodeRepo()
    service.email_service = _FakeEmailService()
    service.user_repo = _FakeUserRepo()
    service.plan_repo = _FakePlanRepo()
    service.pending_registration_repo = _FakePendingRegistrationRepo()

    asyncio.run(service.send_unified_code("414587170@qq.com", "127.0.0.1"))
    response = asyncio.run(service.verify_unified(
        "414587170@qq.com",
        "123456",
        "macos",
        device_id="",
        client_ip="127.0.0.1",
        hw_fingerprint="",
    ))

    assert response == {
        "token": "",
        "email": "414587170@qq.com",
        "tier": "",
        "is_new_user": True,
        "require_invite": True,
    }
    assert service.pending_registration_repo.saved == ["414587170@qq.com"]
    assert asyncio.run(service.code_repo.verify_and_delete("414587170@qq.com", "123456", PURPOSE_UNIFIED)) is False


async def _noop():
    return None
