"""
providers 包 — 统一注册所有 ASR 和 LLM 提供商。

导入此包时会自动完成所有子类的注册，
业务代码通过 asr.base.get_provider() / llm.base.build_llm() 获取实例。
"""
from app.providers.asr import base as asr_base  # noqa: F401
from app.providers.llm import base as llm_base  # noqa: F401
from app.providers.realtime_asr import base as realtime_asr_base  # noqa: F401

# 注册所有 ASR 提供商
from app.providers.asr import openai_compatible as asr_openai_compatible  # noqa: F401
from app.providers.asr import volcengine as asr_volcengine  # noqa: F401
from app.providers.asr import dashscope as asr_dashscope  # noqa: F401
from app.providers.realtime_asr import dashscope as realtime_asr_dashscope  # noqa: F401
from app.providers.realtime_asr import volcengine as realtime_asr_volcengine  # noqa: F401

# 注册所有 LLM 提供商
from app.providers.llm import openai_compatible as llm_openai_compatible  # noqa: F401
from app.providers.llm import anthropic as llm_anthropic  # noqa: F401
from app.providers.llm import ollama as llm_ollama  # noqa: F401
from app.providers.llm import azure as llm_azure  # noqa: F401

from app.providers.llm.runtime import get_llm_for_node  # noqa: F401
