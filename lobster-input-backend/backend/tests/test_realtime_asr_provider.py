import asyncio
import gzip
import json
from dataclasses import replace

from app.providers.realtime_asr.base import RealtimeASRConfig, get_realtime_asr_provider
from app.providers.realtime_asr.dashscope import DashScopeRealtimeASRProvider
from app.providers.realtime_asr.volcengine import VolcengineRealtimeASRProvider
from app.services.audio.realtime_asr import RealtimeASRService
from app.services.infra.api_pool_client import PoolKeyInfo


class FakeWebSocket:
    def __init__(self, messages=None):
        self.messages = list(messages or [])
        self.sent = []

    async def send(self, data):
        self.sent.append(data)

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self.messages:
            raise StopAsyncIteration
        return self.messages.pop(0)


def test_realtime_asr_provider_registry_routes_known_implementations():
    assert isinstance(get_realtime_asr_provider("dashscope_realtime"), DashScopeRealtimeASRProvider)
    assert isinstance(get_realtime_asr_provider("volcengine_realtime"), VolcengineRealtimeASRProvider)
    assert isinstance(get_realtime_asr_provider("doubao_realtime"), VolcengineRealtimeASRProvider)


def test_dashscope_realtime_endpoint_rewrites_rest_default_path():
    key = PoolKeyInfo(
        id="k1",
        api_key="sk-test",
        base_url="https://dashscope.aliyuncs.com/api/v1",
        model="qwen3-asr-flash-realtime",
    )
    endpoint = DashScopeRealtimeASRProvider._build_endpoint(key, {})
    assert endpoint.startswith("wss://dashscope.aliyuncs.com/api-ws/v1/realtime?")
    assert "model=qwen3-asr-flash-realtime" in endpoint


def test_dashscope_realtime_emits_full_session_revisions_as_partial_text():
    asyncio.run(_assert_dashscope_realtime_emits_full_session_revisions_as_partial_text())


async def _assert_dashscope_realtime_emits_full_session_revisions_as_partial_text():
    provider = DashScopeRealtimeASRProvider()
    provider._ws = FakeWebSocket([
        _json_message({
            "type": "conversation.item.input_audio_transcription.text",
            "item_id": "item_1",
            "language": "zh",
            "text": "",
            "stash": "今天",
        }),
        _json_message({
            "type": "conversation.item.input_audio_transcription.text",
            "item_id": "item_1",
            "language": "zh",
            "text": "今天",
            "stash": "天气不错，",
        }),
        _json_message({
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_1",
            "transcript": "今天天气不错，",
        }),
        _json_message({
            "type": "conversation.item.input_audio_transcription.text",
            "item_id": "item_2",
            "language": "zh",
            "text": "",
            "stash": "阳光",
        }),
        _json_message({
            "type": "conversation.item.input_audio_transcription.text",
            "item_id": "item_2",
            "language": "zh",
            "text": "阳光",
            "stash": "明媚。",
        }),
        _json_message({"type": "session.finished"}),
    ])

    events = []
    async for event in provider.events():
        events.append(event)

    assert [event.type for event in events] == ["partial", "partial", "partial", "partial", "partial", "finished"]
    assert [event.text for event in events] == [
        "今天",
        "今天天气不错，",
        "今天天气不错，",
        "今天天气不错，阳光",
        "今天天气不错，阳光明媚。",
        "今天天气不错，阳光明媚。",
    ]
    assert events[1].confirmed_text == "今天"
    assert events[1].stash == "天气不错，"


def test_volcengine_realtime_endpoint_rewrites_flash_path():
    key = PoolKeyInfo(
        id="k1",
        api_key="sk-test",
        base_url="https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash",
        model="volc.seedasr.sauc.duration",
    )
    endpoint = VolcengineRealtimeASRProvider._build_endpoint(key, {})
    assert endpoint == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"


def test_volcengine_sync_endpoint_uses_nostream():
    key = PoolKeyInfo(
        id="k1",
        api_key="sk-test",
        base_url="wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async",
        model="volc.seedasr.sauc.duration",
    )
    cfg = RealtimeASRConfig(platform="sync", user_email="u@example.com", language="ko")

    endpoint = VolcengineRealtimeASRProvider._build_endpoint(key, {}, cfg)

    assert endpoint == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream"


def test_volcengine_realtime_endpoint_keeps_async_for_specified_language_by_default():
    key = PoolKeyInfo(
        id="k1",
        api_key="sk-test",
        base_url="wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async",
        model="volc.seedasr.sauc.duration",
    )
    cfg = RealtimeASRConfig(platform="windows", user_email="u@example.com", language="ko")

    endpoint = VolcengineRealtimeASRProvider._build_endpoint(key, {}, cfg)

    assert endpoint == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"


def test_volcengine_realtime_endpoint_keeps_async_for_chinese_ui_language():
    key = PoolKeyInfo(
        id="k1",
        api_key="sk-test",
        base_url="wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async",
        model="volc.seedasr.sauc.duration",
    )
    cfg = RealtimeASRConfig(platform="windows", user_email="u@example.com", language="")

    endpoint = VolcengineRealtimeASRProvider._build_endpoint(key, {}, cfg)

    assert endpoint == "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"


def test_volcengine_realtime_parses_gzip_json_response():
    payload = {
        "result": {
            "text": "hello",
            "utterances": [{"definite": True}],
            "additions": {"language": "en-US"},
        }
    }
    body = gzip.compress(json.dumps(payload).encode("utf-8"))
    packet = bytes([0x11, 0x90, 0x11, 0x00]) + len(body).to_bytes(4, "big") + body
    parsed = VolcengineRealtimeASRProvider._parse_response(packet)
    assert parsed["type"] == "response"
    assert parsed["final"] is False
    assert parsed["payload"]["result"]["text"] == "hello"


def test_volcengine_realtime_headers_use_x_api_key():
    key = PoolKeyInfo(
        id="k1",
        api_key="x-api-key",
        base_url="wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async",
        model="volc.seedasr.sauc.duration",
    )

    headers = VolcengineRealtimeASRProvider._build_headers(key, {}, "volc.seedasr.sauc.duration")

    assert headers["X-Api-Key"] == "x-api-key"
    assert "X-Api-App-Key" not in headers
    assert "X-Api-Access-Key" not in headers


def test_volcengine_realtime_request_clamps_client_vad_to_provider_default():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(
        platform="macos",
        user_email="u@example.com",
        language="zh",
        sample_rate=16000,
        use_vad=True,
        silence_duration_ms=400,
    )

    request = provider._request_config()

    assert request["end_window_size"] == 800
    assert request["force_to_speech_time"] == 1000
    assert request["enable_lid"] is True
    assert "language" not in request


def test_realtime_bridge_keeps_client_ui_language_only_for_non_zh_volcengine():
    cfg = RealtimeASRConfig(platform="macos", user_email="u@example.com", language="zh-Hans")
    language = RealtimeASRService._provider_audio_language(cfg, "volcengine_realtime", {})
    provider_cfg = replace(cfg, language=language)

    assert cfg.language == "zh-Hans"
    assert provider_cfg.language == ""

    cfg = RealtimeASRConfig(platform="macos", user_email="u@example.com", language="ja")
    language = RealtimeASRService._provider_audio_language(cfg, "volcengine_realtime", {})
    provider_cfg = replace(cfg, language=language)

    assert provider_cfg.language == "ja"


def test_realtime_bridge_can_force_volcengine_language_auto_mode():
    cfg = RealtimeASRConfig(platform="macos", user_email="u@example.com", language="ko")
    language = RealtimeASRService._provider_audio_language(
        cfg, "volcengine_realtime", {"asr_language_mode": "auto"}
    )

    assert language == ""


def test_volcengine_realtime_places_provider_language_in_audio_config():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(
        platform="macos",
        user_email="u@example.com",
        language="ko",
        sample_rate=16000,
    )

    audio = provider._audio_config()
    request = provider._request_config()

    assert audio["language"] == "ko-KR"
    assert "language" not in request
    assert request["enable_nonstream"] is True


def test_volcengine_realtime_request_respects_longer_provider_vad_window():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(
        platform="macos",
        user_email="u@example.com",
        sample_rate=16000,
        use_vad=True,
        silence_duration_ms=3000,
    )

    request = provider._request_config()

    assert request["end_window_size"] == 3000


def test_volcengine_realtime_request_sanitizes_override_vad_window():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(platform="macos", user_email="u@example.com", sample_rate=16000)
    provider._provider_config = {"request": {"end_window_size": 200}}

    request = provider._request_config()

    assert request["end_window_size"] == 800


def test_volcengine_realtime_context_prefers_session_hotwords_and_limit():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(platform="macos", user_email="u@example.com", sample_rate=16000)
    provider._session_hotwords = ("新词", "专有名词", "老词")
    provider._provider_config = {"hotword_limit": 3}

    request = provider._request_config()
    context = request["corpus"]["context"]

    assert "context" not in request
    assert json.loads(context) == {
        "hotwords": [
            {"word": "新词"},
            {"word": "专有名词"},
            {"word": "老词"},
        ]
    }


def test_volcengine_realtime_hotword_limit_is_protocol_specific():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(platform="windows", user_email="u@example.com", sample_rate=16000)
    assert provider._hotword_limit() == 100
    provider._provider_config = {"hotword_limit": 5000}
    assert provider._hotword_limit() == 100

    sync_provider = VolcengineRealtimeASRProvider()
    sync_provider._cfg = RealtimeASRConfig(platform="sync", user_email="u@example.com", sample_rate=16000)
    assert sync_provider._hotword_limit() == 5000


def test_volcengine_realtime_corpus_merges_official_tables_and_context():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(
        platform="macos",
        user_email="u@example.com",
        sample_rate=16000,
        corpus_text="露姐",
    )
    provider._provider_config = {
        "boosting_table_id": "boost-id",
        "correct_table_name": "correct-name",
    }

    corpus = provider._request_config()["corpus"]

    assert corpus["boosting_table_id"] == "boost-id"
    assert corpus["correct_table_name"] == "correct-name"
    assert json.loads(corpus["context"]) == {"hotwords": [{"word": "露姐"}]}
    assert provider._corpus_table_keys({"corpus": corpus}) == ["boosting_table_id", "correct_table_name"]


def test_volcengine_realtime_coalesces_pcm_chunks_to_around_200ms():
    asyncio.run(_assert_volcengine_realtime_coalesces_pcm_chunks_to_around_200ms())


async def _assert_volcengine_realtime_coalesces_pcm_chunks_to_around_200ms():
    provider = VolcengineRealtimeASRProvider()
    fake_ws = FakeWebSocket()
    provider._ws = fake_ws
    provider._cfg = RealtimeASRConfig(platform="macos", user_email="u@example.com", sample_rate=16000)

    await provider.send_audio(b"a" * 3200)
    assert fake_ws.sent == []

    await provider.send_audio(b"b" * 3200)
    assert len(fake_ws.sent) == 1
    assert _volc_audio_packet_payload(fake_ws.sent[0]) == (b"\x00" * 3840) + b"a" * 3200 + b"b" * 3200

    await provider.finish()
    assert len(fake_ws.sent) == 2
    assert fake_ws.sent[1][1] & 0x0F == 0x2


def test_volcengine_realtime_leading_silence_is_configurable():
    provider = VolcengineRealtimeASRProvider()
    provider._cfg = RealtimeASRConfig(platform="macos", user_email="u@example.com", sample_rate=16000)
    provider._provider_config = {"leading_silence_ms": 50}

    assert provider._leading_silence_bytes() == b"\x00" * 1600


def test_volcengine_realtime_emits_full_revisions_as_partial_text():
    asyncio.run(_assert_volcengine_realtime_emits_full_revisions_as_partial_text())


async def _assert_volcengine_realtime_emits_full_revisions_as_partial_text():
    provider = VolcengineRealtimeASRProvider()
    provider._ws = FakeWebSocket([
        _volc_response_packet({"result": {"text": "今天去", "utterances": [{"definite": True}]}}),
        _volc_response_packet({"result": {"text": "今天天气不错", "utterances": [{"definite": True}]}}),
    ])

    events = []
    async for event in provider.events():
        events.append(event)

    assert [event.type for event in events] == ["partial", "partial"]
    assert [event.text for event in events] == ["今天去", "今天天气不错"]


def _volc_audio_packet_payload(packet: bytes) -> bytes:
    size = int.from_bytes(packet[4:8], "big")
    return gzip.decompress(packet[8:8 + size])


def _volc_response_packet(payload: dict, *, final: bool = False) -> bytes:
    body = gzip.compress(json.dumps(payload).encode("utf-8"))
    return bytes([0x11, 0x90 | (0x2 if final else 0x0), 0x11, 0x00]) + len(body).to_bytes(4, "big") + body


def _json_message(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False)
