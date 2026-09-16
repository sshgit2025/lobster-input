"""
iOS 端音频处理流水线。

这里保留 iOS 自己的 Pipeline 类，业务流程对齐 Mac 的 transcribe / rewrite，
但不复用 MacPipeline 类，避免后续平台定制互相影响。
"""
from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline
from app.services.pipeline.v1.rewrite_pipeline import RewritePipeline


class iOSTranscribePipeline(AudioProcessPipeline):
    """iOS 端 transcribe 流水线，当前流程与 Mac transcribe 保持一致。"""


class iOSRewritePipeline(RewritePipeline):
    """iOS 端 rewrite 流水线，当前流程与 Mac rewrite 保持一致。"""
