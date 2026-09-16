import inspect

from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient

from app.api.v1 import v1_router
from app.api.v2 import v2_router
from app.decorators.client_context import ClientRequestContext, with_client_context
from app.middleware.auth import verify_user


_EXPECTED_CONTEXT_ROUTES = {
    "/api/v1/audio/mac/process": ("macos", None),
    "/api/v1/audio/mac/process/stream": ("macos", None),
    "/api/v1/audio/windows/process": ("windows", None),
    "/api/v1/audio/windows/process/stream": ("windows", None),
    "/api/v1/audio/ios/process": ("ios", None),
    "/api/v1/audio/android/process": ("android", None),
    "/api/v1/audio/harmony/process": ("harmony", None),
    "/api/v1/text/android/quick-action": ("android", None),
    "/api/v1/text/harmony/quick-action": ("harmony", None),
    "/api/v2/audio/mac/process": ("macos", "v2"),
    "/api/v2/audio/mac/process/stream": ("macos", "v2"),
    "/api/v2/audio/windows/process": ("windows", "v2"),
    "/api/v2/audio/windows/process/stream": ("windows", "v2"),
    "/api/v2/audio/ios/process": ("ios", "v2"),
    "/api/v2/audio/android/process": ("android", "v2"),
    "/api/v2/audio/harmony/process": ("harmony", "v2"),
}


def _test_app(*, flow_name: str | None = None) -> FastAPI:
    app = FastAPI()

    @app.get("/context")
    @with_client_context(client_platform="macos", flow_name=flow_name)
    async def context_endpoint(client_context: ClientRequestContext):
        return {
            "client_platform": client_context.client_platform,
            "client_ui_lang": client_context.client_ui_lang,
            "flow_name": client_context.flow_name,
            "user_email": client_context.user_email,
        }

    return app


def test_decorator_extracts_shared_context_without_exposing_internal_parameter():
    app = _test_app(flow_name="v2")
    app.dependency_overrides[verify_user] = lambda: {"sub": "user@example.com"}

    response = TestClient(app).get(
        "/context",
        headers={"X-Accept-Language": "zh-Hans"},
    )

    assert response.status_code == 200
    assert response.json() == {
        "client_platform": "macos",
        "client_ui_lang": "zh-Hans",
        "flow_name": "v2",
        "user_email": "user@example.com",
    }
    operation = app.openapi()["paths"]["/context"]["get"]
    assert all(
        parameter["name"] != "client_context"
        for parameter in operation.get("parameters", [])
    )


def test_decorator_preserves_missing_accept_language_fallback():
    app = _test_app()
    app.dependency_overrides[verify_user] = lambda: {"sub": "user@example.com"}

    response = TestClient(app).get("/context")

    assert response.status_code == 200
    assert response.json()["client_ui_lang"] == ""
    assert response.json()["flow_name"] == "standard"


def test_decorator_preserves_auth_dependency_failure():
    app = _test_app(flow_name="v2")

    def reject_auth():
        raise HTTPException(status_code=401, detail="rejected")

    app.dependency_overrides[verify_user] = reject_auth

    response = TestClient(app).get("/context")

    assert response.status_code == 401
    assert response.json() == {"detail": "rejected"}


def test_context_pipeline_resolution_preserves_raw_language(monkeypatch):
    calls = []
    expected_pipeline = object()

    def get_pipeline(client_platform, operation, client_ui_lang):
        calls.append((client_platform, operation, client_ui_lang))
        return expected_pipeline

    monkeypatch.setattr(
        "app.decorators.client_context.PipelineManager.get_pipeline",
        get_pipeline,
    )
    context = ClientRequestContext(
        client_platform="macos",
        client_ui_lang="zh-Hant-HK",
        flow_name="standard",
        user_email="user@example.com",
    )

    pipeline = context.get_pipeline("rewrite")

    assert pipeline is expected_pipeline
    assert calls == [("macos", "rewrite", "zh-Hant-HK")]


def test_decorator_policy_covers_every_pipeline_http_route():
    decorated_routes = {}
    for route in [*v1_router.routes, *v2_router.routes]:
        policy = getattr(route.endpoint, "__client_context_policy__", None)
        if policy is not None:
            decorated_routes[route.path] = (
                policy.client_platform,
                policy.fixed_flow_name,
            )

    assert decorated_routes == _EXPECTED_CONTEXT_ROUTES


def test_decorated_handlers_do_not_parse_headers_directly():
    for route in [*v1_router.routes, *v2_router.routes]:
        if getattr(route.endpoint, "__client_context_policy__", None) is not None:
            source = inspect.getsource(route.endpoint)
            assert "request.headers" not in source, route.path


def test_decorated_routes_preserve_fastapi_request_contracts():
    app = FastAPI()
    app.include_router(v1_router)
    app.include_router(v2_router)

    schema = app.openapi()

    v1_content = schema["paths"]["/api/v1/audio/mac/process"]["post"]["requestBody"]["content"]
    v2_content = schema["paths"]["/api/v2/audio/mac/process"]["post"]["requestBody"]["content"]
    assert "multipart/form-data" in v1_content
    assert "application/json" in v2_content
    assert "ClientRequestContext" not in schema.get("components", {}).get("schemas", {})
