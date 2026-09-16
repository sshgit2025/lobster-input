from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.middleware.client_platform import ClientPlatformMiddleware


def _client() -> TestClient:
    app = FastAPI()
    app.add_middleware(ClientPlatformMiddleware)

    @app.post("/api/v2/audio/windows/process")
    async def windows_v2_process():
        return {"ok": True}

    @app.post("/api/v2/audio/mac/process")
    async def mac_v2_process():
        return {"ok": True}

    @app.post("/api/v2/audio/ios/process")
    async def ios_v2_process():
        return {"ok": True}

    @app.post("/api/v2/audio/android/process")
    async def android_v2_process():
        return {"ok": True}

    @app.post("/api/v2/audio/harmony/process")
    async def harmony_v2_process():
        return {"ok": True}

    @app.post("/api/v1/text/android/quick-action")
    async def android_v1_quick_action():
        return {"ok": True}

    @app.post("/api/v1/text/harmony/quick-action")
    async def harmony_v1_quick_action():
        return {"ok": True}

    return TestClient(app)


def test_v2_windows_audio_requires_windows_platform_header():
    client = _client()

    ok = client.post(
        "/api/v2/audio/windows/process",
        headers={"X-Client-Platform": "windows"},
    )
    mismatch = client.post(
        "/api/v2/audio/windows/process",
        headers={"X-Client-Platform": "macos"},
    )

    assert ok.status_code == 200
    assert mismatch.status_code == 403
    assert mismatch.json()["code"] == "CLIENT_PLATFORM_MISMATCH"


def test_v2_ios_audio_requires_ios_platform_header():
    client = _client()

    ok = client.post(
        "/api/v2/audio/ios/process",
        headers={"X-Client-Platform": "ios"},
    )
    mismatch = client.post(
        "/api/v2/audio/ios/process",
        headers={"X-Client-Platform": "android"},
    )

    assert ok.status_code == 200
    assert mismatch.status_code == 403
    assert mismatch.json()["code"] == "CLIENT_PLATFORM_MISMATCH"


def test_v2_android_audio_requires_android_platform_header():
    client = _client()

    ok = client.post(
        "/api/v2/audio/android/process",
        headers={"X-Client-Platform": "android"},
    )
    mismatch = client.post(
        "/api/v2/audio/android/process",
        headers={"X-Client-Platform": "ios"},
    )

    assert ok.status_code == 200
    assert mismatch.status_code == 403
    assert mismatch.json()["code"] == "CLIENT_PLATFORM_MISMATCH"

def test_v2_mac_audio_requires_macos_platform_header():
    client = _client()

    ok = client.post(
        "/api/v2/audio/mac/process",
        headers={"X-Client-Platform": "macos"},
    )
    mismatch = client.post(
        "/api/v2/audio/mac/process",
        headers={"X-Client-Platform": "windows"},
    )

    assert ok.status_code == 200
    assert mismatch.status_code == 403
    assert mismatch.json()["code"] == "CLIENT_PLATFORM_MISMATCH"


def test_v2_harmony_audio_requires_harmony_platform_header():
    client = _client()

    ok = client.post(
        "/api/v2/audio/harmony/process",
        headers={"X-Client-Platform": "harmony"},
    )
    mismatch = client.post(
        "/api/v2/audio/harmony/process",
        headers={"X-Client-Platform": "android"},
    )

    assert ok.status_code == 200
    assert mismatch.status_code == 403
    assert mismatch.json()["code"] == "CLIENT_PLATFORM_MISMATCH"


def test_v1_text_routes_require_their_fixed_platform_header():
    client = _client()

    android_ok = client.post(
        "/api/v1/text/android/quick-action",
        headers={"X-Client-Platform": "android"},
    )
    android_mismatch = client.post(
        "/api/v1/text/android/quick-action",
        headers={"X-Client-Platform": "macos"},
    )
    harmony_ok = client.post(
        "/api/v1/text/harmony/quick-action",
        headers={"X-Client-Platform": "harmony"},
    )
    harmony_mismatch = client.post(
        "/api/v1/text/harmony/quick-action",
        headers={"X-Client-Platform": "android"},
    )

    assert android_ok.status_code == 200
    assert android_mismatch.status_code == 403
    assert android_mismatch.json()["code"] == "CLIENT_PLATFORM_MISMATCH"
    assert harmony_ok.status_code == 200
    assert harmony_mismatch.status_code == 403
    assert harmony_mismatch.json()["code"] == "CLIENT_PLATFORM_MISMATCH"
