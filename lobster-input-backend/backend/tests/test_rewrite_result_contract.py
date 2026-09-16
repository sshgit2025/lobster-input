import asyncio
from types import SimpleNamespace

from app.agent.nodes.rewrite_node import RewriteNode
from app.models.schemas import ActionType
from app.services.pipeline.v1.audio_pipeline import PipelineContext
from app.services.pipeline.v1.rewrite_pipeline import RewritePipeline


_CLARIFY_JSON = '{"action":"clarify","question":"你想怎么处理选中文本？"}'


class _FakeLLMService:
    async def run(self, **kwargs):
        return _CLARIFY_JSON, SimpleNamespace(platform="test")


def test_rewrite_pipeline_returns_llm_raw_result_even_if_it_looks_like_clarify():
    pipeline = RewritePipeline()
    pipeline.llm_service = _FakeLLMService()
    ctx = PipelineContext(
        operation="rewrite",
        transcript="处理一下",
        selected_text="原始选中文本",
    )

    result = asyncio.run(pipeline.invoke_llm(ctx))

    assert result == _CLARIFY_JSON
    assert ctx.clarify_question is None
    assert pipeline.resolve_action_type(ctx) == ActionType.paste


def test_agent_rewrite_node_returns_llm_raw_result_even_if_it_looks_like_clarify():
    node = RewriteNode(_FakeLLMService())
    ctx = PipelineContext(
        operation="agent",
        transcript="处理一下",
        selected_text="原始选中文本",
    )

    asyncio.run(node.execute(ctx))

    assert ctx.result == _CLARIFY_JSON
    assert ctx.clarify_question is None
    assert ctx.action_type == ActionType.paste
