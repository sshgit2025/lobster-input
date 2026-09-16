from __future__ import annotations

from app.services.audio.asr_correction.models import TokenHint

MAX_HINTS = 8


class HintsFormatter:
    @staticmethod
    def format(hints: list[TokenHint]) -> str:
        # 只输出语言无关的映射行；使用说明由 LLMService._correction_hints_context
        # 按 transcript 语言注入，避免给非中文用户混入中文指令。
        if not hints:
            return ""
        lines = []
        for hint in hints[:MAX_HINTS]:
            candidates = " / ".join(candidate.correct_text for candidate in hint.candidates)
            lines.append(f"- {hint.original} -> {candidates}")
        return "\n".join(lines)
