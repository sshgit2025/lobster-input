"""
LLM Provider 抽象基类。

所有 LLM 提供商必须继承此类并实现 build_chat_model() 方法。
build_chat_model() 返回 LangChain BaseChatModel 实例，供 AgentFactory 使用。

新增提供商步骤：
  1. 在 app/providers/ 目录下新建文件，如 llm_my_provider.py
  2. 继承 BaseLLMProvider，实现 build_chat_model()
  3. 调用 register_llm("my_provider", MyProvider) 注册

注册后在管理端把 LLM 业务节点绑定到对应 provider，再由 provider 挂载号池分组。
后端运行时只读取管理端配置，不在代码里指定具体平台。
"""
from abc import ABC, abstractmethod
from typing import Optional
from langchain_core.language_models import BaseChatModel


class BaseLLMProvider(ABC):
    """LLM 提供商抽象基类。"""

    @abstractmethod
    def build_chat_model(
        self,
        api_key: str,
        base_url: str,
        model: str,
        temperature: float = 0.0,
        extra_config: Optional[dict] = None,
        **kwargs,
    ) -> BaseChatModel:
        """
        构建 LangChain ChatModel 实例。

        :param api_key: 号池分发的 API Key
        :param base_url: 号池分发的 Base URL
        :param model: 模型名称
        :param temperature: 采样温度
        :param extra_config: 号池 Key 的 extra_config 字段（提供商特有配置）
        :return: LangChain BaseChatModel 实例
        """


# ── Provider 注册表 ──

_LLM_REGISTRY: dict[str, type[BaseLLMProvider]] = {}


def register_llm(name: str, cls: type[BaseLLMProvider]) -> None:
    """注册 LLM 提供商，name 为小写标识符（与号池 Key 的 platform 对应）。"""
    _LLM_REGISTRY[name.lower()] = cls


def build_llm(
    platform: str,
    api_key: str,
    base_url: str,
    model: str,
    temperature: float = 0.0,
    extra_config: Optional[dict] = None,
    **kwargs,
) -> BaseChatModel:
    """
    按 platform 名称获取提供商并构建 LLM 实例。
    platform 来自号池 Key 的 platform 字段。
    """
    cls = _LLM_REGISTRY.get(platform.lower())
    if cls is None:
        raise ValueError(
            f"Unknown LLM provider: '{platform}'. "
            f"Available: {list(_LLM_REGISTRY.keys())}"
        )
    return cls().build_chat_model(
        api_key=api_key,
        base_url=base_url,
        model=model,
        temperature=temperature,
        extra_config=extra_config,
        **kwargs,
    )
