"""Low-latency notification for realtime ASR final transcripts."""
from __future__ import annotations

import asyncio
import logging
from collections import defaultdict
from typing import Optional

import redis.asyncio as redis

from app.core.config import settings
from app.repositories.realtime_asr_session_repository import RealtimeASRSessionRepository

logger = logging.getLogger("voice_input.realtime_asr_session_waiter")

CHANNEL = "lobster:realtime_asr:completed"
_waiters: dict[str, set[asyncio.Event]] = defaultdict(set)
_waiters_lock = asyncio.Lock()


async def notify_realtime_asr_completed(asr_session_id: str) -> None:
    if not asr_session_id:
        return
    async with _waiters_lock:
        events = list(_waiters.get(asr_session_id, set()))
    for event in events:
        event.set()
    try:
        client = redis.from_url(settings.redis_url, decode_responses=True)
        try:
            await client.publish(CHANNEL, asr_session_id)
        finally:
            close = getattr(client, "aclose", None)
            if close is not None:
                await close()
            else:
                await client.close()
    except Exception as exc:
        logger.debug("[RealtimeASRWaiter] redis publish skipped: %s", exc)


async def wait_for_realtime_asr_final(
    *,
    asr_session_id: str,
    user_email: str,
    platform: str,
    timeout_ms: int = 500,
) -> Optional[dict]:
    repo = RealtimeASRSessionRepository()
    session = await repo.find_for_owner(
        asr_session_id=asr_session_id,
        user_email=user_email,
        platform=platform,
    )
    if session and session.get("status") in {"completed", "failed"}:
        return session

    timeout = max(0.0, timeout_ms / 1000.0)
    if timeout <= 0:
        return session

    local_event = asyncio.Event()
    async with _waiters_lock:
        _waiters[asr_session_id].add(local_event)

    redis_task = asyncio.create_task(_wait_for_redis(asr_session_id, timeout))
    local_task = asyncio.create_task(local_event.wait())
    try:
        await asyncio.wait(
            {local_task, redis_task},
            timeout=timeout,
            return_when=asyncio.FIRST_COMPLETED,
        )
    finally:
        for task in (local_task, redis_task):
            if not task.done():
                task.cancel()
        await asyncio.gather(local_task, redis_task, return_exceptions=True)
        async with _waiters_lock:
            bucket = _waiters.get(asr_session_id)
            if bucket is not None:
                bucket.discard(local_event)
                if not bucket:
                    _waiters.pop(asr_session_id, None)

    return await repo.find_for_owner(
        asr_session_id=asr_session_id,
        user_email=user_email,
        platform=platform,
    )


async def _wait_for_redis(asr_session_id: str, timeout: float) -> bool:
    client = None
    pubsub = None
    try:
        client = redis.from_url(settings.redis_url, decode_responses=True)
        pubsub = client.pubsub()
        await pubsub.subscribe(CHANNEL)
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            remaining = deadline - loop.time()
            if remaining <= 0:
                return False
            message = await pubsub.get_message(
                ignore_subscribe_messages=True,
                timeout=remaining,
            )
            if message and str(message.get("data") or "") == asr_session_id:
                return True
    except Exception as exc:
        logger.debug("[RealtimeASRWaiter] redis wait skipped: %s", exc)
        return False
    finally:
        if pubsub is not None:
            try:
                await pubsub.unsubscribe(CHANNEL)
                close = getattr(pubsub, "aclose", None)
                if close is not None:
                    await close()
                else:
                    await pubsub.close()
            except Exception:
                pass
        if client is not None:
            try:
                close = getattr(client, "aclose", None)
                if close is not None:
                    await close()
                else:
                    await client.close()
            except Exception:
                pass
