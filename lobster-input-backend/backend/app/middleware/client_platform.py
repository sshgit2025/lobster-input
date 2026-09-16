"""
客户端平台校验中间件。
共享接口只校验 X-Client-Platform 是否属于四端合法枚举值；
平台专属接口额外校验路径与平台是否匹配。

合法值：macos | ios | windows | android | harmony

跳过校验的路径：
  - /health          健康检查（负载均衡探活）
  - /docs /redoc /openapi.json  API 文档
  - /api/v1/agreements  协议接口（无需鉴权）
  - /api/v1/payments/checkout-intents  支付中转页（浏览器打开，无客户端平台头）
  - /api/v1/admin/      管理端接口

平台专属接口路径：
  - /api/v1/audio/mac/      → 仅允许 X-Client-Platform=macos
  - /api/v1/audio/ios/      → 仅允许 X-Client-Platform=ios
  - /api/v1/audio/windows/  → 仅允许 X-Client-Platform=windows
  - /api/v1/audio/android/  → 仅允许 X-Client-Platform=android
  - /api/v1/audio/harmony/  → 仅允许 X-Client-Platform=harmony
  - /api/v2/audio/mac/      → 仅允许 X-Client-Platform=macos
  - /api/v2/audio/ios/      → 仅允许 X-Client-Platform=ios
  - /api/v2/audio/windows/  → 仅允许 X-Client-Platform=windows
  - /api/v2/audio/android/  → 仅允许 X-Client-Platform=android
  - /api/v2/audio/harmony/  → 仅允许 X-Client-Platform=harmony
  - /api/v1/text/android/   → 仅允许 X-Client-Platform=android
  - /api/v1/text/harmony/   → 仅允许 X-Client-Platform=harmony
"""
import logging
from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger("voice_input.middleware.client_platform")

_VALID_PLATFORMS = {"macos", "ios", "windows", "android", "harmony"}

_SKIP_PREFIXES = (
    "/health",
    "/docs",
    "/redoc",
    "/openapi.json",
    "/api/v1/agreements",
    "/api/v1/payments/checkout-intents",
    "/api/v1/admin/",
    # 计费经济性管理:服务间内部接口(verify_internal_api_key HMAC 保护),
    # 由管理端代理调用、不带 X-Client-Platform,与 /api/v1/admin/ 同等豁免。
    "/api/v1/config/billing-",
    # 套餐 / 订阅管理:服务间内部接口(verify_internal_api_key HMAC 保护),
    # 由管理端 plans.py 代理调用、不带 X-Client-Platform,同等豁免。
    "/api/v1/config/plan-admin",
)

# 平台专属接口路径：只能由对应平台调用，接口层仍会强制注入平台值供流水线使用
_PLATFORM_EXCLUSIVE_PREFIXES = {
    "/api/v1/audio/mac/": "macos",
    "/api/v1/audio/ios/": "ios",
    "/api/v1/audio/windows/": "windows",
    "/api/v1/audio/android/": "android",
    "/api/v1/audio/harmony/": "harmony",
    "/api/v2/audio/mac/": "macos",
    "/api/v2/audio/ios/": "ios",
    "/api/v2/audio/windows/": "windows",
    "/api/v2/audio/android/": "android",
    "/api/v2/audio/harmony/": "harmony",
    "/api/v1/text/android/": "android",
    "/api/v1/text/harmony/": "harmony",
}


class ClientPlatformMiddleware(BaseHTTPMiddleware):
    """校验 X-Client-Platform，不合法或端专属路径不匹配时直接 403 拦截。"""

    async def dispatch(self, request: Request, call_next):
        path = request.url.path

        # 跳过公共免校验路径
        if path.startswith(_SKIP_PREFIXES):
            return await call_next(request)

        # 所有业务接口：必须提供合法 X-Client-Platform
        platform = request.headers.get("X-Client-Platform", "")
        if platform not in _VALID_PLATFORMS:
            logger.warning(
                "✗ %s %s  blocked: invalid X-Client-Platform=%r",
                request.method, path, platform,
            )
            return JSONResponse(
                status_code=403,
                content={
                    "code": "INVALID_CLIENT_PLATFORM",
                    "message": "Missing or invalid X-Client-Platform header",
                },
            )

        # 平台专属接口：Header 必须与路径所属平台一致，避免误调其它端定制接口
        for prefix, expected_platform in _PLATFORM_EXCLUSIVE_PREFIXES.items():
            if path.startswith(prefix) and platform != expected_platform:
                logger.warning(
                    "✗ %s %s  blocked: platform=%r expected=%r",
                    request.method, path, platform, expected_platform,
                )
                return JSONResponse(
                    status_code=403,
                    content={
                        "code": "CLIENT_PLATFORM_MISMATCH",
                        "message": f"X-Client-Platform must be {expected_platform} for this endpoint",
                    },
                )

        accept_language = request.headers.get("X-Accept-Language", "")
        if accept_language:
            logger.info(
                "X-Accept-Language=%r  platform=%r  %s %s",
                accept_language, platform, request.method, path,
            )

        return await call_next(request)
