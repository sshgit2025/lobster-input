from pathlib import Path

from app.prompts.prompt_manager import PromptManager


BACKEND_ROOT = Path(__file__).resolve().parents[1]
REGRESSION_ROOT = BACKEND_ROOT / "tests" / "prompt_regression"


def test_international_transcribe_templates_load_by_language_and_platform():
    for language in ("en", "ru", "ko"):
        for platform in ("macos", "windows", "ios", "android"):
            template = PromptManager.get_template(
                "transcribe",
                client_platform=platform,
                flow_name="standard",
                transcript_language=language,
            )

            assert "{context_block}" in template
            assert "Output" in template or "Вывод" in template or "출력" in template


def test_international_rewrite_and_intent_templates_load_by_language_and_platform():
    for language in ("en", "ru", "ko"):
        for platform in ("macos", "windows", "ios", "android"):
            rewrite = PromptManager.get_template(
                "rewrite",
                client_platform=platform,
                flow_name="standard",
                transcript_language=language,
            )
            intent = PromptManager.get_template(
                "agent_intent",
                client_platform=platform,
                flow_name="standard",
                transcript_language=language,
            )

            assert "rewrite_selected" in rewrite
            assert "submit_text" in rewrite
            assert "TRANSCRIBE" in intent
            assert "REWRITE" in intent
            assert "SEARCH" in intent


def test_international_openclaw_templates_load_for_desktop_platforms():
    for language in ("en", "ru", "ko"):
        for platform in ("macos", "windows"):
            template = PromptManager.get_template(
                "openclaw_transcribe",
                client_platform=platform,
                flow_name="standard",
                transcript_language=language,
            )

            assert "COMMAND:" in template
            assert "TEXT:" in template


def test_default_templates_are_generic_multilingual_fallbacks():
    transcribe = PromptManager.get_template(
        "transcribe",
        client_platform="windows",
        flow_name="standard",
        transcript_language="ja",
    )
    rewrite = PromptManager.get_template(
        "rewrite",
        client_platform="windows",
        flow_name="standard",
        transcript_language="ja",
    )
    intent = PromptManager.get_template(
        "agent_intent",
        client_platform="windows",
        flow_name="standard",
        transcript_language="ja",
    )

    assert "multilingual" in transcribe.lower()
    assert "不是逐字替换表" not in transcribe
    assert "submit_text" in rewrite
    assert "TRANSCRIBE" in intent


def test_international_prompt_regression_cases_are_split_by_language():
    for language in ("en", "ru", "ko"):
        path = REGRESSION_ROOT / language / "transcribe_cases.jsonl"
        rows = path.read_text(encoding="utf-8").splitlines()

        assert len(rows) >= 650
