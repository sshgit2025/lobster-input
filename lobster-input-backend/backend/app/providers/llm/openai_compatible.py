"""
OpenAI 兼容 LLM 提供商。
支持所有兼容 OpenAI Chat Completions 接口的提供商:
  - OpenAI
  - DeepSeek
  - Groq
  - 火山引擎方舟（doubao / volcengine）
  - 阿里云百炼 Qwen（aliyun / qwen）
  - 任何实现了 OpenAI 兼容接口的服务

号池中此类 Key 的 platform 字段填写对应供应商名称即可。
"""
from typing import Optional
from langchain_core.language_models import BaseChatModel
from app.providers.llm.base import BaseLLMProvider, register_llm
from app.services.infra.proxy_config import parse_proxy_config


def _default_extra_body(base_url: str, model: str, extra_config: Optional[dict]) -> dict:
    extra_body = dict((extra_config or {}).get("extra_body") or {})
    is_qwen_dashscope = "dashscope" in (base_url or "").lower() or model.lower().startswith("qwen")
    if is_qwen_dashscope and "enable_thinking" not in extra_body:
        extra_body["enable_thinking"] = False
    return extra_body


class OpenAICompatibleLLMProvider(BaseLLMProvider):
    """OpenAI ChatCompletions 兼容接口 LLM 提供商。"""

    def build_chat_model(
        self,
        api_key: str,
        base_url: str,
        model: str,
        temperature: float = 0.0,
        extra_config: Optional[dict] = None,
        **kwargs,
    ) -> BaseChatModel:
        from langchain_openai import ChatOpenAI
        extra_body = _default_extra_body(base_url, model, extra_config)
        proxy = parse_proxy_config(kwargs.pop("proxy_config", None))
        if proxy.is_enabled:
            kwargs.setdefault("openai_proxy", proxy.proxy_url)
        return ChatOpenAI(
            model=model,
            temperature=temperature,
            api_key=api_key,
            base_url=base_url or None,
            timeout=600,
            extra_body=extra_body or None,
            **kwargs,
        )


register_llm("openai", OpenAICompatibleLLMProvider)
register_llm("deepseek", OpenAICompatibleLLMProvider)
register_llm("groq", OpenAICompatibleLLMProvider)
register_llm("volcengine", OpenAICompatibleLLMProvider)
register_llm("doubao", OpenAICompatibleLLMProvider)
register_llm("aliyun", OpenAICompatibleLLMProvider)
register_llm("qwen", OpenAICompatibleLLMProvider)
register_llm("openai_compatible", OpenAICompatibleLLMProvider)
