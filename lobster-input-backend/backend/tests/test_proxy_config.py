import pytest

from app.services.infra.proxy_config import httpx_async_client_kwargs, parse_proxy_config, requests_proxies


def test_parse_proxy_config_disabled_when_missing():
    cfg = parse_proxy_config({})
    assert not cfg.is_enabled
    assert httpx_async_client_kwargs({}, timeout=1.0) == {"timeout": 1.0}
    assert requests_proxies({}) is None


def test_parse_proxy_config_http_url():
    raw = {"enabled": True, "proxy_url": "http://127.0.0.1:3128"}
    cfg = parse_proxy_config(raw)
    assert cfg.is_enabled
    assert cfg.proxy_url == "http://127.0.0.1:3128"
    assert httpx_async_client_kwargs(raw, timeout=1.0) == {
        "timeout": 1.0,
        "proxy": "http://127.0.0.1:3128",
        "trust_env": False,
    }
    assert requests_proxies(raw) == {
        "http": "http://127.0.0.1:3128",
        "https": "http://127.0.0.1:3128",
    }


def test_parse_proxy_config_adds_credentials():
    raw = {
        "enabled": True,
        "proxy_url": "http://proxy.example.com:3128",
        "username": "user@example.com",
        "password": "p/a:ss word",
    }
    cfg = parse_proxy_config(raw)
    assert cfg.proxy_url == "http://user%40example.com:p%2Fa%3Ass%20word@proxy.example.com:3128"
    assert httpx_async_client_kwargs(raw, timeout=1.0)["proxy"] == cfg.proxy_url


def test_parse_proxy_config_keeps_url_embedded_credentials():
    raw = {
        "enabled": True,
        "proxy_url": "http://url-user:url-pass@proxy.example.com:3128",
        "username": "ignored",
        "password": "ignored",
    }
    cfg = parse_proxy_config(raw)
    assert cfg.proxy_url == "http://url-user:url-pass@proxy.example.com:3128"


def test_parse_proxy_config_rejects_unsupported_scheme():
    with pytest.raises(ValueError):
        parse_proxy_config({"enabled": True, "proxy_url": "socks5://127.0.0.1:1080"})
