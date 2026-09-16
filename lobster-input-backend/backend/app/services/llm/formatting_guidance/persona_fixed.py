"""激活人设来源的格式指导：不做长度判断，固定注入轻量格式提示。

本文件只服务人设路径。调整人设场景的格式提示只改这里，不影响系统默认
提示词路径（length_adaptive.py）的长度自适应行为与 short/medium/long 文本。

人设提示词整体替换了静态转写规则，语义处理（翻译、风格改写等）以人设为准；
这里只约束输出形态，刻意不包含以下会与人设语义打架的表述：
  - "不要改写句意"（人设的任务可能恰恰是改写）——该约束仅属于系统默认路径的 short 档
  - 按长度分段/列表化/加标题的结构化要求（会把人设输出掰成整理文档的形态）
"""
from app.services.llm.formatting_guidance.base import (
    TranscribeFormattingGuidance,
    language_key,
)


class PersonaFixedGuidance(TranscribeFormattingGuidance):
    """激活人设时的固定轻量格式提示（与转写文本长短无关）。"""

    _PERSONA_HINTS_BY_LANG = {
        "zh": "本轮已激活自定义人设，文本按人设规则处理，本段只约束输出格式：直接输出处理后的连贯纯文本，不要机械分段、列表化或添加标题，不要输出任何解释或前后缀。标点自然完整；若人设未另行规定，疑问语气用问号收束。ASR 纠偏和用户词典候选的判断规则照常适用——该采用的候选照常采用，不该采用的照常忽略。",
        "en": "A custom persona is active for this turn; the text is processed by the persona rules, and this section only constrains output formatting: output the processed text directly as coherent plain text; do not add mechanical paragraphs, lists, or headings; never output explanations or wrappers. Use natural, complete punctuation; unless the persona says otherwise, end genuine questions with a question mark. ASR correction and user-dictionary candidate rules still apply as usual.",
        "ru": "В этом ходе активна пользовательская персона; текст обрабатывается по её правилам, а этот блок ограничивает только оформление: выведи обработанный текст сразу, связным обычным текстом; не добавляй механических абзацев, списков и заголовков; не выводи пояснений и обёрток. Пунктуация естественная и полная; если персона не требует иного, настоящий вопрос завершай знаком вопроса. Правила ASR-коррекции и кандидатов пользовательского словаря действуют как обычно.",
        "ko": "이번 턴에는 사용자 페르소나가 활성화되어 있으며 텍스트는 페르소나 규칙에 따라 처리합니다. 이 단락은 출력 서식만 제한합니다: 처리된 텍스트를 연결된 일반 텍스트로 바로 출력하고, 기계적인 단락 나누기·목록화·제목 추가를 하지 않으며, 어떤 설명이나 접두·접미 문구도 출력하지 않습니다. 문장부호는 자연스럽고 완전하게 정리하고, 페르소나가 달리 정하지 않았다면 실제 질문은 물음표로 끝냅니다. ASR 교정과 사용자 사전 후보 판단 규칙은 평소대로 적용합니다.",
        "default": "A custom persona is active for this turn; the text is processed by the persona rules, and this section only constrains output formatting: output the processed text directly as coherent plain text; do not add mechanical paragraphs, lists, or headings; never output explanations or wrappers. Use natural, complete punctuation; unless the persona says otherwise, end genuine questions with a question mark. ASR correction and user-dictionary candidate rules still apply as usual.",
    }

    def hint(self, transcript: str, language: str = "") -> str:
        lang = language_key(language)
        return self._PERSONA_HINTS_BY_LANG.get(lang) or self._PERSONA_HINTS_BY_LANG["default"]
