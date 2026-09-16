import importlib
import pkgutil
from typing import Any

from fastapi import HTTPException

from app.services.payment_providers.base import PaymentProviderAdapter, _PROVIDER_REGISTRY


def _autodiscover_adapters() -> None:
    """自动 import 本包内所有渠道子类模块,触发其 __init_subclass__ 完成注册。

    新增支付渠道 = 在本包内新建一个 `xxx.py`、定义 `class XxxAdapter(PaymentProviderAdapter)`
    并设置 `code`/capability —— 扫描到即加载注册,无需改本文件或任何现有代码。
    """
    import app.services.payment_providers as pkg
    for module in pkgutil.iter_modules(pkg.__path__):
        if module.name in {"base", "registry"}:
            continue
        importlib.import_module(f"{pkg.__name__}.{module.name}")


_autodiscover_adapters()


def registered_payment_providers() -> list[dict[str, str]]:
    """所有已注册渠道的 code + 展示名(供管理端/中间页配置渠道时选择)。"""
    return [
        {"code": adapter.code, "name": adapter.display_name}
        for adapter in _PROVIDER_REGISTRY.values()
    ]


def is_registered_provider(provider_code: str) -> bool:
    """provider code 是否为已注册渠道。注册表即"动态枚举",用作合法值单一事实源。"""
    return str(provider_code or "").strip().lower() in _PROVIDER_REGISTRY


def build_payment_provider_adapter(config: dict[str, Any]) -> PaymentProviderAdapter:
    code = str((config or {}).get("provider_code") or "").strip().lower()
    adapter_cls = _PROVIDER_REGISTRY.get(code)
    if not adapter_cls:
        raise HTTPException(status_code=503, detail=f"支付 provider 未接入: {code or 'unknown'}")
    return adapter_cls(config)


def provider_capability(provider_code: str, capability: str, default: Any = False) -> Any:
    """读已注册 adapter 类的能力声明(类属性,无需实例化/配置)。

    供业务层把 `provider == "creem"` / `provider != "zpay"` 之类字面量判定,改为按能力分流
    (如 supports_recurring/supports_discount_codes/order_mode)。未注册的 provider 返回 default。
    """
    cls = _PROVIDER_REGISTRY.get(str(provider_code or "").strip().lower())
    return getattr(cls, capability, default) if cls else default
