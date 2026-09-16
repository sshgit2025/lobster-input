import wave

from app.providers.asr.volcengine import VolcengineASRProvider


def test_volcengine_nostream_resource_defaults_to_sauc_duration():
    assert VolcengineASRProvider._nostream_resource_id("volc.seedasr.auc", {}) == "volc.seedasr.sauc.duration"
    assert VolcengineASRProvider._nostream_resource_id("", {}) == "volc.seedasr.sauc.duration"
    assert VolcengineASRProvider._nostream_resource_id("volc.seedasr.sauc.duration", {}) == "volc.seedasr.sauc.duration"
    assert VolcengineASRProvider._nostream_resource_id(
        "volc.seedasr.auc", {"nostream_resource_id": "custom.resource"}
    ) == "custom.resource"


def test_volcengine_reads_enhanced_wav_as_pcm(tmp_path):
    audio = tmp_path / "sample.wav"
    with wave.open(str(audio), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(16000)
        wf.writeframes(b"\x01\x02" * 160)

    pcm, sample_rate = VolcengineASRProvider._read_pcm16_mono(audio)

    assert sample_rate == 16000
    assert pcm == b"\x01\x02" * 160


def test_volcengine_extracts_text_from_standard_result_shapes():
    assert VolcengineASRProvider._extract_text({"text": "你好"}) == "你好"
    assert VolcengineASRProvider._extract_text([{"text": "你"}, {"text": "好"}]) == "你好"


def test_volcengine_builds_hotword_context_from_prompt():
    context = VolcengineASRProvider._hotword_context("部署, 调试，数据库")

    assert '"hotwords"' in context
    assert '"部署"' in context
    assert '"调试"' in context
    assert '"数据库"' in context
