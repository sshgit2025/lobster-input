"""Build LLM instances from business-node runtime configuration."""
import logging
import time

from langchain_core.language_models import BaseChatModel

from app.providers.llm.base import build_llm
from app.services.infra.api_pool_client import PoolKeyInfo
from app.services.infra.runtime_provider_config import pick_key_for_node

logger = logging.getLogger("voice_input.model_provider")


async def get_llm_for_node(
    node_id: str,
    temperature: float = 0.0,
    model_override: str = "",
    **kwargs,
) -> tuple[BaseChatModel, PoolKeyInfo]:
    t_total = time.monotonic()
    key_info, _node, provider = await pick_key_for_node(node_id, expected_category="llm_chat")
    implementation = provider.implementation
    model = model_override or key_info.model
    if not implementation:
        raise RuntimeError(f"Provider implementation missing for node={node_id}")
    if not model:
        raise RuntimeError(f"Pool group {provider.pool_group_id} returned key without model for node={node_id}")
    if not key_info.base_url:
        raise RuntimeError(f"Pool group {provider.pool_group_id} returned key without base_url for node={node_id}")

    llm = build_llm(
        platform=implementation,
        api_key=key_info.api_key,
        base_url=key_info.base_url,
        model=model,
        temperature=temperature,
        extra_config=key_info.extra_config,
        proxy_config=key_info.proxy_config,
        **kwargs,
    )
    logger.info(
        "LLM built for node=%s provider=%s impl=%s group=%s platform=%s model=%s total=%dms",
        node_id, provider.provider_id, implementation, provider.pool_group_id,
        key_info.platform_code, model, int((time.monotonic() - t_total) * 1000),
    )
    return llm, key_info
