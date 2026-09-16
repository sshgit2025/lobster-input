"""
EmailService — 异步邮件发送服务（基于 AokSend HTTP API）。
当前用于发送验证码邮件。
"""
import asyncio
import json
import logging

import aiohttp

from app.core.config import settings
from app.core.exceptions import AppException


logger = logging.getLogger("voice_input.email")


class EmailService:
    """邮件发送服务，通过 AokSend HTTP API 异步发送模板邮件。"""

    _TIMEOUT = aiohttp.ClientTimeout(total=15, connect=5, sock_read=10)

    async def send_verification_code(self, to: str, code: str, purpose: str = "验证") -> None:
        """发送验证码邮件到指定邮箱。"""
        if not settings.aoksend_api_key or not settings.aoksend_template_id:
            logger.error("AokSend configuration missing API key or template ID")
            raise self._unavailable()

        payload = {
            "app_key": settings.aoksend_api_key,
            "template_id": settings.aoksend_template_id,
            "to": to,
            "data": json.dumps({"code": code}, ensure_ascii=False),
        }
        async with aiohttp.ClientSession(timeout=self._TIMEOUT) as session:
            for attempt in range(2):
                try:
                    # 禁止跟随重定向，避免将 API Key 转交给意外的目标。
                    async with session.post(
                        settings.aoksend_api_url, data=payload, allow_redirects=False,
                    ) as resp:
                        if resp.status != 200:
                            logger.error("AokSend HTTP failure status=%s", resp.status)
                            raise self._unavailable()
                        result = await resp.json(content_type=None)
                        if not isinstance(result, dict) or result.get("code") != 200:
                            provider_code = result.get("code") if isinstance(result, dict) else None
                            logger.error("AokSend rejected request provider_code=%s", provider_code)
                            raise self._unavailable()
                        logger.info("AokSend accepted verification email")
                        return
                except aiohttp.ClientSSLError as exc:
                    # 证书错误不能通过关闭 TLS 校验或重试规避。
                    logger.error("AokSend TLS validation failure type=%s", type(exc).__name__)
                    raise self._unavailable() from exc
                except aiohttp.ClientConnectorError as exc:
                    # 仅连接建立前失败可以安全重试；已发送请求的超时不重试，避免重复邮件。
                    logger.warning("AokSend connection failed attempt=%s type=%s", attempt + 1, type(exc).__name__)
                    if attempt == 0:
                        await asyncio.sleep(0.25)
                        continue
                    raise self._unavailable() from exc
                except (aiohttp.ClientError, asyncio.TimeoutError, ValueError) as exc:
                    logger.error("AokSend request failed type=%s", type(exc).__name__)
                    raise self._unavailable() from exc

    @staticmethod
    def _unavailable() -> AppException:
        return AppException(503, "EMAIL_SERVICE_UNAVAILABLE", "验证码邮件暂时发送失败，请 60 秒后重试")
