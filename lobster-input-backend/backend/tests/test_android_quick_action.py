from app.models.schemas import AndroidQuickAction
from app.api.v1 import v1_router
from app.prompts.prompt_manager import PromptManager
from app.services.account.android_quick_action_service import (
    _prompt_operation,
    detect_quick_action_language,
)


def test_android_quick_action_detects_language_from_processed_text():
    assert detect_quick_action_language("今天 meeting 的 agenda 先发你") == "zh"
    assert detect_quick_action_language("please make this shorter and clearer") == "en"
    assert detect_quick_action_language("пожалуйста сократи этот текст") == "ru"
    assert detect_quick_action_language("이 문장을 정리해 주세요") == "ko"
    assert detect_quick_action_language("12345 !!!") == "default"


def test_android_quick_action_prompt_operations_are_template_backed():
    format_prompt = PromptManager.get_template(
        _prompt_operation(AndroidQuickAction.format),
        client_platform="android",
        flow_name="standard",
        transcript_language="zh",
    )
    concise_prompt = PromptManager.get_template(
        _prompt_operation(AndroidQuickAction.concise),
        client_platform="android",
        flow_name="standard",
        transcript_language="zh",
    )
    bullets_prompt = PromptManager.get_template(
        _prompt_operation(AndroidQuickAction.bullets),
        client_platform="android",
        flow_name="standard",
        transcript_language="en",
    )

    assert "格式化" in format_prompt
    assert "精简" in concise_prompt
    assert format_prompt != concise_prompt
    assert "bullet" in bullets_prompt.lower()


def test_android_quick_action_prompts_have_language_specific_rules():
    zh_prompt = PromptManager.get_template(
        _prompt_operation(AndroidQuickAction.format),
        client_platform="android",
        flow_name="standard",
        transcript_language="zh",
    )
    ru_prompt = PromptManager.get_template(
        _prompt_operation(AndroidQuickAction.format),
        client_platform="android",
        flow_name="standard",
        transcript_language="ru",
    )
    ko_prompt = PromptManager.get_template(
        _prompt_operation(AndroidQuickAction.polish),
        client_platform="android",
        flow_name="standard",
        transcript_language="ko",
    )

    assert "中文标点" in zh_prompt
    assert "«ёлочки»" in ru_prompt
    assert "존댓말/반말" in ko_prompt
    assert zh_prompt != ru_prompt


def test_android_quick_action_default_prompts_exist_for_four_platforms():
    for platform in ("android", "ios", "macos", "windows"):
        for action in AndroidQuickAction:
            prompt = PromptManager.get_template(
                _prompt_operation(action),
                client_platform=platform,
                flow_name="standard",
                transcript_language="ja",
            )
            assert "<text>" in prompt
            assert "Return only" in prompt or "只输出" in prompt


def test_android_quick_action_is_text_route_not_audio_route():
    paths = {route.path for route in v1_router.routes}

    assert "/api/v1/text/android/quick-action" in paths
    assert "/api/v1/audio/android/quick-action" not in paths
    assert "/api/v1/audio/android/process" in paths
