"""管理端套餐 / 订阅 内部端点(/api/v1/config/plan-admin/*)单测。

用内存 FakeDB 替换 get_db,直接调用端点 handler(绕过 HMAC),验证:
- plan-configs 读写走 PlanRepository(唯一 DEFAULT / 清洗),reset_period=none 语义保留;
- assign 走 PlanService.activate_subscription(而非自算)并写审计日志 / 订阅事件;
- auto-renew 开关更新与免费套餐拒绝。
"""
import asyncio
import re
from datetime import datetime, timedelta, timezone

import pytest

from app.api.v1 import plan_admin
from app.repositories import plan_repository, user_repository, credit_grant_repository


# ── 内存 Mongo 替身 ────────────────────────────────────────
def _match(doc: dict, query: dict) -> bool:
    for key, cond in query.items():
        if key == "$or":
            if not any(_match(doc, c) for c in cond):
                return False
            continue
        if key == "$and":
            if not all(_match(doc, c) for c in cond):
                return False
            continue
        value = doc.get(key)
        if isinstance(cond, dict):
            for op, operand in cond.items():
                if op == "$regex":
                    pattern = operand if isinstance(operand, str) else operand.pattern
                    flags = re.IGNORECASE if "i" in (cond.get("$options") or "") else 0
                    if value is None or not re.search(pattern, str(value), flags):
                        return False
                elif op == "$options":
                    continue
                elif op == "$exists":
                    if (key in doc) != bool(operand):
                        return False
                elif op == "$gt":
                    if not (value is not None and value > operand):
                        return False
                elif op == "$gte":
                    if not (value is not None and value >= operand):
                        return False
                elif op == "$lt":
                    if not (value is not None and value < operand):
                        return False
                elif op == "$lte":
                    if not (value is not None and value <= operand):
                        return False
                elif op == "$ne":
                    if value == operand:
                        return False
                elif op == "$in":
                    if value not in operand:
                        return False
                elif op == "$nin":
                    if value in operand:
                        return False
        else:
            if value != cond:
                return False
    return True


class _Result:
    def __init__(self, matched=0, modified=0):
        self.matched_count = matched
        self.modified_count = modified
        self.acknowledged = True


class _Cursor:
    def __init__(self, docs):
        self._docs = docs

    def sort(self, *args, **kwargs):
        return self

    def skip(self, n):
        self._docs = self._docs[n:]
        return self

    def limit(self, n):
        self._docs = self._docs[:n]
        return self

    async def to_list(self, length=None):
        return [dict(d) for d in self._docs]


class _Aggregate:
    async def to_list(self, length=None):
        return []


class _Collection:
    def __init__(self):
        self.docs = []

    async def find_one(self, query, projection=None):
        for d in self.docs:
            if _match(d, query):
                return dict(d)
        return None

    def find(self, query, projection=None):
        return _Cursor([d for d in self.docs if _match(d, query)])

    async def count_documents(self, query):
        return sum(1 for d in self.docs if _match(d, query))

    async def insert_one(self, doc):
        self.docs.append(dict(doc))
        return _Result(1, 1)

    async def update_one(self, query, update, upsert=False):
        for d in self.docs:
            if _match(d, query):
                d.update(update.get("$set", {}))
                return _Result(1, 1)
        if upsert:
            doc = {k: v for k, v in query.items() if not isinstance(v, dict)}
            doc.update(update.get("$set", {}))
            self.docs.append(doc)
            return _Result(0, 0)
        return _Result(0, 0)

    async def update_many(self, query, update):
        n = 0
        for d in self.docs:
            if _match(d, query):
                d.update(update.get("$set", {}))
                n += 1
        return _Result(n, n)

    async def delete_many(self, query):
        self.docs = [d for d in self.docs if not _match(d, query)]
        return _Result()

    def aggregate(self, pipeline):
        return _Aggregate()


class _FakeDB:
    def __init__(self):
        self.cols = {}

    def __getitem__(self, name):
        return self.cols.setdefault(name, _Collection())


@pytest.fixture
def fake_db(monkeypatch):
    db = _FakeDB()
    for mod in (plan_admin, plan_repository, user_repository, credit_grant_repository):
        monkeypatch.setattr(mod, "get_db", lambda: db, raising=True)
    return db


def _run(coro):
    return asyncio.run(coro)


# ── plan-configs 读写 ──────────────────────────────────────
def test_get_plan_configs_returns_defaults_and_policy(fake_db):
    resp = _run(plan_admin.get_plan_configs(_={}))
    assert set(resp.keys()) == {"plan_configs", "defaults", "bonus_credit_policy"}
    # trial reset_period=none 语义保留
    assert resp["plan_configs"]["trial"]["reset_period"] == "none"
    assert resp["defaults"]["trial"]["validity_count"] == 7
    assert "registration_reward" in resp["bonus_credit_policy"]


def test_save_plan_configs_persists_cleaned(fake_db):
    req = plan_admin.PlanConfigsRequest(
        plan_configs={"lite": {"code": "lite", "credits": 12345, "paid": True, "reset_period": "month"}},
        bonus_credit_policy={"registration_reward": {"enabled": True, "credits": 100, "expires_days": 30}},
    )
    resp = _run(plan_admin.save_plan_configs(req, _={}))
    assert resp["message"] == "套餐配置已保存"
    stored = _run(plan_admin.get_plan_configs(_={}))
    assert stored["plan_configs"]["lite"]["credits"] == 12345
    assert stored["bonus_credit_policy"]["registration_reward"]["credits"] == 100


# ── assign 走 PlanService.activate_subscription ────────────
def _seed_user(fake_db, **overrides):
    now = datetime.now(timezone.utc)
    user = {
        "email": "u@example.com",
        "subscription_plan_code": "free",
        "plan_code": "free",
        "tier": "free",
        "subscription_expires_at": None,
        "plan_current_period_end": now + timedelta(days=3),
        "plan_credits_total": 500,
        "plan_credits_used": 0,
        "created_at": now,
    }
    user.update(overrides)
    fake_db["users"].docs.append(user)
    return user


def test_assign_activate_now_uses_plan_service(fake_db):
    _seed_user(fake_db)
    req = plan_admin.AssignPlanRequest(
        email="u@example.com", plan_code="lite", billing_cycle="monthly",
        change_mode="activate_now", auto_renew=False, admin_email="admin@x.com",
    )
    resp = _run(plan_admin.assign_plan(req, _={}))
    assert resp["message"] == "已处理 u@example.com 的订阅操作"
    user = fake_db["users"].docs[0]
    # PlanService.activate_subscription 写入的字段(非管理端自算)
    assert user["subscription_plan_code"] == "lite"
    assert user["plan_credits_total"] == 9000
    assert user["subscription_expires_at"] is not None
    assert user["plan_current_period_end"] is not None
    # 审计日志 + 订阅事件副作用保留
    assert len(fake_db["admin_operation_log"].docs) == 1
    assert fake_db["admin_operation_log"].docs[0]["admin_email"] == "admin@x.com"
    events = fake_db["subscription_events"].docs
    assert len(events) == 1
    assert events[0]["to_plan_code"] == "lite"
    assert events[0]["event_type"] == "activate_now"


def test_assign_rejects_unknown_plan(fake_db):
    _seed_user(fake_db)
    req = plan_admin.AssignPlanRequest(email="u@example.com", plan_code="nope", admin_email="a@x.com")
    with pytest.raises(Exception) as exc:
        _run(plan_admin.assign_plan(req, _={}))
    assert getattr(exc.value, "status_code", None) == 400


def test_assign_renew_extends_expiry(fake_db):
    now = datetime.now(timezone.utc)
    future = now + timedelta(days=10)
    _seed_user(
        fake_db,
        subscription_plan_code="lite", plan_code="lite", tier="lite",
        paid=True, subscription_expires_at=future, plan_credits_total=9000,
    )
    req = plan_admin.AssignPlanRequest(
        email="u@example.com", plan_code="lite", billing_cycle="monthly",
        change_mode="renew", auto_renew=True, admin_email="a@x.com",
    )
    _run(plan_admin.assign_plan(req, _={}))
    user = fake_db["users"].docs[0]
    # 续费从当前到期日往后顺延一个月(> 原到期日)
    assert plan_admin._normalize_dt(user["subscription_expires_at"]) > future


# ── auto-renew 开关 ────────────────────────────────────────
def test_auto_renew_toggle_and_free_rejected(fake_db):
    now = datetime.now(timezone.utc)
    _seed_user(
        fake_db,
        subscription_plan_code="lite", plan_code="lite", tier="lite",
        subscription_expires_at=now + timedelta(days=10),
    )
    req = plan_admin.AutoRenewRequest(email="u@example.com", auto_renew=True, admin_email="a@x.com")
    resp = _run(plan_admin.update_auto_renew(req, _={}))
    assert resp["message"] == "自动续费状态已更新"
    assert fake_db["users"].docs[0]["subscription_auto_renew"] is True
    assert len(fake_db["subscription_events"].docs) == 1

    # 免费套餐不能开启自动续费
    fake_db["users"].docs.clear()
    _seed_user(fake_db)  # free plan
    bad = plan_admin.AutoRenewRequest(email="u@example.com", auto_renew=True, admin_email="a@x.com")
    with pytest.raises(Exception) as exc:
        _run(plan_admin.update_auto_renew(bad, _={}))
    assert getattr(exc.value, "status_code", None) == 400
