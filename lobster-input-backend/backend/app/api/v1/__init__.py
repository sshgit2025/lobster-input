"""
V1 版本路由聚合模块。
将认证、音频处理、词典、人设、管理等路由统一挂载到 /api/v1 前缀下。

音频处理路由分层：
  /api/v1/audio/mac/process     — Mac 端专属接口（macos 平台）
  /api/v1/audio/ios/process     — iOS 端专属接口
  /api/v1/audio/windows/process — Windows 端专属接口
  /api/v1/audio/android/process — Android 端专属接口
  /api/v1/audio/harmony/process — HarmonyOS 端专属接口

文本快捷处理路由：
  /api/v1/text/android/quick-action — Android 输入法快捷键文本处理
  /api/v1/text/harmony/quick-action — HarmonyOS 输入法快捷键文本处理
"""
from fastapi import APIRouter
from app.api.v1.audio.mac import router as audio_mac_router
from app.api.v1.audio.ios import router as audio_ios_router
from app.api.v1.audio.windows import router as audio_windows_router
from app.api.v1.audio.android import router as audio_android_router
from app.api.v1.audio.harmony import router as audio_harmony_router
from app.api.v1.text.android import router as text_android_router
from app.api.v1.text.harmony import router as text_harmony_router
from app.api.v1.auth import router as auth_router
from app.api.v1.hotwords import router as hotwords_router
from app.api.v1.personas import router as personas_router
from app.api.v1.config import router as config_router
from app.api.v1.plan_admin import router as plan_admin_router
from app.api.v1.admin import router as admin_router
from app.api.v1.admin_user_dict import router as admin_user_dict_router
from app.api.v1.logs import router as logs_router
from app.api.v1.agreements import router as agreements_router
from app.api.v1.feedback import router as feedback_router
from app.api.v1.payments import router as payments_router
from app.api.v1.payments import subscription_router
from app.api.v1.apple_iap import router as apple_iap_router
from app.api.v1.runtime_admin import router as runtime_admin_router

v1_router = APIRouter(prefix="/api/v1")
v1_router.include_router(auth_router)
# 平台专属音频处理接口
v1_router.include_router(audio_mac_router)
v1_router.include_router(audio_ios_router)
v1_router.include_router(audio_windows_router)
v1_router.include_router(audio_android_router)
v1_router.include_router(audio_harmony_router)
v1_router.include_router(text_android_router)
v1_router.include_router(text_harmony_router)
v1_router.include_router(hotwords_router)
v1_router.include_router(personas_router)
v1_router.include_router(config_router)
v1_router.include_router(plan_admin_router)
v1_router.include_router(admin_router)
v1_router.include_router(admin_user_dict_router)
v1_router.include_router(logs_router)
v1_router.include_router(agreements_router)
v1_router.include_router(feedback_router)
v1_router.include_router(payments_router)
v1_router.include_router(subscription_router)
v1_router.include_router(apple_iap_router)
v1_router.include_router(runtime_admin_router)
