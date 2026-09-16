from app.providers.asr.dashscope import _extract_audio_language


def test_extracts_qwen_asr_annotation_language_from_dict_message():
    message = {
        "annotations": [
            {
                "type": "audio_info",
                "language": "ja",
                "emotion": "neutral",
            }
        ],
        "content": [{"text": "私は中国人です。"}],
    }

    assert _extract_audio_language(message) == "ja"


def test_extracts_no_language_when_annotation_missing():
    assert _extract_audio_language({"content": [{"text": "hello"}]}) == ""
