"""
ASR Provider 抽象基类。

所有 ASR 提供商必须继承此类并实现 transcribe() 方法。
transcribe() 返回 ASRResult，包含识别文本和检测到的语言代码。

新增提供商步骤：
  1. 在 app/providers/asr/ 目录下新建文件，如 my_provider.py
  2. 继承 BaseASRProvider，实现 transcribe()
  3. 调用 register("my_provider", MyProvider) 注册

注册后在管理端把 ASR 业务节点绑定到对应 provider，再由 provider 挂载号池分组。
后端运行时只读取管理端配置，不在代码里指定具体平台。
"""
from abc import ABC, abstractmethod
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass
class ASRResult:
    """ASR 识别结果。"""
    text: str
    language: str = ""


class BaseASRProvider(ABC):
    """ASR 提供商抽象基类。"""

    @abstractmethod
    async def transcribe(
        self,
        audio_path: Path,
        api_key: str,
        base_url: str,
        model: str,
        prompt: str = "",
        language: str = "",
        extra_config: Optional[dict] = None,
        proxy_config: Optional[dict] = None,
    ) -> ASRResult:
        """
        语音识别入口。

        :param audio_path: 本地音频文件路径
        :param api_key: 号池分发的 API Key
        :param base_url: 号池分发的 Base URL（空则使用提供商默认）
        :param model: 号池分发的模型名称
        :param prompt: Whisper-style prompt（热词提示）
        :param language: 强制指定语言代码（空则自动检测）
        :param extra_config: 号池 Key 的 extra_config 字段（提供商特有配置）
        :param proxy_config: 号池 Key 的代理配置
        :return: ASRResult(text, language)
        """


# ── Provider 注册表 ──

_ASR_REGISTRY: dict[str, type[BaseASRProvider]] = {}


def register(name: str, cls: type[BaseASRProvider]) -> None:
    """注册 ASR 提供商，name 为小写标识符。"""
    _ASR_REGISTRY[name.lower()] = cls


def get_provider(name: str) -> BaseASRProvider:
    """
    按名称获取 ASR 提供商实例。
    名称来自号池 Key 的 platform 字段或 extra_config["asr_provider"]。
    """
    cls = _ASR_REGISTRY.get(name.lower())
    if cls is None:
        raise ValueError(
            f"Unknown ASR provider: '{name}'. "
            f"Available: {list(_ASR_REGISTRY.keys())}"
        )
    return cls()
