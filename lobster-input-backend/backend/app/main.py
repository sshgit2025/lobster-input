"""
FastAPI 应用主模块。
负责: 应用实例创建、生命周期管理（数据库连接/索引初始化）、
全局中间件注册、统一异常处理、路由挂载。
"""
import asyncio
import logging
import logging.config
import os
import tempfile
import wave
from contextlib import asynccontextmanager
from pathlib import Path
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from app.core.config import settings
from app.core.database import connect_db, close_db, get_db
from app.core.exceptions import AppException
from app.api.v1 import v1_router
from app.api.v2 import v2_router
from app.middleware.logging import RequestLoggingMiddleware
from app.middleware.client_platform import ClientPlatformMiddleware
from app.middleware.security_guard import SecurityGuardMiddleware
from app.middleware.session_renewal import SessionRenewalMiddleware
from app.repositories.agreement_repository import AgreementRepository
from app.repositories.client_log_repository import ClientLogRepository
from app.repositories.credit_grant_repository import CreditGrantRepository
from app.repositories.distributed_lock_repository import DistributedLockRepository
from app.repositories.feedback_repository import FeedbackRepository
from app.repositories.hotword_repository import HotWordRepository
from app.repositories.invite_repository import InviteRepository
from app.repositories.pending_registration_repository import PendingRegistrationRepository
from app.repositories.persona_repository import PersonaRepository
from app.repositories.plan_repository import PlanRepository
from app.repositories.realtime_asr_session_repository import RealtimeASRSessionRepository
from app.repositories.security_repository import SecurityRepository
from app.repositories.user_repository import UserRepository
from app.repositories.verify_code_repository import VerifyCodeRepository
from app.services.audio.audio_service import AudioService
from app.services.audio.asr_correction import warmup_asr_correction_components
from app.services.billing.plan_service import PlanService
from app.services.billing.subscription_purchase_service import SubscriptionPurchaseService
from app.data.credits.repository import CreditLedgerRepository
from app.data.usage.repository import UsageRepository
from app.data.usage.queue import start_worker, stop_worker

# ── 日志配置 ──────────────────────────────────────────────
# 开发模式下将 voice_input 命名空间降至 DEBUG，便于观察 Persona 注入流程
_LOG_LEVEL = logging.DEBUG if settings.app_env != "production" else logging.INFO

logging.basicConfig(
    level=_LOG_LEVEL,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt="%H:%M:%S",
)
# 第三方库噪音抑制
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("openai").setLevel(logging.WARNING)
logging.getLogger("langchain").setLevel(logging.WARNING)
logging.getLogger("motor").setLevel(logging.WARNING)

logger = logging.getLogger("voice_input")

# ── LangWatch 初始化（LLM 可观测性，key 为空时自动跳过）──
if settings.langwatch_enabled and settings.langwatch_api_key:
    import langwatch
    _lw_kwargs: dict = {"api_key": settings.langwatch_api_key}
    if settings.langwatch_endpoint:
        _lw_kwargs["endpoint_url"] = settings.langwatch_endpoint
    langwatch.setup(**_lw_kwargs)
    _lw_target = settings.langwatch_endpoint or "https://app.langwatch.ai"
    logger.info("LangWatch initialized, endpoint=%s", _lw_target)
else:
    logger.info("LangWatch disabled or API key not set, skipping.")


async def _warmup_asr() -> None:
    """
    后台预热 ASR 连接。
    后端启动后异步触发，向 DashScope 发一次极短静音音频识别，
    激活 HTTP 连接池，消除第一个真实请求的冷启动延迟（约 3-4s）。
    """
    await asyncio.sleep(2)
    warmup_path = None
    try:
        upload_dir = Path(settings.audio_upload_dir)
        upload_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(suffix=".wav", dir=upload_dir, delete=False) as f:
            warmup_path = f.name
        with wave.open(warmup_path, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(b"\x00\x00" * 8000)
        svc = AudioService()
        key_info = await svc._resolve_asr_key()
        await svc._transcribe_with_key(
            key_info=key_info,
            audio_path=Path(warmup_path),
            prompt="",
            operation="warmup",
        )
        logger.info("ASR warmup completed (cold-start eliminated).")
    except Exception as e:
        logger.warning("ASR warmup failed (non-critical): %s", e)
    finally:
        if warmup_path:
            try:
                os.unlink(warmup_path)
            except Exception:
                pass


async def _warmup_asr_correction() -> None:
    """
    后台预热 ASR 纠偏组件。
    只初始化本地分词和用户词典发音索引，不调用外部模型或公共词库。
    """
    await asyncio.sleep(1)
    try:
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, warmup_asr_correction_components)
    except Exception as e:
        logger.warning("ASR correction warmup failed (non-critical): %s", e)


async def _plan_reset_worker() -> None:
    await asyncio.sleep(5)
    svc = PlanService()
    while True:
        try:
            count = await svc.process_due_resets(limit=200)
            if count:
                logger.info("Plan reset worker processed %d users", count)
        except Exception as e:
            logger.warning("Plan reset worker failed: %s", e)
        await asyncio.sleep(300)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期：启动时连接数据库并初始化索引，关闭时断开连接。"""
    logger.info("Starting up — connecting to MongoDB...")
    await connect_db()
    logger.info("MongoDB connected.")
    await UserRepository().ensure_indexes()
    await VerifyCodeRepository().ensure_indexes()
    await PendingRegistrationRepository().ensure_indexes()
    await HotWordRepository().ensure_indexes()
    await PersonaRepository().ensure_indexes()
    await InviteRepository().ensure_indexes()
    await UsageRepository().ensure_indexes()
    await CreditLedgerRepository().ensure_indexes()
    await CreditGrantRepository().ensure_indexes()
    await ClientLogRepository().ensure_indexes()
    await AgreementRepository().ensure_indexes()
    await FeedbackRepository().ensure_indexes()
    await SecurityRepository().ensure_indexes()
    await DistributedLockRepository().ensure_indexes()
    await RealtimeASRSessionRepository().ensure_indexes()
    await PlanRepository().ensure_default_system_configs()
    await SubscriptionPurchaseService().ensure_indexes()
    # system_config：按 key 点查，加单字段索引（unique=False，key 重复写入使用 upsert）
    await get_db()["system_config"].create_index("key", unique=True)
    await get_db()["payment_checkout_intents"].create_index("intent_id", unique=True)
    await get_db()["payment_checkout_intents"].create_index("expires_at", expireAfterSeconds=0)
    # user_settings：按 user_email 查询用户自定义设置
    await get_db()["user_settings"].create_index("user_email", unique=True)
    start_worker()
    logger.info("DB indexes ready. UsageWorker started. Server is up.")

    # ASR 连接预热：向 DashScope 发一次静默请求，激活 HTTP 连接池
    # 避免第一个真实用户请求触发冷启动（约 3-4s 延迟）
    asyncio.create_task(_warmup_asr_correction())
    asyncio.create_task(_warmup_asr())
    asyncio.create_task(_plan_reset_worker())

    yield
    logger.info("Shutting down...")
    stop_worker()
    await close_db()


app = FastAPI(
    title="Voice Input API",
    version="0.1.0",
    lifespan=lifespan,
    # 生产环境不暴露 API 文档
    docs_url="/docs" if settings.app_env != "production" else None,
    redoc_url="/redoc" if settings.app_env != "production" else None,
)

# 注册全局中间件（Starlette 洋葱模型：后注册的先执行/更外层）
# 请求方向执行顺序：SecurityGuard 风控 → ClientPlatform 校验 → 日志记录 → 会话续期 → 业务处理
# SessionRenewal 最先注册 = 最内层：只有通过风控/平台校验的请求才会进入它，
# 它在业务响应产生后（响应方向最先）根据 status/路径/Bearer 头异步调度登录态滑动续期，
# 不做任何阻塞操作，也不修改请求与响应。
app.add_middleware(SessionRenewalMiddleware)
app.add_middleware(RequestLoggingMiddleware)
app.add_middleware(ClientPlatformMiddleware)
app.add_middleware(SecurityGuardMiddleware)


@app.exception_handler(AppException)
async def app_exception_handler(request: Request, exc: AppException):
    """统一业务异常处理，将 AppException 转为 JSON 响应。"""
    logger.warning(
        "AppException %s %s → %d %s",
        request.method, request.url.path,
        exc.status_code, exc.detail,
    )
    content = dict(exc.detail) if isinstance(exc.detail, dict) else {"message": str(exc.detail)}
    if hasattr(exc, "config_update") and exc.config_update:
        content["config_update"] = exc.config_update
    return JSONResponse(status_code=exc.status_code, content=content)


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """兜底：将遗漏的 HTTPException 统一转为 {"code": ..., "message": ...} 格式。"""
    logger.warning(
        "HTTPException %s %s → %d %s",
        request.method, request.url.path,
        exc.status_code, exc.detail,
    )
    return JSONResponse(
        status_code=exc.status_code,
        content=exc.detail if isinstance(exc.detail, dict) else {
            "code": "UNKNOWN_ERROR",
            "message": str(exc.detail),
        },
    )


# 挂载 v1 版本路由（/api/v1）
app.include_router(v1_router)
# 挂载 v2 版本路由（/api/v2）
app.include_router(v2_router)


@app.get("/health", tags=["Health"])
async def health():
    """健康检查接口，用于监控和负载均衡探活。"""
    return {"status": "ok"}
