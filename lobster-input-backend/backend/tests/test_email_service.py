import asyncio
import json
import ssl
from types import SimpleNamespace
from unittest.mock import AsyncMock

import aiohttp
import pytest

from app.core.config import settings
from app.core.exceptions import AppException
from app.services.account import email_service
from app.services.account.email_service import EmailService


class FakeResponse:
    def __init__(self, status=200, body=None):
        self.status = status
        self.body = {"code": 200} if body is None else body

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    async def json(self, **kwargs):
        if isinstance(self.body, Exception):
            raise self.body
        return self.body


class FakeSession:
    def __init__(self, outcomes):
        self.outcomes = iter(outcomes)
        self.calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        pass

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        outcome = next(self.outcomes)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome


@pytest.fixture
def setup_sender(monkeypatch):
    monkeypatch.setattr(settings, "aoksend_api_key", "test-key")
    monkeypatch.setattr(settings, "aoksend_template_id", "test-template")
    monkeypatch.setattr(settings, "aoksend_api_url", "http://192.0.2.16/index/api/send_email")
    monkeypatch.setattr(email_service.asyncio, "sleep", AsyncMock())

    def setup(outcomes):
        session = FakeSession(outcomes)
        kwargs = {}

        def factory(**options):
            kwargs.update(options)
            return session

        monkeypatch.setattr(email_service.aiohttp, "ClientSession", factory)
        return session, kwargs

    return setup


def send():
    asyncio.run(EmailService().send_verification_code("test@example.com", "654321"))


def test_uses_configured_url_timeout_and_disables_redirects(setup_sender):
    session, kwargs = setup_sender([FakeResponse()])
    send()
    url, options = session.calls[0]
    assert url == settings.aoksend_api_url
    assert options["allow_redirects"] is False
    assert options["data"]["app_key"] == "test-key"
    assert json.loads(options["data"]["data"]) == {"code": "654321"}
    assert kwargs["timeout"].total == 15
    assert kwargs["timeout"].connect == 5
    assert kwargs["timeout"].sock_read == 10


def connection_error():
    key = SimpleNamespace(host="apiv2.aoksend.com", port=443, ssl=True)
    return aiohttp.ClientConnectorError(key, ConnectionResetError(104, "Connection reset"))


def test_retries_only_connection_failure(setup_sender):
    session, _ = setup_sender([connection_error(), FakeResponse()])
    send()
    assert len(session.calls) == 2


def test_connection_failure_stops_after_two_attempts(setup_sender):
    session, _ = setup_sender([connection_error(), connection_error()])
    with pytest.raises(AppException) as caught:
        send()
    assert caught.value.status_code == 503
    assert len(session.calls) == 2


@pytest.mark.parametrize("outcome", [
    FakeResponse(status=502),
    FakeResponse(status=302),
    FakeResponse(body={"code": 40007, "message": "private-provider-detail"}),
    FakeResponse(body=[]),
    FakeResponse(body=ValueError("invalid json")),
    asyncio.TimeoutError(),
    aiohttp.ServerDisconnectedError(),
    aiohttp.ClientConnectorCertificateError(
        SimpleNamespace(host="apiv2.aoksend.com", port=443, ssl=True),
        ssl.CertificateError("invalid certificate"),
    ),
])
def test_failure_is_structured_and_not_replayed(setup_sender, outcome, caplog):
    session, _ = setup_sender([outcome])
    with pytest.raises(AppException) as caught:
        send()
    assert caught.value.status_code == 503
    assert caught.value.detail["code"] == "EMAIL_SERVICE_UNAVAILABLE"
    assert len(session.calls) == 1
    assert "test-key" not in caplog.text
    assert "654321" not in caplog.text
    assert "private-provider-detail" not in caplog.text


def test_missing_credentials_do_not_send(setup_sender, monkeypatch):
    session, _ = setup_sender([])
    monkeypatch.setattr(settings, "aoksend_api_key", "")
    with pytest.raises(AppException):
        send()
    assert session.calls == []
