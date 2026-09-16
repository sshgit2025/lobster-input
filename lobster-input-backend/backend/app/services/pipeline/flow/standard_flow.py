"""
StandardFlow — 唯一标准处理流程（flow_name = "standard"）。

整合现有4个平台（Mac / iOS / Windows / Android）的 Pipeline 集合，
复用 platform_pipelines.py 中已定义的各平台单例，保持行为与重构前完全一致。

flow_name "standard" 的两个用途：
  1. 映射到 templates/standard/ 提示词目录
  2. 作为号池 pick_key 的 required_tag 值，号池中标有 tags=["standard"] 的 Key
     会被优先选中；无标签约束的 Key 作为通用兜底。
"""
from app.services.pipeline.flow.base import BasePipelineFlow
from app.services.pipeline.v1.platform_pipelines import (
    PlatformPipelineSet,
    MAC_PIPELINES,
    IOS_PIPELINES,
    WINDOWS_PIPELINES,
    ANDROID_PIPELINES,
)

_PLATFORM_PIPELINE_MAP: dict[str, PlatformPipelineSet] = {
    "macos":   MAC_PIPELINES,
    "ios":     IOS_PIPELINES,
    "windows": WINDOWS_PIPELINES,
    "android": ANDROID_PIPELINES,
    "harmony": ANDROID_PIPELINES,  # 鸿蒙端完全复刻安卓客户端行为，直接复用 Android 流水线
}

_DEFAULT_PLATFORM = "macos"


class StandardFlow(BasePipelineFlow):
    """
    标准处理流程，当前系统唯一流程。

    封装4个平台的完整 Pipeline 集合，行为与重构前各平台 Pipeline 保持完全一致。
    未来新增流程（如专为特定语言优化的流程）时，继承 BasePipelineFlow 另行实现即可。
    """

    @property
    def flow_name(self) -> str:
        return "standard"

    def get_platform_pipelines(self, client_platform: str) -> PlatformPipelineSet:
        """
        按客户端平台标识返回对应的 PlatformPipelineSet 单例。
        未知平台降级到 macos 默认集合。
        """
        return _PLATFORM_PIPELINE_MAP.get(client_platform, _PLATFORM_PIPELINE_MAP[_DEFAULT_PLATFORM])


STANDARD_FLOW = StandardFlow()
