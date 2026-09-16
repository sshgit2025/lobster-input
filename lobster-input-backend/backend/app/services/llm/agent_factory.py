"""
AgentFactory — 按 operation 类型分发到不同的 Agent 调用模式。

三种模式：
  1. 直接调用（transcribe）
     - 不绑定工具，LLM 自由生成
     - 纠偏类输入直接返回纠偏文本，命令式输入执行生成后返回
     - 从 response.content 提取结果

  2. 单次工具调用（rewrite）
     - bind_tools + tool_choice="any" 强制单次调用
     - 无 selected_text：使用 submit_text 工具，从 text 参数提取结果
     - 有 selected_text：使用 rewrite_selected 工具，从 rewritten 参数提取结果
       将 selected_text 作为工具参数 original 传递，语音指令作为 HumanMessage，
       彻底分离"操作对象"与"操作指令"，避免模型将指令本身当作操作对象

  3. React Agent 循环（agent）
     - langgraph create_react_agent 多轮推理
     - 从消息历史中提取最后一次 submit_text 工具调用结果
"""
import logging
import time
from typing import Optional, List

from langchain_core.language_models import BaseChatModel
from langchain_core.messages import SystemMessage
from langchain_core.runnables import RunnableConfig
from langgraph.prebuilt import create_react_agent

from app.tools import REWRITE_TOOLS, REWRITE_SELECTED_TOOLS, AGENT_TOOLS

logger = logging.getLogger("voice_input.agent_factory")

SUBMIT_TOOL_NAME = "submit_text"
REWRITE_SELECTED_TOOL_NAME = "rewrite_selected"

DIRECT_OPERATIONS = {"transcribe"}
SINGLE_CALL_OPERATIONS = {"rewrite"}
REACT_AGENT_OPERATIONS = {"agent"}


class AgentFactory:

    @staticmethod
    async def run(
        llm: BaseChatModel,
        operation: str,
        messages: list,
        has_selected_text: bool = False,
        langchain_callbacks: Optional[List] = None,
    ) -> tuple[str, object]:
        """
        根据 operation 分发到直接调用、单次工具调用或 react agent。

        messages 为完整的 LangChain message 列表，结构为：
          [SystemMessage, HumanMessage(历史1), AIMessage(历史1), ..., HumanMessage(本轮)]

        has_selected_text: rewrite 时是否有选中文本，决定使用哪套工具。
        langchain_callbacks: LangWatch 等监控框架的 LangChain callback 列表，用于完整链路追踪。

        Returns:
            (result_text, last_response): 结果文本 + 最后一次 LLM 响应对象（用于 token 统计）
        """
        if operation in DIRECT_OPERATIONS:
            return await AgentFactory._run_direct(llm, messages, langchain_callbacks)
        elif operation in SINGLE_CALL_OPERATIONS:
            if has_selected_text:
                return await AgentFactory._run_single_tool_call(
                    llm, messages, REWRITE_SELECTED_TOOLS, REWRITE_SELECTED_TOOL_NAME, langchain_callbacks
                )
            else:
                return await AgentFactory._run_single_tool_call(
                    llm, messages, REWRITE_TOOLS, SUBMIT_TOOL_NAME, langchain_callbacks
                )
        elif operation in REACT_AGENT_OPERATIONS:
            return await AgentFactory._run_react_agent(llm, messages, AGENT_TOOLS, langchain_callbacks)
        else:
            return await AgentFactory._run_direct(llm, messages, langchain_callbacks)

    @staticmethod
    async def _run_direct(
        llm: BaseChatModel,
        messages: list,
        langchain_callbacks: Optional[List] = None,
    ) -> tuple[str, object]:
        """
        直接调用模式（transcribe）。
        不绑定工具，LLM 自由生成内容，从 response.content 提取结果。
        适用于：纠偏（直接返回纠偏文本）和命令式生成（LLM 自由生成后返回）。
        """
        config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
        response = await llm.ainvoke(messages, config=config)
        content = response.content if hasattr(response, "content") else str(response)
        logger.info("Direct call: got %d chars", len(content))
        return content.strip(), response

    @staticmethod
    async def _run_single_tool_call(
        llm: BaseChatModel,
        messages: list,
        tools: list,
        target_tool_name: str,
        langchain_callbacks: Optional[List] = None,
    ) -> tuple[str, object]:
        """
        单次工具调用模式（rewrite）。
        强制 LLM 调用指定工具，从 tool_call 参数中提取结果文本。
        target_tool_name 决定从哪个工具参数提取：
          - submit_text: 提取 args["text"]
          - rewrite_selected: 提取 args["rewritten"]
        """
        t_total = time.monotonic()
        t_bind = time.monotonic()
        llm_with_tools = llm.bind_tools(tools, tool_choice="any")
        bind_ms = int((time.monotonic() - t_bind) * 1000)
        config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
        t_invoke = time.monotonic()
        response = await llm_with_tools.ainvoke(messages, config=config)
        invoke_ms = int((time.monotonic() - t_invoke) * 1000)
        logger.info(
            "[SingleToolCall][timing] target=%s bind=%dms ainvoke=%dms total_before_extract=%dms",
            target_tool_name, bind_ms, invoke_ms,
            int((time.monotonic() - t_total) * 1000),
        )

        logger.debug(
            "[SingleToolCall] target=%s has_tool_calls=%s content_preview=%r",
            target_tool_name,
            bool(hasattr(response, "tool_calls") and response.tool_calls),
            (response.content[:80] if hasattr(response, "content") else "")[:80],
        )

        if hasattr(response, "tool_calls") and response.tool_calls:
            logger.debug("[SingleToolCall] tool_calls=%s", [tc["name"] for tc in response.tool_calls])
            for tc in response.tool_calls:
                if tc["name"] == target_tool_name:
                    if target_tool_name == REWRITE_SELECTED_TOOL_NAME:
                        result = tc["args"].get("rewritten", "")
                    else:
                        result = tc["args"].get("text", "")
                    logger.info(
                        "[SingleToolCall] OK tool=%s extracted_len=%d result_preview=%r",
                        target_tool_name, len(result), result[:60],
                    )
                    return result, response
            # 回退：尝试任意工具的任意结果字段
            tc = response.tool_calls[0]
            result = tc["args"].get("rewritten") or tc["args"].get("text", "")
            logger.warning(
                "[SingleToolCall] fallback tool=%s (expected %s) result_preview=%r",
                tc["name"], target_tool_name, result[:60],
            )
            return result, response

        logger.warning(
            "[SingleToolCall] NO tool call returned! content=%r",
            (response.content[:200] if hasattr(response, "content") else str(response))[:200],
        )
        return (response.content if hasattr(response, "content") else str(response)), response

    @staticmethod
    async def _run_react_agent(
        llm: BaseChatModel,
        messages: list,
        tools: list,
        langchain_callbacks: Optional[List] = None,
    ) -> tuple[str, object]:
        """
        React Agent 循环模式（agent）。
        agent 最终返回的文本忽略，从消息历史中提取最后一次 submit_text 工具调用结果。
        返回最后一条 AI 消息作为 last_response 供 token 统计使用。
        """
        system_prompt = ""
        history_messages = []
        for msg in messages:
            if isinstance(msg, SystemMessage):
                system_prompt = msg.content
            else:
                history_messages.append(msg)

        agent = create_react_agent(llm, tools, prompt=system_prompt)
        config = RunnableConfig(callbacks=langchain_callbacks) if langchain_callbacks else {}
        result = await agent.ainvoke({"messages": history_messages}, config=config)

        last_response = result["messages"][-1] if result.get("messages") else None

        for msg in reversed(result["messages"]):
            if hasattr(msg, "tool_calls") and msg.tool_calls:
                for tc in msg.tool_calls:
                    if tc["name"] == SUBMIT_TOOL_NAME:
                        logger.info("React agent: extracted %d chars from submit_text", len(tc["args"].get("text", "")))
                        return tc["args"]["text"], last_response

        last_msg = result["messages"][-1]
        logger.warning("React agent: no submit_text found, using last message content")
        return (last_msg.content if hasattr(last_msg, "content") else str(last_msg)), last_response
