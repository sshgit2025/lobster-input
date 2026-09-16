import asyncio
import os
from datetime import datetime, timedelta, timezone

os.environ.setdefault("QDRANT_HOST", "127.0.0.1")
os.environ.setdefault("QDRANT_PORT", "6333")

from app.repositories import security_repository
from app.repositories.security_repository import SecurityRepository


class _FakeAccountIpSeenCollection:
    def __init__(self):
        self.docs = {}

    async def update_one(self, query, update, upsert=False):
        key = (query["user_email"], query["ip"])
        doc = self.docs.get(key)
        if doc is None:
            if not upsert:
                return
            doc = dict(query)
            doc.update(update.get("$setOnInsert", {}))
            self.docs[key] = doc
        doc.update(update.get("$set", {}))

    async def count_documents(self, query):
        since = query["last_seen_at"]["$gte"]
        user_email = query["user_email"]
        return sum(
            1
            for doc in self.docs.values()
            if doc.get("user_email") == user_email
            and doc.get("last_seen_at") is not None
            and doc["last_seen_at"] >= since
        )


def _run(coro):
    return asyncio.run(coro)


def test_count_account_ips_only_counts_recent_ip_observations(monkeypatch):
    account_ip_seen = _FakeAccountIpSeenCollection()
    monkeypatch.setattr(
        security_repository,
        "get_db",
        lambda: {"security_account_ip_seen": account_ip_seen},
    )
    repo = SecurityRepository()
    now = datetime.now(timezone.utc)
    old = now - timedelta(minutes=20)

    for index in range(10):
        _run(repo._touch_account_ip_seen(
            user_email="user@example.com",
            ip=f"10.0.0.{index}",
            user_agent="test",
            now=old,
        ))
    _run(repo._touch_account_ip_seen(
        user_email="user@example.com",
        ip="10.0.1.1",
        user_agent="test",
        now=now,
    ))

    assert _run(repo.count_account_ips(user_email="user@example.com", window_seconds=600)) == 1


def test_account_ip_observation_is_unique_per_account_and_ip(monkeypatch):
    account_ip_seen = _FakeAccountIpSeenCollection()
    monkeypatch.setattr(
        security_repository,
        "get_db",
        lambda: {"security_account_ip_seen": account_ip_seen},
    )
    repo = SecurityRepository()
    now = datetime.now(timezone.utc)

    _run(repo._touch_account_ip_seen(
        user_email="user@example.com",
        ip="10.0.1.1",
        user_agent="first",
        now=now - timedelta(minutes=5),
    ))
    _run(repo._touch_account_ip_seen(
        user_email="user@example.com",
        ip="10.0.1.1",
        user_agent="second",
        now=now,
    ))

    assert _run(repo.count_account_ips(user_email="user@example.com", window_seconds=600)) == 1
    assert len(account_ip_seen.docs) == 1
