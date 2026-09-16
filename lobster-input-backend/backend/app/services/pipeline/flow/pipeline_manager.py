"""
PipelineManager — 流程管理器（统一入口）。

职责：
  1. 接收客户端平台标识和 UI 语言类型（X-Accept-Language）
  2. 委托 PipelineSelector 根据客户端 UI 语言选择合适的处理流程
  3. 从选中流程中按 operation 获取具体 Pipeline 实例
  4. 暴露选中流程的 flow_name（供提示词目录路由和号池标签筛选使用）

语言类型说明：
  - client_ui_lang（X-Accept-Language）：客户端 UI 语言，用于流程选择
  - transcript_language（ASR 返回）：ASR 识别语言，用于提示词目录路由
  两者含义不同，不可混用。

其它业务（接口层、各 audio_*.py）只需调用 PipelineManager，
无需关心底层流程选择逻辑。
"""
import logging
from typing import TYPE_CHECKING, Optional

from app.services.pipeline.flow.pipeline_selector import PipelineSelector

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline

logger = logging.getLogger("voice_input.pipeline_manager")


class PipelineManager:
    """
    流程管理器，对外提供两个核心接口：
      - get_pipeline()  获取可执行的 Pipeline 实例
      - get_flow_name() 获取当前流程名称（供提示词路由和号池标签筛选）
    """

    @staticmethod
    def get_pipeline(
        client_platform: str,
        operation: str,
        client_ui_lang: Optional[str] = None,
    ) -> "AudioProcessPipeline":
        """
        根据客户端 UI 语言、平台、操作类型获取具体 Pipeline 实例。

        :param client_platform: 客户端平台标识（macos / ios / windows / android）
        :param operation:       操作类型（transcribe / rewrite / agent）
        :param client_ui_lang:  X-Accept-Language Header 值（客户端 UI 语言，用于流程选择）
        :return: 对应的 AudioProcessPipeline 实例
        """
        flow = PipelineSelector.select(client_ui_lang)
        pipeline = flow.get_pipeline(client_platform, operation)
        logger.info(
            "[PipelineManager] platform=%r op=%r ui_lang=%r → flow=%r pipeline=%s",
            client_platform, operation, client_ui_lang or "none",
            flow.flow_name, type(pipeline).__name__,
        )
        return pipeline

    @staticmethod
    def get_flow_name(client_ui_lang: Optional[str] = None) -> str:
        """
        获取当前客户端 UI 语言对应流程的名称。
        用于提示词目录路由（templates/{flow_name}/）和号池标签筛选（required_tag）。

        :param client_ui_lang: X-Accept-Language Header 值（客户端必须传递）
        :return: 流程名称字符串（如 "standard"）
        """
        if not client_ui_lang:
            logger.warning(
                "[PipelineManager] X-Accept-Language header missing, falling back to default flow. "
                "Clients must provide this header."
            )
        flow = PipelineSelector.select(client_ui_lang)
        return flow.flow_name
