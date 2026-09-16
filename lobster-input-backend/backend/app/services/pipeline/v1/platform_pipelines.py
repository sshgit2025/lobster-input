"""
平台专属 Pipeline — 各端（Mac / iOS / Windows / Android）的语音处理流水线入口。

设计原则：
  - 每个平台对应一套 Pipeline 组合，语义清晰，流程可见
  - Mac 端：完整功能（transcribe / rewrite / agent + OpenClaw）
  - iOS 端：纯语音输入法功能（transcribe / rewrite，无 agent）
  - Windows 端：桌面端基础功能（transcribe / rewrite / agent + OpenClaw）
  - Android 端：基础功能（transcribe / rewrite，agent 待适配）

提示词分流通过 client_platform 字段由 PromptManager 自动路由到对应平台子目录：
  macos                     → templates/mac/
  ios                        → templates/ios/
  windows                    → templates/windows/
  android                    → templates/android/

各平台接口层（audio_*.py）调用对应 PlatformPipelineSet，
路由层已强制注入正确的 client_platform，无需 Pipeline 层再做判断。
"""
from dataclasses import dataclass
from typing import Optional

from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline
from app.services.pipeline.v1.rewrite_pipeline import RewritePipeline
from app.services.pipeline.v1.agent_pipeline import AgentPipeline
from app.services.pipeline.v1.ios_audio_pipeline import iOSTranscribePipeline, iOSRewritePipeline
from app.services.pipeline.v1.android_audio_pipeline import AndroidTranscribePipeline, AndroidRewritePipeline


# ── Mac 端 Pipeline 组合 ──────────────────────────────────────────
# 完整功能：transcribe（基类） / rewrite（RewritePipeline） / agent（AgentPipeline + OpenClaw）

class MacTranscribePipeline(AudioProcessPipeline):
    """Mac 端 transcribe 流水线（基类默认行为即为 Mac 流程，保持稳定）。"""


class MacRewritePipeline(RewritePipeline):
    """Mac 端 rewrite 流水线（继承 RewritePipeline，行为与现有 Mac 完全一致）。"""


class MacAgentPipeline(AgentPipeline):
    """Mac 端 agent 流水线（继承 AgentPipeline，含完整 OpenClaw 路由逻辑）。"""


# ── Windows 端 Pipeline 组合 ──────────────────────────────────────
# 桌面端功能：提示词读取 templates/windows/，保留 Windows 平台语义

class WindowsTranscribePipeline(AudioProcessPipeline):
    """
    Windows 端 transcribe 流水线。
    提示词由 PromptManager 自动读取 templates/windows/transcribe.txt。
    """


class WindowsRewritePipeline(RewritePipeline):
    """
    Windows 端 rewrite 流水线。
    提示词由 PromptManager 自动读取 templates/windows/rewrite.txt。
    """


class WindowsAgentPipeline(AgentPipeline):
    """
    Windows 端 agent 流水线。
    继承 AgentPipeline，OpenClaw 走桌面端通用链路。
    提示词由 PromptManager 自动读取 templates/windows/agent_intent.txt。
    """


class AndroidAgentPipeline(AgentPipeline):
    """
    Android 端 agent 流水线。
    提示词由 PromptManager 自动读取 templates/android/agent_intent.txt。
    """


@dataclass
class PlatformPipelineSet:
    """
    封装某个平台的全部 Pipeline 实例，供接口层按 operation 分发。

    使用示例：
        pipelines = MAC_PIPELINES
        pipeline = pipelines.get(operation)
    """
    transcribe: AudioProcessPipeline
    rewrite: RewritePipeline
    agent: Optional[AgentPipeline]
    _default: AudioProcessPipeline

    def get(self, operation: str) -> AudioProcessPipeline:
        """按 operation 返回对应 Pipeline，未注册的 operation 使用 transcribe 作为默认。"""
        mapping = {
            "transcribe": self.transcribe,
            "rewrite":    self.rewrite,
        }
        if self.agent is not None:
            mapping["agent"] = self.agent
        return mapping.get(operation, self._default)


# ── 各平台 Pipeline 单例集合 ─────────────────────────────────────

MAC_PIPELINES = PlatformPipelineSet(
    transcribe=MacTranscribePipeline(),
    rewrite=MacRewritePipeline(),
    agent=MacAgentPipeline(),
    _default=MacTranscribePipeline(),
)

IOS_PIPELINES = PlatformPipelineSet(
    transcribe=iOSTranscribePipeline(),
    rewrite=iOSRewritePipeline(),
    agent=None,
    _default=iOSTranscribePipeline(),
)

WINDOWS_PIPELINES = PlatformPipelineSet(
    transcribe=WindowsTranscribePipeline(),
    rewrite=WindowsRewritePipeline(),
    agent=WindowsAgentPipeline(),
    _default=WindowsTranscribePipeline(),
)

ANDROID_PIPELINES = PlatformPipelineSet(
    transcribe=AndroidTranscribePipeline(),
    rewrite=AndroidRewritePipeline(),
    agent=None,
    _default=AndroidTranscribePipeline(),
)
