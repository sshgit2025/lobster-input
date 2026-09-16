"""
Android 端音频处理流水线。

Android 保留自己的 Pipeline 类，当前 transcribe / rewrite 流程与 iOS/Mac 对齐，
但不复用其它平台的 Pipeline 类，方便后续做 Android 专属定制。
"""
from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline
from app.services.pipeline.v1.rewrite_pipeline import RewritePipeline


class AndroidTranscribePipeline(AudioProcessPipeline):
    """Android 端 transcribe 流水线，当前流程与 Mac/iOS transcribe 保持一致。"""


class AndroidRewritePipeline(RewritePipeline):
    """Android 端 rewrite 流水线，当前流程与 Mac/iOS rewrite 保持一致。"""
