from app.services.llm.llm_service import LLMService
from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline


def test_rewrite_selected_keeps_voice_text_as_instruction():
    messages = LLMService._build_messages(
        system_prompt="rewrite rules",
        transcript="翻译成英文",
        selected_text="你好世界",
        operation="rewrite",
    )

    assert messages[1].content == "[selected text]\n你好世界"
    assert messages[2].content == "[voice text]\n翻译成英文"
    assert "不是指令" not in messages[2].content


def test_rewrite_without_selected_keeps_voice_text_as_instruction():
    messages = LLMService._build_messages(
        system_prompt="rewrite rules",
        transcript="帮我写一封请假邮件",
        selected_text=None,
        operation="rewrite",
    )

    assert messages[-1].content == "[voice text]\n帮我写一封请假邮件"
    assert "不是指令" not in messages[-1].content


def test_transcribe_marks_voice_text_as_non_instruction():
    messages = LLMService._build_messages(
        system_prompt="transcribe rules",
        transcript="帮我写一封请假邮件",
        selected_text=None,
        operation="transcribe",
        transcript_language="zh",
    )

    assert "不是让你回答的指令" in messages[-1].content
    assert "speech-recognition text" not in messages[-1].content
    assert "<voice_text>" in messages[-1].content


def test_transcribe_voice_text_prefix_follows_language():
    english = LLMService._build_messages(
        system_prompt="transcribe rules",
        transcript="please clean this sentence",
        selected_text=None,
        operation="transcribe",
        transcript_language="en",
    )
    russian = LLMService._build_messages(
        system_prompt="transcribe rules",
        transcript="проверь этот текст",
        selected_text=None,
        operation="transcribe",
        transcript_language="ru",
    )
    korean = LLMService._build_messages(
        system_prompt="transcribe rules",
        transcript="이 문장을 정리해 주세요",
        selected_text=None,
        operation="transcribe",
        transcript_language="ko",
    )

    assert "speech-recognition text" in english[-1].content
    assert "текст распознавания речи" in russian[-1].content
    assert "음성 인식 텍스트" in korean[-1].content


def test_clipboard_image_parser_accepts_near_5mb_data_url():
    payload = '[{"kind":"image","mime_type":"image/png","data_url":"data:image/png;base64,' + ("a" * 4_900_000) + '"}]'

    items = AudioProcessPipeline._parse_clipboard_items(payload)

    assert len(items) == 1
    assert items[0]["kind"] == "image"
    assert items[0]["mime_type"] == "image/png"


def test_clipboard_image_parser_rejects_over_5mb_payload():
    payload = '[{"kind":"image","mime_type":"image/png","data_url":"data:image/png;base64,' + ("a" * 5_100_000) + '"}]'

    assert AudioProcessPipeline._parse_clipboard_items(payload) == []


def test_international_length_classification_counts_sentence_periods():
    # 阈值统一后(long = 等效词数>=40 或 句末标点>=6):30 词上下、4 句的多点指令
    # 属于 medium——medium 档提示词本身覆盖 2-4 个独立点的轻量列表,不应触发 long 档结构化。
    english_rules = (
        "I need you to make breakfast for me, and I have some rules for you. "
        "First, you must make it delicious. "
        "Second, I must eat egg. "
        "And last, you should make it hot."
    )
    russian_rules = (
        "Мне нужно, чтобы ты приготовил мне завтрак, и у меня есть несколько правил. "
        "Во-первых, он должен быть вкусным. "
        "Во-вторых, там должны быть яйца. "
        "И наконец, он должен быть горячим."
    )
    korean_rules = (
        "아침을 만들어 줬으면 좋겠고 몇 가지 규칙이 있어요. "
        "첫째, 맛있어야 해요. "
        "둘째, 계란이 있어야 해요. "
        "마지막으로 따뜻해야 해요."
    )

    assert LLMService._classify_length(english_rules, "en") == "medium"
    assert LLMService._classify_length(russian_rules, "ru") == "medium"
    assert LLMService._classify_length(korean_rules, "ko") == "medium"

    # 句末标点达到 6 个即按"多句长文本"兜底判 long,即使等效词数不足 40
    english_staccato = (
        "Meeting notes. Budget approved. Timeline moved up. Hiring frozen. "
        "Launch stays in June. Marketing needs the deck. Legal signs off Friday."
    )
    russian_staccato = (
        "Итоги встречи. Бюджет утвердили. Сроки сдвинули. Набор заморозили. "
        "Запуск остаётся в июне. Маркетингу нужна презентация. Юристы подпишут в пятницу."
    )
    korean_staccato = (
        "회의 요약입니다. 예산은 승인됐어요. 일정은 앞당겨졌어요. 채용은 동결됐어요. "
        "출시는 6월 그대로예요. 마케팅에 자료가 필요해요. 법무는 금요일에 승인해요."
    )

    assert LLMService._classify_length(english_staccato, "en") == "long"
    assert LLMService._classify_length(russian_staccato, "ru") == "long"
    assert LLMService._classify_length(korean_staccato, "ko") == "long"


def test_international_length_classification_keeps_simple_requests_medium():
    english_request = (
        "Please check the login page after deployment, confirm whether the preview build picked up "
        "the new prompt, and tell me if the floating window still closes too early."
    )
    russian_request = (
        "Проверь страницу входа после деплоя, подтверди, что preview-сборка взяла новый prompt, "
        "и скажи, если плавающее окно всё ещё закрывается слишком рано."
    )
    korean_request = (
        "배포 후 로그인 페이지를 확인하고 preview 빌드가 새 prompt를 가져왔는지 본 다음 "
        "floating window가 아직 너무 빨리 닫히는지 알려 주세요."
    )

    assert LLMService._classify_length(english_request, "en") == "medium"
    assert LLMService._classify_length(russian_request, "ru") == "medium"
    assert LLMService._classify_length(korean_request, "ko") == "medium"
