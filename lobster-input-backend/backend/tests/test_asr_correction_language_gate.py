import asyncio
from datetime import datetime, timezone

from app.models.schemas import HotWord
from app.services.audio.asr_correction import ASRCorrectionService
from app.services.audio.asr_correction.adapters.latin import LatinPhoneticAdapter
from app.services.audio.asr_correction.adapters.zh import ChinesePhoneticAdapter
from app.services.audio.asr_correction.text_utils import tokenize


class _FakeHotWordRepository:
    def __init__(self, words: list[str]):
        self.words = words

    async def list_by_user(self, user_email: str) -> list[HotWord]:
        if user_email != "user@example.com":
            return []
        return [
            HotWord(id=f"hw-{index}", word=word, created_at=datetime.now(timezone.utc))
            for index, word in enumerate(self.words)
        ]


def _run_service(text: str, words: list[str], user_email: str | None = "user@example.com"):
    service = ASRCorrectionService()
    service._repo = _FakeHotWordRepository(words)
    return asyncio.run(service.run(text, language="zh", user_email=user_email))


def test_chinese_adapter_includes_technical_transliteration_aliases():
    keys = ChinesePhoneticAdapter().term_keys("Agent")
    assert "agent" in keys
    assert "ai zheng te" in keys
    assert "ei zhen te" in keys


def test_tokenizer_keeps_chinese_phonetic_error_and_english_terms():
    tokens = tokenize("帮我查一下癌症特最新技术文档，并对比 Qwen3-ASR")
    assert "癌症特" in tokens
    assert "Qwen3-ASR" in tokens


def test_user_dictionary_surfaces_agent_for_phonetic_asr_error():
    result = _run_service("帮我查一下癌症特最新技术文档", ["Agent", "Cursor"])
    assert result.has_hints
    assert "癌症特 -> Agent" in result.hints_text


def test_correct_agent_text_does_not_emit_self_replacement_hint():
    result = _run_service("帮我查一下 Agent 最新技术文档", ["Agent"])
    assert not result.has_hints


def test_missing_user_dictionary_does_not_emit_public_correction():
    result = _run_service("帮我查一下癌症特最新技术文档", [], user_email="user@example.com")
    assert not result.has_hints


def test_other_user_dictionary_is_not_used():
    result = _run_service("帮我查一下癌症特最新技术文档", ["Agent"], user_email="other@example.com")
    assert not result.has_hints


def test_latin_adapter_surfaces_git_only_with_technical_context():
    result = _run_service("run get status", ["Git"])
    assert result.has_hints
    assert "get -> Git" in result.hints_text


def test_latin_adapter_does_not_rewrite_common_get_without_context():
    result = _run_service("please get me the latest report", ["Git"])
    assert not result.has_hints


def test_latin_phrase_alias_prefers_github_phrase():
    result = _run_service("clone from get hub", ["Git", "GitHub"])
    assert result.has_hints
    assert "get hub -> GitHub" in result.hints_text
    assert "get -> Git" not in result.hints_text


def test_non_latin_languages_are_conservative_without_matching_dictionary():
    result = _run_service("회의 내용을 정리해줘", ["Git", "Agent"])
    assert not result.has_hints


def test_latin_adapter_phonetic_keys_cover_get_git():
    adapter = LatinPhoneticAdapter()
    assert adapter.term_keys("Git") & adapter.token_keys("get")
