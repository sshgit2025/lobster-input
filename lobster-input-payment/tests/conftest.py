"""payment 测试共享 fixture。

P3 权益收敛后,payment 履约(subscription_callback / credits_topup_callback)不再直写主库权益,
改调后端 EntitlementService.grant_paid/grant_paid_topup(HTTP)。测试环境无真实后端,这里 mock 这两个
调用,并模拟"后端对(fake)主库的权益写入",使 payment 侧测试(订单/续费补单/取消旧订阅/加购校验)在
"权益由后端授予"的前提下继续验证 payment 自身职责。权益写入的逐字段等价性由 backend 209 测试覆盖。
"""
from datetime import datetime, timedelta, timezone

import pytest

from app.api.v1 import payments
from app.api.v1.payments import _common as _pay_common
from app.api.v1.payments import callback as _pay_callback


# 计费域已由单文件 payments.py 拆分为 payments/ 包:_grant_paid_backend /
# _grant_paid_topup_backend 由 callback 域端点按裸名从其自身命名空间调用。故打桩须落到
# 承载该绑定的 callback(与共享内核 _common、包 __init__)模块上,单打包属性对子模块内调用不生效。
_ENTITLEMENT_PATCH_MODULES = (payments, _pay_common, _pay_callback)


def _patch_entitlement(monkeypatch, name, value):
    for _m in _ENTITLEMENT_PATCH_MODULES:
        if hasattr(_m, name):
            monkeypatch.setattr(_m, name, value, raising=False)


@pytest.fixture(autouse=True)
def _mock_backend_entitlement(monkeypatch):
    async def fake_grant_paid(payload):
        db = payments.get_main_db()
        email = payload["email"]
        plan = payload["plan_code"]
        change_mode = payload.get("change_mode")
        now = datetime.now(timezone.utc)
        user = await db["users"].find_one({"email": email})
        if change_mode == "renew":
            base = (user or {}).get("subscription_expires_at")
            base = base if (base and base > now) else now
            expires = base + timedelta(days=30)
            await db["users"].update_one({"email": email}, {"$set": {
                "subscription_expires_at": expires, "plan_expires_at": expires,
                "subscription_status": "active", "subscription_auto_renew": bool(payload.get("auto_renew")),
                "subscription_source": "paid",
            }})
        else:
            plan_configs = (await db["system_config"].find_one({"key": "plan_configs"}) or {}).get("value", {})
            credits = int((plan_configs.get(plan) or {}).get("credits", 0) or 0)
            expires = now + timedelta(days=30)
            await db["users"].update_one({"email": email}, {"$set": {
                "tier": plan, "plan_code": plan, "subscription_plan_code": plan,
                "subscription_started_at": now, "subscription_expires_at": expires, "plan_expires_at": expires,
                "subscription_status": "active", "subscription_auto_renew": bool(payload.get("auto_renew")),
                "plan_credits_total": credits, "plan_credits_used": 0,
                "credits_total": credits, "credits_used": 0, "subscription_source": "paid",
            }})
        return {"status": "applied", "change_mode": change_mode,
                "subscription_expires_at": expires.isoformat(), "entitlement_started_at": now.isoformat()}

    async def fake_grant_paid_topup(payload):
        db = payments.get_main_db()
        exp = payload.get("expires_at")
        if isinstance(exp, str):
            exp = datetime.fromisoformat(exp.replace("Z", "+00:00"))
        await db["credit_grants"].insert_one({
            "user_email": payload["email"], "source": "paid_topup", "credit_type": "paid_topup",
            "amount_total": payload["amount"], "amount_used": 0, "expires_at": exp,
            "metadata": {"payment_event_id": payload.get("payment_event_id"),
                         "subscription_plan_code": payload.get("plan_code")},
        })
        return {"status": "applied", "grant_id": "fake_grant_id",
                "amount": payload["amount"], "credit_type": "paid_topup"}

    _patch_entitlement(monkeypatch, "_grant_paid_backend", fake_grant_paid)
    _patch_entitlement(monkeypatch, "_grant_paid_topup_backend", fake_grant_paid_topup)
