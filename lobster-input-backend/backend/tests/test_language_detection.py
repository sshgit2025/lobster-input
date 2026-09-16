"""detect_language：基于文本的提示词语言判定（lingua）。"""
from app.core.language_detection import detect_language


def test_chinese_short_and_interjection():
    assert detect_language("好的") == "zh"
    assert detect_language("嗯") == "zh"
    assert detect_language("这个需要尽快上线") == "zh"


def test_chinese_mixed_with_latin():
    # 中英混合（含 URL 口述）仍判中文——这是之前误判英文的核心场景
    assert detect_language("帮我打开三W点百度点com") == "zh"
    assert detect_language("帮我 review 一下这个 pull request") == "zh"


def test_english():
    assert detect_language("please check the login bug") == "en"


def test_korean():
    assert detect_language("안녕하세요 회의 결론 먼저 정리해 주세요") == "ko"


def test_russian():
    assert detect_language("проверь почему endpoint возвращает timeout") == "ru"


def test_russian_short_mixed_with_latin():
    # 短俄文夹英文技术词：脚本强信号确保判俄文，不被英文带偏
    assert detect_language("проверь endpoint") == "ru"


def test_undetectable_falls_back_to_provider_language():
    # 纯数字/符号无法判定 → 回退到 ASR provider 语言（限受支持集）
    assert detect_language("123", fallback="zh") == "zh"
    assert detect_language("", fallback="en") == "en"


def test_fallback_must_be_supported():
    # 不支持的兜底语言（无对应模板）一律归一为 ""（走 default）
    assert detect_language("123", fallback="ja") == ""
    assert detect_language("123", fallback="fr") == ""
    assert detect_language("123", fallback="") == ""


def test_client_ui_lang_does_not_leak_in():
    # 即便客户端 UI 是英文，中文文本也必须判中文（UI 语言不参与）
    assert detect_language("我说的是中文", fallback="en") == "zh"
