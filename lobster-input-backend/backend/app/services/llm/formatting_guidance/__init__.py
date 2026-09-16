"""
transcribe 系统提示词的「本轮格式指导」（[Current Turn Formatting Guidance]）选择策略。

业务规则：最终 system prompt = 语义规则（内置模板 或 激活人设） + 运行时段落（格式指导、参考上下文）。
格式指导注入 system 末尾（注意力最强的位置），因此它绝不能与语义规则冲突，
「给哪一段格式指导」由语义规则的来源（PromptSource）决定：

  - BUILTIN（内置模板）→ length_adaptive.LengthAdaptiveGuidance：按转写文本长短
    （short/medium/long）自适应选择格式指导，指导可以带结构化要求（分段/列表/标题），
    short 档含"不要改写句意"等完整强约束——系统默认行为。
  - PERSONA（激活人设）→ persona_fixed.PersonaFixedGuidance：人设已整体接管语义处理
    （翻译/改写风格等），固定注入一段只约束输出形态的轻量提示，避免格式指导压制人设语义。

两个策略各自独立成文件、各管各的文本与规则，调整任意一方不会影响另一方。
新增来源（例如未来的场景化模板）时：新建策略文件实现 TranscribeFormattingGuidance，
并在下方 _GUIDANCE_BY_SOURCE 注册表登记，不要在调用方写 if/else。
"""
from app.prompts.prompt_manager import PromptSource
from app.services.llm.formatting_guidance.base import (
    TranscribeFormattingGuidance,
    language_key,
)
from app.services.llm.formatting_guidance.length_adaptive import LengthAdaptiveGuidance
from app.services.llm.formatting_guidance.persona_fixed import PersonaFixedGuidance

__all__ = [
    "TranscribeFormattingGuidance",
    "LengthAdaptiveGuidance",
    "PersonaFixedGuidance",
    "guidance_for",
    "language_key",
]

_GUIDANCE_BY_SOURCE: dict[PromptSource, TranscribeFormattingGuidance] = {
    PromptSource.BUILTIN: LengthAdaptiveGuidance(),
    PromptSource.PERSONA: PersonaFixedGuidance(),
}


def guidance_for(source: PromptSource) -> TranscribeFormattingGuidance:
    """按语义规则来源取格式指导策略；未知来源兜底到内置行为。"""
    return _GUIDANCE_BY_SOURCE.get(source) or _GUIDANCE_BY_SOURCE[PromptSource.BUILTIN]
