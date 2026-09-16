"""
Anthropic LLM 提供商。

管理端配置:
  category       = llm_chat
  implementation = anthropic
  pool_group_id  = 号池中的 Anthropic 分组
"""
from typing import Optional
from langchain_core.language_models import BaseChatModel
from app.providers.llm.base import BaseLLMProvider, register_llm
from app.services.infra.proxy_config import parse_proxy_config


class AnthropicLLMProvider(BaseLLMProvider):
    def build_chat_model(
        self,
        api_key: str,
        base_url: str,
        model: str,
        temperature: float = 0.0,
        extra_config: Optional[dict] = None,
        **kwargs,
    ) -> BaseChatModel:
        from langchain_anthropic import ChatAnthropic
        proxy = parse_proxy_config(kwargs.pop("proxy_config", None))
        if proxy.is_enabled:
            kwargs.setdefault("anthropic_proxy", proxy.proxy_url)
        return ChatAnthropic(
            model=model,
            temperature=temperature,
            api_key=api_key,
            base_url=base_url or None,
            timeout=600,
            **kwargs,
        )


register_llm("anthropic", AnthropicLLMProvider)
