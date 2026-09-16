"""Request helpers shared by auth, rate limiting, and audit logging."""
from __future__ import annotations

import ipaddress
from functools import lru_cache

from fastapi import Request

from app.core.config import settings


@lru_cache(maxsize=1)
def _trusted_proxy_networks() -> tuple[ipaddress._BaseNetwork, ...]:
    raw = getattr(settings, "trusted_proxy_cidrs", "") or ""
    networks = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        try:
            networks.append(ipaddress.ip_network(item, strict=False))
        except ValueError:
            continue
    return tuple(networks)


def _is_trusted_proxy(host: str | None) -> bool:
    if not host:
        return False
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return any(ip in network for network in _trusted_proxy_networks())


def client_ip(request: Request) -> str:
    """Return the client IP, trusting forwarded headers only from trusted proxies."""
    client = getattr(request, "client", None)
    peer = getattr(client, "host", "") if client else ""
    if _is_trusted_proxy(peer):
        forwarded = request.headers.get("X-Forwarded-For", "")
        if forwarded:
            first = forwarded.split(",")[0].strip()
            if first:
                return first
        real_ip = request.headers.get("X-Real-IP", "").strip()
        if real_ip:
            return real_ip
    return peer or "unknown"
