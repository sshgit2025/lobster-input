"""
UsageQueue — 全局异步用量统计队列。

设计要点：
  - emit() 为同步非阻塞函数，主流程调用后立即返回，不影响响应延迟
  - usage_worker() 为后台协程，在 FastAPI lifespan 中以 asyncio.create_task 启动
  - 队列容量上限 10000，满时丢弃并记录警告（避免内存无限增长）
  - Worker 逐条消费，每条持久化失败时记录错误并继续，不中断 Worker
"""
import asyncio
import logging
from typing import Optional

from app.data.usage.models import UsageEvent

logger = logging.getLogger("voice_input.usage.queue")

_MAX_QUEUE_SIZE = 10_000
_usage_queue: asyncio.Queue = asyncio.Queue(maxsize=_MAX_QUEUE_SIZE)

_worker_task: Optional[asyncio.Task] = None


def emit(event: UsageEvent) -> None:
    """
    非阻塞投递用量事件到队列。

    主流程中调用此函数，不会阻塞当前协程。
    队列满时丢弃事件并记录警告。
    """
    try:
        _usage_queue.put_nowait(event)
    except asyncio.QueueFull:
        logger.warning(
            "Usage queue full (%d), dropping event: platform=%s user=%s op=%s",
            _MAX_QUEUE_SIZE, event.platform, event.user_email, event.operation,
        )


async def usage_worker() -> None:
    """
    后台协程，持续从队列消费 UsageEvent 并写入 MongoDB。

    在 FastAPI lifespan 中以 asyncio.create_task() 启动。
    每条事件持久化失败时记录错误并继续处理下一条，保证 Worker 不中断。
    """
    from app.data.usage.repository import UsageRepository
    repo = UsageRepository()
    logger.info("UsageWorker started.")

    while True:
        event: UsageEvent = await _usage_queue.get()
        try:
            await repo.increment(event)
            logger.debug(
                "UsageWorker: persisted platform=%s user=%s op=%s date=%s",
                event.platform, event.user_email, event.operation, event.date,
            )
        except Exception as e:
            logger.error(
                "UsageWorker: persist failed platform=%s user=%s op=%s: %s",
                event.platform, event.user_email, event.operation, e,
            )
        finally:
            _usage_queue.task_done()


def start_worker() -> asyncio.Task:
    """在当前事件循环中启动 usage_worker 后台任务，返回 Task 对象。"""
    global _worker_task
    _worker_task = asyncio.create_task(usage_worker(), name="usage_worker")
    return _worker_task


def stop_worker() -> None:
    """取消 usage_worker 后台任务（应用关闭时调用）。"""
    global _worker_task
    if _worker_task and not _worker_task.done():
        _worker_task.cancel()
        _worker_task = None
        logger.info("UsageWorker stopped.")
