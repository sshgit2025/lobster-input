import asyncio
from types import SimpleNamespace

from app.agent.nodes import search_node
from app.agent.intent_router import IntentType
from app.core.exceptions import CreditsExhaustedException
from app.services.pipeline.v1.agent_pipeline import AgentPipeline as V1AgentPipeline
from app.services.infra.api_pool_client import PoolKeyInfo
from app.services.pipeline.v2.agent_pipeline import AgentPipeline as V2AgentPipeline


class _FakeResponse:
    status_code = 200
    text = ""

    def json(self):
        return {
            "choices": [
                {"message": {"content": "## 搜索结果\n\n"}},
                {"message": {"content": "**核心答案：**同步返回。"}},
            ],
            "usage": {
                "prompt_tokens": 12,
                "completion_tokens": 34,
                "total_tokens": 46,
            },
        }


class _FakeAsyncClient:
    def __init__(self, timeout):
        self.timeout = timeout
        self.request = None

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def post(self, endpoint, headers, json):
        self.request = {
            "endpoint": endpoint,
            "headers": headers,
            "json": json,
        }
        return _FakeResponse()


def test_dashscope_web_search_uses_non_streaming_chat(monkeypatch):
    client = _FakeAsyncClient(timeout=None)

    monkeypatch.setattr(search_node.httpx, "AsyncClient", lambda timeout: client)

    payload = {
        "model": "qwen-plus",
        "messages": [{"role": "user", "content": "查今天新闻"}],
        "enable_search": True,
        "search_options": {"search_strategy": "agent", "enable_source": True},
    }

    content, usage = asyncio.run(
        search_node.DashScopeWebSearchProvider._chat(
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            "test-key",
            payload,
        )
    )

    assert client.request["json"] is payload
    assert "stream" not in client.request["json"]
    assert "stream_options" not in client.request["json"]
    assert client.request["headers"]["Authorization"] == "Bearer test-key"
    assert content == "## 搜索结果\n\n**核心答案：**同步返回。"
    assert usage == {
        "prompt_tokens": 12,
        "completion_tokens": 34,
        "total_tokens": 46,
    }


def test_tavily_search_provider_uses_shared_precharge(monkeypatch):
    class _CreditCalc:
        def request_cost(self, category, platform_code, model, node_id="", provider_id=""):
            assert category == "web_search"
            assert platform_code == "tavily"
            assert model == "tavily-search"
            assert node_id == "web_search"
            assert provider_id == "search_tavily"
            return 300

    class _CreditAccount:
        async def charge(self, user_email, amount):
            assert user_email == "user@example.com"
            assert amount == 300
            return 9700, [{"credits": 300, "source": "test"}]

    monkeypatch.setattr(search_node, "CreditAccountService", lambda: _CreditAccount())

    ctx = SimpleNamespace(
        user_email="user@example.com",
        credit_calc=_CreditCalc(),
        precharged_credits=0,
        deductions=[],
    )
    key_info = PoolKeyInfo(
        id="key-1",
        api_key="tvly-test",
        model="tavily-search",
        category="web_search",
        platform_code="tavily",
        provider_id="search_tavily",
        business_node_id="web_search",
    )

    cost, rows = asyncio.run(
        search_node.TavilySearchProvider()._precharge_search_credits(
            ctx,
            key_info,
            {},
            key_info.model,
        )
    )

    assert cost == 300
    assert rows == [{"credits": 300, "source": "test"}]
    assert ctx.precharged_credits == 300
    assert ctx.deductions == rows


def test_v1_and_v2_agent_pipelines_route_search_to_shared_search_node():
    v1_pipeline = V1AgentPipeline()
    v2_pipeline = V2AgentPipeline()

    assert isinstance(v1_pipeline._node_map[IntentType.SEARCH], search_node.SearchNode)
    assert isinstance(v2_pipeline._node_map[IntentType.SEARCH], search_node.SearchNode)


def test_tavily_search_does_not_convert_credit_errors_to_markdown(monkeypatch):
    class _CreditCalc:
        def request_cost(self, *args, **kwargs):
            return 300

    class _CreditAccount:
        async def charge(self, *args, **kwargs):
            raise CreditsExhaustedException()

    class _TavilyClient:
        def search(self, *args, **kwargs):
            raise AssertionError("search should not be called after credit failure")

    async def _report_error(*args, **kwargs):
        raise AssertionError("credit failure should not be reported as provider error")

    monkeypatch.setattr(search_node, "CreditAccountService", lambda: _CreditAccount())
    monkeypatch.setattr(search_node, "report_error", _report_error)
    ctx = SimpleNamespace(
        user_email="user@example.com",
        credit_calc=_CreditCalc(),
        precharged_credits=0,
        deductions=[],
        client_platform="macos",
    )
    key_info = PoolKeyInfo(
        id="key-1",
        api_key="tvly-test",
        model="tavily-search",
        category="web_search",
        platform_code="tavily",
        provider_id="search_tavily",
        business_node_id="web_search",
    )

    try:
        asyncio.run(
            search_node.TavilySearchProvider()._search_and_summarize(
                _TavilyClient(),
                "扬州天气",
                ctx,
                key_info,
                {},
            )
        )
    except CreditsExhaustedException:
        pass
    else:
        raise AssertionError("CreditsExhaustedException should propagate")
