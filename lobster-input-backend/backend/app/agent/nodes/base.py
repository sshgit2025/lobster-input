"""
BaseNode — Agent 意图处理节点基类。

所有意图节点必须继承此类并实现 execute() 方法。
节点直接操作 PipelineContext（修改 result / action_type 等字段），
无需关心上下游流程。
"""
from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Optional, List

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import PipelineContext


class BaseNode(ABC):
    """Agent 意图处理节点基类。"""

    @abstractmethod
    async def execute(self, ctx: "PipelineContext",
                      langchain_callbacks: Optional[List] = None) -> None:
        """
        执行节点业务逻辑，直接修改 ctx 中的字段。

        子类实现应设置：
          ctx.result       — 最终返回给客户端的文本
          ctx.action_type  — 客户端操作类型

        langchain_callbacks: 外部父 trace 传入的 LangChain callback，用于 LangWatch child span。
        """
