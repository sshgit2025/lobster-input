"""Per-key outbound proxy helpers.

The API pool stores a small proxy_config object on each key. Providers call
these helpers when constructing their HTTP clients so proxy behavior remains
local to the selected key and does not leak through process-wide environment
variables.
"""
from dataclasses import dataclass
from typing import Any, Mapping, Optional
from urllib.parse import quote, urlparse, urlunparse

import httpx


@dataclass(frozen=True)
class ProxyConfig:
    enabled: bool = False
    proxy_url: str = ""

    @property
    def is_enabled(self) -> bool:
        return self.enabled and bool(self.proxy_url)


def parse_proxy_config(raw: Optional[Mapping[str, Any]]) -> ProxyConfig:
    if not raw:
        return ProxyConfig()
    url = str(raw.get("proxy_url") or "").strip()
    enabled = bool(raw.get("enabled")) and bool(url)
    if not enabled:
        return ProxyConfig()
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("proxy_url must be an HTTP/HTTPS URL, for example http://host:port")
    username = str(raw.get("username") or "").strip()
    password = str(raw.get("password") or "")
    if username and not parsed.username:
        userinfo = quote(username, safe="")
        if password:
            userinfo += f":{quote(password, safe='')}"
        host = parsed.hostname or ""
        if ":" in host and not host.startswith("["):
            host = f"[{host}]"
        netloc = f"{userinfo}@{host}"
        if parsed.port is not None:
            netloc += f":{parsed.port}"
        url = urlunparse(parsed._replace(netloc=netloc))
    return ProxyConfig(enabled=True, proxy_url=url)


def httpx_async_client_kwargs(
    proxy_config: Optional[Mapping[str, Any]],
    **kwargs,
) -> dict:
    cfg = parse_proxy_config(proxy_config)
    if cfg.is_enabled:
        kwargs["proxy"] = cfg.proxy_url
        kwargs["trust_env"] = False
    return kwargs


def openai_async_http_client(proxy_config: Optional[Mapping[str, Any]], timeout: float = 600.0):
    cfg = parse_proxy_config(proxy_config)
    if not cfg.is_enabled:
        return None
    return httpx.AsyncClient(proxy=cfg.proxy_url, timeout=timeout, trust_env=False)


def requests_proxies(proxy_config: Optional[Mapping[str, Any]]) -> Optional[dict[str, str]]:
    cfg = parse_proxy_config(proxy_config)
    if not cfg.is_enabled:
        return None
    return {"http": cfg.proxy_url, "https": cfg.proxy_url}
