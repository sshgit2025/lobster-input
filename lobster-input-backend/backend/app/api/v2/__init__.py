"""V2 API routes."""
from fastapi import APIRouter

from app.api.v2.audio.android import router as audio_android_router
from app.api.v2.audio.harmony import router as audio_harmony_router
from app.api.v2.audio.ios import router as audio_ios_router
from app.api.v2.audio.mac import router as audio_mac_router
from app.api.v2.audio.windows import router as audio_windows_router

v2_router = APIRouter(prefix="/api/v2")
v2_router.include_router(audio_mac_router)
v2_router.include_router(audio_ios_router)
v2_router.include_router(audio_windows_router)
v2_router.include_router(audio_android_router)
v2_router.include_router(audio_harmony_router)
