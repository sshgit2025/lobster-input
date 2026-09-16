"""
请求日志中间件。
记录每个 HTTP 请求的方法、路径、客户端 IP、响应状态码和耗时（毫秒）。
4xx 及以上状态码以 WARNING 级别记录，便于快速定位问题。
"""
import time
import logging
from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

logger = logging.getLogger("voice_input")


class RequestLoggingMiddleware(BaseHTTPMiddleware):
    """全局请求日志中间件，记录请求进出和耗时。"""

    async def dispatch(self, request: Request, call_next) -> Response:
        start = time.perf_counter()

        logger.info(
            "→ %s %s  client=%s",
            request.method,
            request.url.path,
            request.client.host if request.client else "-",
        )

        try:
            response = await call_next(request)
        except Exception as exc:
            elapsed = (time.perf_counter() - start) * 1000
            logger.error(
                "✗ %s %s  %.1fms  UNHANDLED: %s",
                request.method,
                request.url.path,
                elapsed,
                exc,
                exc_info=True,
            )
            raise

        elapsed = (time.perf_counter() - start) * 1000
        level = logging.WARNING if response.status_code >= 400 else logging.INFO
        logger.log(
            level,
            "← %s %s  status=%d  %.1fms",
            request.method,
            request.url.path,
            response.status_code,
            elapsed,
        )
        return response
