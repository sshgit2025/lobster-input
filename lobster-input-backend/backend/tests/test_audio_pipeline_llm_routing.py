import asyncio

from app.services.pipeline.v1.audio_pipeline import AudioProcessPipeline, PipelineContext


class _FakeAudioService:
    def __init__(self, text: str, language: str):
        self._text = text
        self._language = language

    async def transcribe(self, *args, **kwargs):
        return self._text, self._language, None


class _CorrectionGuardPipeline(AudioProcessPipeline):
    """断言纠偏未被调用——仅在极速模式下应成立。"""

    def __init__(self, text: str, language: str):
        self.audio_service = _FakeAudioService(text, language)
        self.correction_called = False

    async def _apply_asr_correction(self, *args, **kwargs):
        self.correction_called = True
        raise AssertionError("fast_mode transcribe must not enter ASR correction")


class _CorrectionRecordingPipeline(AudioProcessPipeline):
    def __init__(self, text: str, language: str):
        self.audio_service = _FakeAudioService(text, language)
        self.correction_called = False

    async def _apply_asr_correction(self, text, *args, **kwargs):
        self.correction_called = True
        return text

    async def _check_next_node_credits(self, *args, **kwargs):
        return None


# --- should_invoke_llm：transcribe 非极速模式一律走 LLM（按字符长度的短句直返已移除） ---

def test_transcribe_short_chinese_now_invokes_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(operation="transcribe", transcript="好的。", transcript_language="zh")
    assert pipeline.should_invoke_llm(ctx)


def test_transcribe_short_english_now_invokes_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(
        operation="transcribe",
        transcript="please check the login bug",
        transcript_language="en",
    )
    assert pipeline.should_invoke_llm(ctx)


def test_transcribe_email_sentence_invokes_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(
        operation="transcribe",
        transcript="呃，我的邮箱是幺七幺二八九九三艾特qq点com。",
        transcript_language="zh",
    )
    assert pipeline.should_invoke_llm(ctx)


def test_transcribe_long_text_invokes_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(
        operation="transcribe",
        transcript="这个问题需要再确认一下。",
        transcript_language="zh",
    )
    assert pipeline.should_invoke_llm(ctx)


def test_transcribe_empty_text_skips_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(operation="transcribe", transcript="", transcript_language="zh")
    assert not pipeline.should_invoke_llm(ctx)


# --- 极速模式（fast_mode）：保留，仍跳过 LLM 与纠偏 ---

def test_transcribe_fast_mode_skips_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(
        operation="transcribe", transcript="好的。",
        transcript_language="zh", fast_mode=True,
    )
    assert not pipeline.should_invoke_llm(ctx)


def test_transcribe_fast_mode_skips_correction():
    pipeline = _CorrectionGuardPipeline(text="好的。", language="zh")
    ctx = PipelineContext(operation="transcribe", fast_mode=True)

    result = asyncio.run(pipeline.transcribe("dummy.wav", operation="transcribe", ctx=ctx))

    assert result == "好的。"
    assert ctx.transcript_language == "zh"
    assert not pipeline.correction_called


# --- 激活人设：强制走 LLM ---

def test_persona_active_forces_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(
        operation="transcribe", transcript="好的。",
        transcript_language="zh", persona_active=True,
    )
    assert pipeline.should_invoke_llm(ctx)


# --- 纠偏：短句也进入纠偏流程（不再因字符短而跳过） ---

def test_short_transcribe_now_enters_correction():
    pipeline = _CorrectionRecordingPipeline(text="好的。", language="zh")
    ctx = PipelineContext(operation="transcribe")

    result = asyncio.run(pipeline.transcribe("dummy.wav", operation="transcribe", ctx=ctx))

    assert result == "好的。"
    assert ctx.transcript_language == "zh"
    assert pipeline.correction_called


def test_long_transcribe_enters_correction():
    text = "我二十八岁了需要确认一下"
    pipeline = _CorrectionRecordingPipeline(text=text, language="zh")
    ctx = PipelineContext(operation="transcribe")

    result = asyncio.run(pipeline.transcribe("dummy.wav", operation="transcribe", ctx=ctx))

    assert result == text
    assert ctx.transcript_language == "zh"
    assert pipeline.correction_called


# --- 极短纯语气词兜底：直返原文，不走 LLM 与纠偏 ---

def test_pure_interjection_chinese_skips_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(operation="transcribe", transcript="嗯", transcript_language="zh")
    assert not pipeline.should_invoke_llm(ctx)


def test_pure_interjection_english_skips_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(operation="transcribe", transcript="um", transcript_language="en")
    assert not pipeline.should_invoke_llm(ctx)


def test_interjection_with_real_content_invokes_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(
        operation="transcribe",
        transcript="嗯那个我觉得这个方案还行",
        transcript_language="zh",
    )
    assert pipeline.should_invoke_llm(ctx)


def test_pure_interjection_persona_active_still_invokes_llm():
    pipeline = AudioProcessPipeline()
    ctx = PipelineContext(
        operation="transcribe", transcript="嗯",
        transcript_language="zh", persona_active=True,
    )
    assert pipeline.should_invoke_llm(ctx)


def test_pure_interjection_skips_correction():
    pipeline = _CorrectionGuardPipeline(text="嗯", language="zh")
    ctx = PipelineContext(operation="transcribe")

    result = asyncio.run(pipeline.transcribe("dummy.wav", operation="transcribe", ctx=ctx))

    assert result == "嗯"
    assert not pipeline.correction_called


# --- transcribe LLM 结果 sanitizer（去除误加的单个项目符号） ---

def test_transcribe_sanitizer_removes_single_accidental_bullet():
    pipeline = AudioProcessPipeline()

    result = pipeline._sanitize_transcribe_llm_result(
        "• 还有一些截图，以及一些智能的转写或提问结果，AI 的全部都有。"
    )

    assert result == "还有一些截图，以及一些智能的转写或提问结果，AI 的全部都有。"


def test_transcribe_sanitizer_keeps_real_multiline_list():
    pipeline = AudioProcessPipeline()
    text = "• 第一项\n• 第二项"

    assert pipeline._sanitize_transcribe_llm_result(text) == text
