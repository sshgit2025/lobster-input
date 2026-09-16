"""Streaming response helpers for client process endpoints."""
from __future__ import annotations

import asyncio
import json
from typing import Any, Awaitable, Callable

from fastapi.responses import StreamingResponse

from app.models.schemas import AudioTranscribeResponse

StreamEventCallback = Callable[[str, dict[str, Any]], Awaitable[None]]


def sse_event(event: str, payload: dict[str, Any]) -> str:
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event}\ndata: {data}\n\n"


def audio_process_stream(
    runner: Callable[[StreamEventCallback], Awaitable[AudioTranscribeResponse]],
) -> StreamingResponse:
    async def generate():
        queue: asyncio.Queue[tuple[str, dict[str, Any]]] = asyncio.Queue()

        async def emit_event(event: str, payload: dict[str, Any]) -> None:
            if event:
                await queue.put((event, payload))

        task = asyncio.create_task(runner(emit_event))
        while True:
            if task.done() and queue.empty():
                break
            try:
                event, payload = await asyncio.wait_for(queue.get(), timeout=0.1)
            except asyncio.TimeoutError:
                continue
            yield sse_event(event, payload)

        try:
            response = await task
        except Exception as exc:
            yield sse_event("error", {"message": str(exc)})
            return

        body = response.model_dump(mode="json")
        yield sse_event("final", body)

    return StreamingResponse(
        generate(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
