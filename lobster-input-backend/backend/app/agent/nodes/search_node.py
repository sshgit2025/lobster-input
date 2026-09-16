"""
SearchNode — 联网搜索意图节点。

默认使用 DashScope qwen enable_search 直接生成 Markdown 搜索结果。
Tavily 实现保留为可插拔 provider，后续需要恢复或接入其他搜索平台时，
只需要新增 provider 子类并在工厂中选择。
"""
import asyncio
import json
import logging
import time
from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Awaitable, Callable, Optional, List

import httpx
from langchain_core.messages import SystemMessage, HumanMessage
from langchain_core.runnables.config import RunnableConfig

from app.agent.nodes.base import BaseNode
from app.core.exceptions import CreditsExhaustedException, ServiceTemporarilyUnavailableException
from app.data.credits.models import BreakdownItem
from app.models.schemas import ActionType
from app.providers.llm.runtime import get_llm_for_node
from app.services.infra.api_pool_client import (
    report_usage, report_error, PoolKeyInfo,
)
from app.services.infra.runtime_provider_config import pick_key_for_node, resolve_node_provider
from app.services.billing.credit_account_service import CreditAccountService
from app.services.infra.proxy_config import httpx_async_client_kwargs, requests_proxies
from app.data.usage.extractors.base import BaseUsageExtractor
from app.data.usage.extractors.groq_llm_extractor import GroqLLMExtractor
from app.data.usage.extractors.openai_llm_extractor import OpenAILLMExtractor
from app.data.usage.extractors.tavily_extractor import TavilyExtractor
from app.data.usage.models import UsageEvent
from app.data.usage.queue import emit as usage_emit

try:
    from tavily import TavilyClient as _TavilyClient
    _TAVILY_AVAILABLE = True
except ImportError:
    _TavilyClient = None
    _TAVILY_AVAILABLE = False

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import PipelineContext

logger = logging.getLogger("voice_input.node.search")

_SEARCH_QUERY_SYSTEM_PROMPT = """你是一个搜索词优化器。
将用户的语音输入转换为简洁、有效的搜索引擎查询词。
去除语气词，纠正语义错误，只输出优化后的搜索词文本，不添加任何解释或多余内容。"""

_MARKDOWN_SEARCH_SYSTEM_PROMPT = """你是一个专业的联网搜索结果整理助手。
请根据用户问题进行联网搜索，并输出清晰、可靠、简洁的 Markdown 回答。

## 内容要求
- 用用户提问的语言回答（中文提问则中文回答，英文则英文）
- 先用 1-3 句话给出核心答案或摘要，前面加 **核心答案：** 标签
- 如果是新闻/热点，用 bullet list 列出各条新闻，每条格式：**新闻标题**：一句话摘要
- 如果是知识问答，用结构化段落或 bullet list 解释，可按逻辑分小节
- 在末尾单独一节列出来源链接
- 过滤掉明显的噪音、广告、导航栏、重复内容和乱码
- 保持简洁，突出最有价值的信息

## Markdown 格式规范（严格遵守）
- 标题只使用 ## 和 ###，不使用 # 一级标题
- bullet list 每项以 `- ` 开头，缩进用 2 个空格
- 加粗用 `**文字**`，不要用 `__文字__`
- 链接用 `[显示文字](URL)` 格式
- 段落之间空一行
- 来源节格式固定为：
  ## 来源
  - [文章标题](URL)
  - [文章标题](URL)
- 不要在同一行混用加粗和链接语法（如 `**[title](url)**`），分开写
- 不要输出任何代码块（```），这是给普通用户看的文字内容"""


class BaseSearchProvider(ABC):
    """联网搜索 provider 抽象基类。"""

    @abstractmethod
    async def run(
        self,
        ctx: "PipelineContext",
        node_config: dict,
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        """执行联网搜索并返回 Markdown 文本。"""

    async def run_stream(
        self,
        ctx: "PipelineContext",
        node_config: dict,
        on_delta: Callable[[str], Awaitable[None]],
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        """执行联网搜索并流式输出最终 Markdown 文本。"""
        return await self.run(ctx, node_config, langchain_callbacks=langchain_callbacks)

    def _emit_llm_usage(
        self,
        response,
        ctx: "PipelineContext",
        operation: str,
        latency_ms: int,
        key_info: Optional[PoolKeyInfo] = None,
    ) -> None:
        effective_provider = ((key_info.platform_code if key_info else ctx.provider) or "openai").lower()
        extractor = GroqLLMExtractor() if effective_provider == "groq" else OpenAILLMExtractor()
        api_key = key_info.api_key if key_info else ""
        event = extractor.extract(
            response,
            user_email=ctx.user_email,
            operation=operation,
            latency_ms=latency_ms,
            api_key=api_key,
            client_platform=ctx.client_platform,
        )
        if event:
            usage_emit(event)

    @staticmethod
    async def _precharge_search_credits(
        ctx: "PipelineContext",
        key_info: PoolKeyInfo,
        node_config: dict,
        model: str,
    ) -> tuple[int, list[dict]]:
        if not ctx.user_email or not ctx.credit_calc:
            return 0, []
        request_cost = ctx.credit_calc.request_cost(
            node_config.get("pricing_category") or "web_search",
            node_config.get("pricing_platform_code") or key_info.platform_code or "aliyun_search",
            node_config.get("pricing_model") or model,
            node_id=key_info.business_node_id or "web_search",
            provider_id=key_info.provider_id,
        )
        if request_cost <= 0:
            return 0, []
        _, rows = await CreditAccountService().charge(ctx.user_email, request_cost)
        ctx.precharged_credits = getattr(ctx, "precharged_credits", 0) + request_cost
        ctx.deductions.extend(rows)
        return request_cost, rows


class DashScopeWebSearchProvider(BaseSearchProvider):
    """DashScope qwen enable_search 直出 Markdown 搜索结果。"""

    async def run(
        self,
        ctx: "PipelineContext",
        node_config: dict,
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        key_info, _node, _provider = await pick_key_for_node("web_search", expected_category="web_search")
        model = node_config.get("model") or key_info.model
        if not model:
            raise RuntimeError(f"Pool key {key_info.id} has no model configured for web search")

        endpoint = self._chat_completions_endpoint(node_config.get("base_url") or key_info.base_url or "")
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": _MARKDOWN_SEARCH_SYSTEM_PROMPT},
                {"role": "user", "content": ctx.transcript},
            ],
            "enable_search": True,
            "search_options": {
                "search_strategy": node_config.get("search_strategy") or "agent",
                "enable_source": True,
            },
        }

        t0 = time.monotonic()
        charge_rows: list[dict] = []
        request_cost = 0
        try:
            request_cost, charge_rows = await self._precharge_search_credits(ctx, key_info, node_config, model)
            content, usage = await self._chat(endpoint, key_info.api_key, payload, key_info.proxy_config)
        except (CreditsExhaustedException, ServiceTemporarilyUnavailableException):
            raise
        except Exception as e:
            if ctx.user_email and charge_rows:
                await CreditAccountService().refund(ctx.user_email, charge_rows, request_cost)
                ctx.precharged_credits = max(0, getattr(ctx, "precharged_credits", 0) - request_cost)
            await report_error(key_info, str(e))
            raise

        latency_ms = int((time.monotonic() - t0) * 1000)
        input_tokens = int(usage.get("prompt_tokens") or 0)
        output_tokens = int(usage.get("completion_tokens") or 0)
        total_tokens = int(usage.get("total_tokens") or (input_tokens + output_tokens))

        if ctx.user_email:
            self._emit_usage_event(ctx, key_info, input_tokens, output_tokens, latency_ms)
            asyncio.ensure_future(report_usage(
                key_info,
                tokens_used=total_tokens,
                requests_used=1,
                operation="search",
                user_email=ctx.user_email,
                latency_ms=latency_ms,
                client_platform=ctx.client_platform,
            ))

        self._apply_credits(ctx, key_info, node_config, model)
        logger.info(
            "DashScope web search done: model=%s latency_ms=%d tokens=%d",
            model, latency_ms, total_tokens,
        )
        return content.strip() if content.strip() else "## 搜索结果\n\n未获取到有效搜索结果。"

    async def run_stream(
        self,
        ctx: "PipelineContext",
        node_config: dict,
        on_delta: Callable[[str], Awaitable[None]],
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        key_info, _node, _provider = await pick_key_for_node("web_search", expected_category="web_search")
        model = node_config.get("model") or key_info.model
        if not model:
            raise RuntimeError(f"Pool key {key_info.id} has no model configured for web search")

        endpoint = self._chat_completions_endpoint(node_config.get("base_url") or key_info.base_url or "")
        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": _MARKDOWN_SEARCH_SYSTEM_PROMPT},
                {"role": "user", "content": ctx.transcript},
            ],
            "enable_search": True,
            "search_options": {
                "search_strategy": node_config.get("search_strategy") or "agent",
                "enable_source": True,
            },
            "stream": True,
            "stream_options": {"include_usage": True},
        }

        t0 = time.monotonic()
        charge_rows: list[dict] = []
        request_cost = 0
        try:
            request_cost, charge_rows = await self._precharge_search_credits(ctx, key_info, node_config, model)
            content, usage = await self._chat_stream(
                endpoint,
                key_info.api_key,
                payload,
                key_info.proxy_config,
                on_delta,
            )
        except (CreditsExhaustedException, ServiceTemporarilyUnavailableException):
            raise
        except Exception as e:
            if ctx.user_email and charge_rows:
                await CreditAccountService().refund(ctx.user_email, charge_rows, request_cost)
                ctx.precharged_credits = max(0, getattr(ctx, "precharged_credits", 0) - request_cost)
            await report_error(key_info, str(e))
            raise

        latency_ms = int((time.monotonic() - t0) * 1000)
        input_tokens = int(usage.get("prompt_tokens") or 0)
        output_tokens = int(usage.get("completion_tokens") or 0)
        total_tokens = int(usage.get("total_tokens") or (input_tokens + output_tokens))

        if ctx.user_email:
            self._emit_usage_event(ctx, key_info, input_tokens, output_tokens, latency_ms)
            asyncio.ensure_future(report_usage(
                key_info,
                tokens_used=total_tokens,
                requests_used=1,
                operation="search",
                user_email=ctx.user_email,
                latency_ms=latency_ms,
                client_platform=ctx.client_platform,
            ))

        self._apply_credits(ctx, key_info, node_config, model)
        logger.info(
            "DashScope web search streamed: model=%s latency_ms=%d tokens=%d",
            model, latency_ms, total_tokens,
        )
        return content.strip() if content.strip() else "## 搜索结果\n\n未获取到有效搜索结果。"

    @staticmethod
    def _chat_completions_endpoint(base_url: str) -> str:
        base_url = (base_url or "https://dashscope.aliyuncs.com/compatible-mode/v1").rstrip("/")
        if base_url.endswith("/chat/completions"):
            return base_url
        if base_url.endswith("/v1"):
            return f"{base_url}/chat/completions"
        return f"{base_url}/compatible-mode/v1/chat/completions"

    @staticmethod
    async def _chat(
        endpoint: str,
        api_key: str,
        payload: dict,
        proxy_config: Optional[dict] = None,
    ) -> tuple[str, dict]:
        timeout = httpx.Timeout(90.0, connect=10.0)
        async with httpx.AsyncClient(
            **httpx_async_client_kwargs(proxy_config, timeout=timeout)
        ) as client:
            resp = await client.post(
                endpoint,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
            if resp.status_code >= 400:
                raise RuntimeError(
                    f"DashScope web search failed: {resp.status_code} "
                    f"{resp.text[:500]}"
                )
            try:
                data = resp.json()
            except ValueError as e:
                raise RuntimeError(
                    f"DashScope web search returned invalid JSON: {resp.text[:500]}"
                ) from e

        choices = data.get("choices") or []
        content_parts: list[str] = []
        for choice in choices:
            message = choice.get("message") or {}
            content = message.get("content")
            if content:
                content_parts.append(content)

        usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
        return "".join(content_parts), usage

    @staticmethod
    async def _chat_stream(
        endpoint: str,
        api_key: str,
        payload: dict,
        proxy_config: Optional[dict],
        on_delta: Callable[[str], Awaitable[None]],
    ) -> tuple[str, dict]:
        timeout = httpx.Timeout(120.0, connect=10.0)
        content_parts: list[str] = []
        usage: dict = {}
        async with httpx.AsyncClient(
            **httpx_async_client_kwargs(proxy_config, timeout=timeout)
        ) as client:
            async with client.stream(
                "POST",
                endpoint,
                headers={
                    "Authorization": f"Bearer {api_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            ) as resp:
                if resp.status_code >= 400:
                    body = await resp.aread()
                    raise RuntimeError(
                        f"DashScope web search failed: {resp.status_code} "
                        f"{body.decode('utf-8', errors='ignore')[:500]}"
                    )
                async for line in resp.aiter_lines():
                    line = line.strip()
                    if not line or line.startswith(":"):
                        continue
                    if not line.startswith("data:"):
                        continue
                    data = line[5:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                    except ValueError:
                        continue
                    if isinstance(chunk.get("usage"), dict):
                        usage = chunk["usage"]
                    for choice in chunk.get("choices") or []:
                        delta = choice.get("delta") or {}
                        text = delta.get("content")
                        if text:
                            content_parts.append(text)
                            await on_delta(text)
        return "".join(content_parts), usage

    @staticmethod
    def _emit_usage_event(
        ctx: "PipelineContext",
        key_info: PoolKeyInfo,
        input_tokens: int,
        output_tokens: int,
        latency_ms: int,
    ) -> None:
        if not ctx.user_email or (input_tokens <= 0 and output_tokens <= 0):
            return
        usage_emit(UsageEvent(
            user_email=ctx.user_email,
            platform=f"{key_info.platform_code or 'dashscope'}_llm",
            operation="search",
            date=BaseUsageExtractor._utc_date(),
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            request_count=1,
            latency_ms=latency_ms,
            api_key_hint=BaseUsageExtractor._mask_api_key(key_info.api_key),
            client_platform=ctx.client_platform,
        ))

    @staticmethod
    def _apply_credits(
        ctx: "PipelineContext",
        key_info: PoolKeyInfo,
        node_config: dict,
        model: str,
    ) -> None:
        if not ctx.credit_calc:
            return

        request_cost = ctx.credit_calc.request_cost(
            node_config.get("pricing_category") or "web_search",
            node_config.get("pricing_platform_code") or key_info.platform_code or "aliyun_search",
            node_config.get("pricing_model") or model,
            node_id=key_info.business_node_id or "web_search",
            provider_id=key_info.provider_id,
        )
        if request_cost > 0:
            ctx.credits_cost += request_cost
            ctx.credits_breakdown.append(BreakdownItem(
                    platform=f"{key_info.platform_code or 'web_search'}_search",
                credits=request_cost,
                search_count=1,
            ))

class TavilySearchProvider(BaseSearchProvider):
    """Tavily 搜索 + LLM Markdown 整理 provider。"""

    async def run(
        self,
        ctx: "PipelineContext",
        node_config: dict,
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        optimized_query = await self._optimize_query(ctx, langchain_callbacks=langchain_callbacks)
        logger.info("Tavily search optimized query=[%s]", optimized_query)

        tavily_key_info, tavily_api_key = await self._get_tavily_key_info(node_config)
        tavily = self._build_tavily_client(tavily_api_key, tavily_key_info.proxy_config)
        if tavily:
            return await self._search_and_summarize(
                tavily, optimized_query, ctx, tavily_key_info, node_config,
                langchain_callbacks=langchain_callbacks,
            )
        return await self._llm_fallback(ctx, optimized_query, langchain_callbacks=langchain_callbacks)

    async def _get_tavily_key_info(self, node_config: dict) -> tuple[PoolKeyInfo, str]:
        key_info, _node, _provider = await pick_key_for_node("web_search", expected_category="web_search")
        logger.info("Tavily key from pool: group=%s id=%s", key_info.group_id, key_info.id)
        return key_info, key_info.api_key

    @staticmethod
    def _build_tavily_client(api_key: str, proxy_config: Optional[dict] = None):
        if not _TAVILY_AVAILABLE:
            logger.error("tavily-python not installed. Run: pip install tavily-python")
            return None
        if not api_key:
            logger.warning("Tavily API key not available")
            return None
        return _TavilyClient(api_key=api_key, proxies=requests_proxies(proxy_config))

    async def _optimize_query(
        self,
        ctx: "PipelineContext",
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        llm, llm_key_info = await get_llm_for_node(node_id="llm_transcribe")
        messages = [
            SystemMessage(content=_SEARCH_QUERY_SYSTEM_PROMPT),
            HumanMessage(content=ctx.transcript),
        ]
        try:
            t0 = time.monotonic()
            config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
            response = await llm.ainvoke(messages, config=config)
            latency_ms = int((time.monotonic() - t0) * 1000)
            query = response.content.strip() if hasattr(response, "content") else ctx.transcript

            if ctx.user_email:
                self._emit_llm_usage(response, ctx, "search_optimize", latency_ms, llm_key_info)

            if ctx.credit_calc and query:
                est_input = ctx.credit_calc._estimate_tokens(ctx.transcript)
                est_output = ctx.credit_calc._estimate_tokens(query)
                bill_in, bill_out, _ = ctx.credit_calc.resolve_billing_tokens(llm_key_info, est_input, est_output)
                cost = ctx.credit_calc.token_cost(bill_in, bill_out, llm_key_info)
                if cost > 0:
                    ctx.credits_cost += cost
                    ctx.credits_breakdown.append(BreakdownItem(
                        platform=f"{llm_key_info.platform_code}_llm",
                        credits=cost,
                        input_tokens=bill_in,
                        output_tokens=bill_out,
                    ))

            return query if query else ctx.transcript
        except Exception as e:
            logger.warning("Query optimization failed: %s, using raw transcript", e)
            return ctx.transcript

    async def _search_and_summarize(
        self,
        tavily_client,
        query: str,
        ctx: "PipelineContext",
        tavily_key_info: PoolKeyInfo,
        node_config: dict,
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        charge_rows: list[dict] = []
        request_cost = 0
        try:
            request_cost, charge_rows = await self._precharge_search_credits(
                ctx,
                tavily_key_info,
                node_config,
                tavily_key_info.model,
            )
            t0 = time.monotonic()
            loop = asyncio.get_event_loop()
            response = await loop.run_in_executor(
                None,
                lambda: tavily_client.search(
                    query=query,
                    search_depth="advanced",
                    max_results=5,
                    include_answer=True,
                ),
            )
            tavily_latency_ms = int((time.monotonic() - t0) * 1000)

            if ctx.user_email:
                event = TavilyExtractor().extract(
                    response,
                    user_email=ctx.user_email,
                    operation="search",
                    latency_ms=tavily_latency_ms,
                    api_key=tavily_key_info.api_key,
                    client_platform=ctx.client_platform,
                )
                if event:
                    usage_emit(event)
                asyncio.ensure_future(report_usage(
                    tavily_key_info,
                    requests_used=1,
                    operation="search",
                    user_email=ctx.user_email,
                    latency_ms=tavily_latency_ms,
                    client_platform=ctx.client_platform,
                ))

            if ctx.credit_calc:
                cost = ctx.credit_calc.request_cost(
                    node_config.get("pricing_category") or tavily_key_info.category,
                    node_config.get("pricing_platform_code") or tavily_key_info.platform_code,
                    node_config.get("pricing_model") or tavily_key_info.model,
                    node_id=tavily_key_info.business_node_id or "web_search",
                    provider_id=tavily_key_info.provider_id,
                )
                if cost > 0:
                    ctx.credits_cost += cost
                    ctx.credits_breakdown.append(BreakdownItem(
                        platform="tavily",
                        credits=cost,
                        search_count=1,
                    ))

        except (CreditsExhaustedException, ServiceTemporarilyUnavailableException):
            raise
        except Exception as e:
            if ctx.user_email and charge_rows:
                await CreditAccountService().refund(ctx.user_email, charge_rows, request_cost)
                ctx.precharged_credits = max(0, getattr(ctx, "precharged_credits", 0) - request_cost)
            await report_error(tavily_key_info, str(e))
            logger.error("Tavily search failed: %s", e)
            return f"## 搜索失败\n\n搜索过程中出现错误：{str(e)}\n\n**查询：** {query}"

        raw_context = self._build_raw_context(query, response)
        logger.debug("Tavily raw context length=%d", len(raw_context))
        return await self._llm_summarize(raw_context, ctx, langchain_callbacks=langchain_callbacks)

    @staticmethod
    def _build_raw_context(query: str, response: dict) -> str:
        parts = [f"用户问题：{query}\n"]

        answer = response.get("answer", "")
        if answer:
            parts.append(f"搜索引擎 AI 摘要：{answer}\n")

        results = response.get("results", [])
        for i, item in enumerate(results, 1):
            title = item.get("title", "无标题")
            url = item.get("url", "")
            content = item.get("content", "").strip()
            parts.append(f"来源 {i}：{title}\n链接：{url}\n内容：{content}\n")

        return "\n".join(parts)

    async def _llm_summarize(
        self,
        raw_context: str,
        ctx: "PipelineContext",
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        llm, llm_key_info = await get_llm_for_node(node_id="llm_transcribe")
        messages = [
            SystemMessage(content=_MARKDOWN_SEARCH_SYSTEM_PROMPT),
            HumanMessage(content=raw_context),
        ]
        try:
            t0 = time.monotonic()
            config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
            response = await llm.ainvoke(messages, config=config)
            latency_ms = int((time.monotonic() - t0) * 1000)
            result = response.content.strip() if hasattr(response, "content") else ""

            if ctx.user_email:
                self._emit_llm_usage(response, ctx, "search_summarize", latency_ms, llm_key_info)

            if ctx.credit_calc and result:
                est_input = ctx.credit_calc._estimate_tokens(raw_context)
                est_output = ctx.credit_calc._estimate_tokens(result)
                bill_in, bill_out, _ = ctx.credit_calc.resolve_billing_tokens(llm_key_info, est_input, est_output)
                cost = ctx.credit_calc.token_cost(bill_in, bill_out, llm_key_info)
                if cost > 0:
                    ctx.credits_cost += cost
                    ctx.credits_breakdown.append(BreakdownItem(
                        platform=f"{llm_key_info.platform_code}_llm",
                        credits=cost,
                        input_tokens=bill_in,
                        output_tokens=bill_out,
                    ))

            return result if result else raw_context
        except Exception as e:
            logger.warning("LLM summarize failed: %s, falling back to raw context", e)
            return raw_context

    async def _llm_summarize_stream(
        self,
        raw_context: str,
        ctx: "PipelineContext",
        on_delta: Callable[[str], Awaitable[None]],
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        llm, llm_key_info = await get_llm_for_node(node_id="llm_transcribe")
        messages = [
            SystemMessage(content=_MARKDOWN_SEARCH_SYSTEM_PROMPT),
            HumanMessage(content=raw_context),
        ]
        try:
            t0 = time.monotonic()
            config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
            parts: list[str] = []
            async for chunk in llm.astream(messages, config=config):
                text = chunk.content if hasattr(chunk, "content") else ""
                if text:
                    parts.append(text)
                    await on_delta(text)
            latency_ms = int((time.monotonic() - t0) * 1000)
            result = "".join(parts).strip()

            if ctx.credit_calc and result:
                est_input = ctx.credit_calc._estimate_tokens(raw_context)
                est_output = ctx.credit_calc._estimate_tokens(result)
                bill_in, bill_out, _ = ctx.credit_calc.resolve_billing_tokens(llm_key_info, est_input, est_output)
                cost = ctx.credit_calc.token_cost(bill_in, bill_out, llm_key_info)
                if cost > 0:
                    ctx.credits_cost += cost
                    ctx.credits_breakdown.append(BreakdownItem(
                        platform=f"{llm_key_info.platform_code}_llm",
                        credits=cost,
                        input_tokens=bill_in,
                        output_tokens=bill_out,
                    ))

            return result if result else raw_context
        except Exception as e:
            logger.warning("LLM summarize stream failed: %s, falling back to non-stream", e)
            return await self._llm_summarize(raw_context, ctx, langchain_callbacks=langchain_callbacks)

    async def _llm_fallback(
        self,
        ctx: "PipelineContext",
        query: str,
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        logger.info("Tavily unavailable, falling back to LLM direct answer")
        llm, key_info = await get_llm_for_node(node_id="llm_transcribe")
        messages = [
            SystemMessage(content=_MARKDOWN_SEARCH_SYSTEM_PROMPT),
            HumanMessage(content=f"请在无法联网搜索时尽力回答以下问题：{query}"),
        ]
        t0 = time.monotonic()
        config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
        response = await llm.ainvoke(messages, config=config)
        latency_ms = int((time.monotonic() - t0) * 1000)
        if ctx.user_email:
            self._emit_llm_usage(response, ctx, "search_fallback", latency_ms, key_info)
        result = response.content.strip() if hasattr(response, "content") else ""
        return f"## 搜索结果（离线模式）\n\n**查询：** {query}\n\n{result}"

    async def run_stream(
        self,
        ctx: "PipelineContext",
        node_config: dict,
        on_delta: Callable[[str], Awaitable[None]],
        langchain_callbacks: Optional[List] = None,
    ) -> str:
        optimized_query = await self._optimize_query(ctx, langchain_callbacks=langchain_callbacks)
        logger.info("Tavily search optimized query=[%s]", optimized_query)

        tavily_key_info, tavily_api_key = await self._get_tavily_key_info(node_config)
        tavily = self._build_tavily_client(tavily_api_key, tavily_key_info.proxy_config)
        if not tavily:
            return await self.run(ctx, node_config, langchain_callbacks=langchain_callbacks)

        charge_rows: list[dict] = []
        request_cost = 0
        try:
            request_cost, charge_rows = await self._precharge_search_credits(
                ctx,
                tavily_key_info,
                node_config,
                tavily_key_info.model,
            )
            t0 = time.monotonic()
            loop = asyncio.get_event_loop()
            response = await loop.run_in_executor(
                None,
                lambda: tavily.search(
                    query=optimized_query,
                    search_depth="advanced",
                    max_results=5,
                    include_answer=True,
                ),
            )
            tavily_latency_ms = int((time.monotonic() - t0) * 1000)

            if ctx.user_email:
                event = TavilyExtractor().extract(
                    response,
                    user_email=ctx.user_email,
                    operation="search",
                    latency_ms=tavily_latency_ms,
                    api_key=tavily_key_info.api_key,
                    client_platform=ctx.client_platform,
                )
                if event:
                    usage_emit(event)
                asyncio.ensure_future(report_usage(
                    tavily_key_info,
                    requests_used=1,
                    operation="search",
                    user_email=ctx.user_email,
                    latency_ms=tavily_latency_ms,
                    client_platform=ctx.client_platform,
                ))

            if ctx.credit_calc:
                cost = ctx.credit_calc.request_cost(
                    node_config.get("pricing_category") or tavily_key_info.category,
                    node_config.get("pricing_platform_code") or tavily_key_info.platform_code,
                    node_config.get("pricing_model") or tavily_key_info.model,
                    node_id=tavily_key_info.business_node_id or "web_search",
                    provider_id=tavily_key_info.provider_id,
                )
                if cost > 0:
                    ctx.credits_cost += cost
                    ctx.credits_breakdown.append(BreakdownItem(
                        platform="tavily",
                        credits=cost,
                        search_count=1,
                    ))
        except (CreditsExhaustedException, ServiceTemporarilyUnavailableException):
            raise
        except Exception as e:
            if ctx.user_email and charge_rows:
                await CreditAccountService().refund(ctx.user_email, charge_rows, request_cost)
                ctx.precharged_credits = max(0, getattr(ctx, "precharged_credits", 0) - request_cost)
            await report_error(tavily_key_info, str(e))
            logger.error("Tavily search failed: %s", e)
            return f"## 搜索失败\n\n搜索过程中出现错误：{str(e)}\n\n**查询：** {optimized_query}"

        raw_context = self._build_raw_context(optimized_query, response)
        logger.debug("Tavily raw context length=%d", len(raw_context))
        return await self._llm_summarize_stream(
            raw_context,
            ctx,
            on_delta,
            langchain_callbacks=langchain_callbacks,
        )


def build_search_provider(implementation: str) -> BaseSearchProvider:
    provider = (implementation or "").lower()
    if provider == "tavily":
        return TavilySearchProvider()
    if provider in {"dashscope_web_search", "dashscope", "aliyun", "qwen"}:
        return DashScopeWebSearchProvider()
    raise RuntimeError(f"Unsupported search implementation: {implementation}")


class SearchNode(BaseNode):
    """联网搜索节点，按配置选择具体 provider。"""

    def __init__(self, llm_service):
        self._llm_service = llm_service

    async def execute(
        self,
        ctx: "PipelineContext",
        langchain_callbacks: Optional[List] = None,
    ) -> None:
        try:
            _node, runtime_provider = await resolve_node_provider("web_search", expected_category="web_search")
            node_config = dict(runtime_provider.config or {})
            node_config["implementation"] = runtime_provider.implementation
            provider = build_search_provider(runtime_provider.implementation)
            if ctx.stream_callback:
                stream_event_callback = getattr(ctx, "stream_event_callback", None)
                if stream_event_callback:
                    await stream_event_callback("search_start", {
                        "agent_intent": "SEARCH",
                        "render": "markdown",
                    })
                ctx.result = await provider.run_stream(
                    ctx,
                    node_config,
                    ctx.stream_callback,
                    langchain_callbacks=langchain_callbacks,
                )
            else:
                ctx.result = await provider.run(
                    ctx,
                    node_config,
                    langchain_callbacks=langchain_callbacks,
                )
        except (CreditsExhaustedException, ServiceTemporarilyUnavailableException):
            raise
        except Exception as e:
            logger.error("SearchNode provider failed: %s", e)
            ctx.result = f"## 搜索失败\n\n搜索过程中出现错误：{str(e)}"
        ctx.action_type = ActionType.show_markdown
        ctx.llm_invoked = True
