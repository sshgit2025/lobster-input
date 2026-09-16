"""
BasePipelineFlow — 流程基类。

每个流程封装一套完整的平台 Pipeline 集合（transcribe / rewrite / agent），
对外暴露统一的 get_pipeline() 接口供调用方按 operation 分发。

设计原则：
  - 每个流程对应一个 flow_name（固定字符串名称，如 "standard"，
    同时用作号池密钥标签筛选的 required_tag 值）
  - 子类通过重写 get_platform_pipelines() 返回各平台 Pipeline 集合
  - 调用方不感知具体流程实现，通过 BasePipelineFlow 统一操作
"""
from abc import ABC, abstractmethod
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline
    from app.services.pipeline.v1.platform_pipelines import PlatformPipelineSet


class BasePipelineFlow(ABC):
    """流程基类，每个具体流程继承此类并实现平台 Pipeline 集合的构建。"""

    @property
    @abstractmethod
    def flow_name(self) -> str:
        """流程固定名称（如 "standard"），用于提示词目录路由和号池标签筛选。"""

    @abstractmethod
    def get_platform_pipelines(self, client_platform: str) -> "PlatformPipelineSet":
        """
        根据客户端平台标识返回对应的 PlatformPipelineSet。

        :param client_platform: 客户端平台标识（macos / ios / windows / android）
        :return: 对应平台的 PlatformPipelineSet 实例
        """

    def get_pipeline(self, client_platform: str, operation: str) -> "AudioProcessPipeline":
        """
        按平台和 operation 获取具体 Pipeline 实例。

        :param client_platform: 客户端平台标识
        :param operation: 操作类型（transcribe / rewrite / agent）
        :return: 对应的 AudioProcessPipeline 实例
        """
        platform_pipelines = self.get_platform_pipelines(client_platform)
        return platform_pipelines.get(operation)
