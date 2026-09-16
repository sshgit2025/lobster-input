"""
Ollama 本地 LLM 提供商。

管理端配置:
  category       = llm_chat
  implementation = ollama
  pool_group_id  = 号池中的 Ollama 分组
"""
from typing import Optional
from langchain_core.language_models import BaseChatModel
from app.providers.llm.base import BaseLLMProvider, register_llm

_DEFAULT_BASE_URL = "http://localhost:11434"


class OllamaLLMProvider(BaseLLMProvider):
    def build_chat_model(
        self,
        api_key: str,
        base_url: str,
        model: str,
        temperature: float = 0.0,
        extra_config: Optional[dict] = None,
        **kwargs,
    ) -> BaseChatModel:
        from langchain_community.chat_models import ChatOllama
        kwargs.pop("proxy_config", None)
        return ChatOllama(
            model=model,
            temperature=temperature,
            base_url=base_url or _DEFAULT_BASE_URL,
            request_timeout=600,
            **kwargs,
        )


register_llm("ollama", OllamaLLMProvider)
