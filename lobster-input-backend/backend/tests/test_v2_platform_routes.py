import os

from fastapi import FastAPI

os.environ.setdefault("QDRANT_HOST", "127.0.0.1")
os.environ.setdefault("QDRANT_PORT", "6333")

from app.api.v2 import v2_router


def _route_paths() -> set[str]:
    app = FastAPI()
    app.include_router(v2_router)
    return {route.path for route in app.routes}


def test_v2_platform_process_routes_are_fixed_per_platform():
    paths = _route_paths()

    assert "/api/v2/audio/mac/process" in paths
    assert "/api/v2/audio/ios/process" in paths
    assert "/api/v2/audio/windows/process" in paths
    assert "/api/v2/audio/android/process" in paths
    assert "/api/v2/audio/harmony/process" in paths
    assert "/api/v2/audio/{platform}/process" not in paths


def test_v2_platform_realtime_routes_are_fixed_per_platform():
    paths = _route_paths()

    assert "/api/v2/audio/mac/asr/realtime" in paths
    assert "/api/v2/audio/ios/asr/realtime" in paths
    assert "/api/v2/audio/windows/asr/realtime" in paths
    assert "/api/v2/audio/android/asr/realtime" in paths
    assert "/api/v2/audio/harmony/asr/realtime" in paths
    assert "/api/v2/asr/realtime/{platform}" not in paths
