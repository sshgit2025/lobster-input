import asyncio
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import pytest

os.environ.setdefault("QDRANT_HOST", "127.0.0.1")
os.environ.setdefault("QDRANT_PORT", "6333")

from app.core.exceptions import AppException
from app.services.account.auth_service import AuthService


class _FakePendingRepo:
    def __init__(self, exists=True):
        self._exists = exists
        self.deleted = []

    async def exists(self, email):
        return self._exists

    async def delete(self, email):
        self.deleted.append(email)


class _FakePlanRepo:
    def __init__(self, registration_enabled=True):
        self.registration_enabled = registration_enabled

    async def get_registration_enabled(self):
        return self.registration_enabled

    async def get_invite_code_enabled(self):
        return True

    async def get_registration_limit_enabled(self):
        return False


class _FakePlanService:
    def __init__(self, user_repo):
        self.user_repo = user_repo

    async def init_user_plan(self, email, registered_at):
        user = self.user_repo.user
        user.update({
            "tier": "trial",
            "subscription_plan_code": "trial",
            "plan_current_period_start": registered_at,
            "plan_credits_total": 3000,
        })

    async def check_and_reset_credits(self, email, user):
        return user


class _FakeInviteRepo:
    def __init__(self):
        self.marked_used = []
        self.created_for = []

    async def find_available_code(self, code):
        return {"code": code, "owner_email": "owner@example.com", "is_used": False}

    async def mark_code_used(self, code, used_by_email):
        self.marked_used.append((code, used_by_email))
        return {"code": code, "used_by": used_by_email, "is_used": True}

    async def create_codes_for_user(self, owner_email):
        self.created_for.append(owner_email)
        return []


class _FakeCreditAccount:
    async def grant_by_policy(self, email, source, idempotency_key=""):
        return 0


class _FakeLedgerRepo:
    async def insert(self, entry):
        return True


class _FakeLockRepo:
    @asynccontextmanager
    async def lock(self, *args, **kwargs):
        yield


class _FakeUserRepo:
    def __init__(self, user=None, create_error=None):
        self.user = user
        self.create_error = create_error
        self.sessions = []
        self.registration_complete = []

    async def find_by_email(self, email):
        return self.user if self.user and self.user.get("email") == email else None

    async def find_by_invite_code(self, invite_code):
        return self.user if self.user and self.user.get("used_invite_code") == invite_code else None

    async def create(self, **kwargs):
        if self.create_error:
            raise self.create_error
        now = datetime.now(timezone.utc)
        self.user = {
            "email": kwargs["email"],
            "tier": "trial",
            "is_active": True,
            "created_at": now,
            "used_invite_code": kwargs.get("used_invite_code", ""),
            "registration_status": "created",
        }
        return self.user

    async def set_active_session(self, email, platform, session_id, expires_at=None, renewed_date=None):
        self.sessions.append((email, platform, session_id))
        return True

    async def mark_registration_complete(self, email):
        self.registration_complete.append(email)
        if self.user:
            self.user["registration_status"] = "complete"
        return True

    async def get_max_accounts_per_device(self):
        return 3

    async def count_by_device_id(self, device_id):
        return 0

    async def count_by_ip(self, ip):
        return 0

    async def count_by_hw_fingerprint(self, fingerprint):
        return 0


def _service(user_repo, pending_repo=None, invite_repo=None, plan_repo=None):
    svc = AuthService.__new__(AuthService)
    svc.user_repo = user_repo
    svc.pending_registration_repo = pending_repo or _FakePendingRepo()
    svc.invite_repo = invite_repo or _FakeInviteRepo()
    svc.plan_repo = plan_repo or _FakePlanRepo()
    svc.plan_service = _FakePlanService(user_repo)
    svc.credit_account = _FakeCreditAccount()
    svc.ledger_repo = _FakeLedgerRepo()
    svc.lock_repo = _FakeLockRepo()
    return svc


def test_verify_invite_rejects_when_registration_disabled():
    svc = _service(_FakeUserRepo(), plan_repo=_FakePlanRepo(registration_enabled=False))

    with pytest.raises(AppException) as exc:
        asyncio.run(svc.verify_invite(
            email="new@example.com",
            invite_code="ABCDEFGH",
            device_id="a" * 64,
            client_ip="127.0.0.1",
            client_platform="macos",
        ))

    assert exc.value.detail["code"] == "REGISTRATION_DISABLED"


def test_verify_invite_rejects_existing_user_without_pending_state():
    user_repo = _FakeUserRepo({
        "email": "user@example.com",
        "tier": "trial",
        "is_active": True,
        "subscription_plan_code": "trial",
        "plan_current_period_start": datetime.now(timezone.utc),
    })
    svc = _service(user_repo, pending_repo=_FakePendingRepo(exists=False))

    with pytest.raises(AppException) as exc:
        asyncio.run(svc.verify_invite(
            email="user@example.com",
            invite_code="ABCDEFGH",
            device_id="a" * 64,
            client_ip="127.0.0.1",
            client_platform="macos",
        ))

    assert exc.value.detail["code"] == "INVITE_SESSION_EXPIRED"
    assert user_repo.sessions == []


def test_invite_is_not_marked_used_when_user_create_fails():
    invite_repo = _FakeInviteRepo()
    user_repo = _FakeUserRepo(create_error=RuntimeError("insert failed"))
    svc = _service(user_repo, invite_repo=invite_repo)

    with pytest.raises(RuntimeError):
        asyncio.run(svc.verify_invite(
            email="new@example.com",
            invite_code="ABCDEFGH",
            device_id="a" * 64,
            client_ip="127.0.0.1",
            client_platform="macos",
        ))

    assert invite_repo.marked_used == []


def test_verify_invite_recovers_user_created_before_invite_status_update():
    created_at = datetime.now(timezone.utc)
    user_repo = _FakeUserRepo({
        "email": "new@example.com",
        "tier": "trial",
        "is_active": True,
        "created_at": created_at,
        "used_invite_code": "ABCDEFGH",
        "registration_status": "created",
    })
    pending_repo = _FakePendingRepo(exists=True)
    invite_repo = _FakeInviteRepo()
    svc = _service(user_repo, pending_repo=pending_repo, invite_repo=invite_repo)

    response = asyncio.run(svc.verify_invite(
        email="new@example.com",
        invite_code="ABCDEFGH",
        device_id="a" * 64,
        client_ip="127.0.0.1",
        client_platform="macos",
    ))

    assert response["email"] == "new@example.com"
    assert response["require_invite"] is False
    assert invite_repo.marked_used == [("ABCDEFGH", "new@example.com")]
    assert pending_repo.deleted == ["new@example.com"]
    assert user_repo.registration_complete == ["new@example.com"]
