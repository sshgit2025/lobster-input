"""
Azure OpenAI LLM 提供商。

管理端配置:
  category       = llm_chat
  implementation = azure_openai
  pool_group_id  = 号池中的 Azure OpenAI 分组
  config         = {"api_version": "2024-02-01"}（可选）
"""
from typing import Optional
from langchain_core.language_models import BaseChatModel
from app.providers.llm.base import BaseLLMProvider, register_llm
from app.services.infra.proxy_config import parse_proxy_config

_DEFAULT_API_VERSION = "2024-02-01"


class AzureOpenAILLMProvider(BaseLLMProvider):
    def build_chat_model(
        self,
        api_key: str,
        base_url: str,
        model: str,
        temperature: float = 0.0,
        extra_config: Optional[dict] = None,
        **kwargs,
    ) -> BaseChatModel:
        from langchain_openai import AzureChatOpenAI
        api_version = (extra_config or {}).get("api_version", _DEFAULT_API_VERSION)
        proxy = parse_proxy_config(kwargs.pop("proxy_config", None))
        if proxy.is_enabled:
            kwargs.setdefault("openai_proxy", proxy.proxy_url)
        return AzureChatOpenAI(
            azure_deployment=model,
            temperature=temperature,
            api_key=api_key,
            azure_endpoint=base_url,
            api_version=api_version,
            timeout=600,
            **kwargs,
        )


register_llm("azure_openai", AzureOpenAILLMProvider)
