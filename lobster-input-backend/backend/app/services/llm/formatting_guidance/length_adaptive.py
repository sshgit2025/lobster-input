"""内置模板来源（无激活人设）的格式指导：按转写文本长短自适应。

本文件只服务系统默认提示词路径。调整长度阈值、分档规则或 short/medium/long
提示词文本都在这里改，不影响人设路径（persona_fixed.py）。
特别注意：short 档的「不要改写句意」等强约束是系统默认转写的既定行为,必须保持完整。
"""
from app.services.llm.formatting_guidance.base import (
    TranscribeFormattingGuidance,
    language_key,
)


class LengthAdaptiveGuidance(TranscribeFormattingGuidance):
    """按转写文本长短（short/medium/long）自适应选择格式指导。"""

    # 句末终止标点:用于识别"多句长文本"的信号
    _SENTENCE_END = set("。！？…；;!?.")
    # 句中停顿标点:用于识别短句是否其实是逗号/顿号堆叠的并列项
    _SENTENCE_MID = set("，,、")
    # 跨语言长短句门槛,统一以"等效词数"为度量,不再依赖具体语言
    _SHORT_WORD_LIMIT = 15      # < 15 词且为单句 -> 短句(轻清理、不分段)
    _LONG_WORD_LIMIT = 40       # >= 40 词 -> 长句(全语言统一标准)
    _LONG_END_PUNCT = 6         # 句末标点过多说明是多句长文本,兜底判长
    # 中/日等无空格表意文字:平均每词约 1.6 个字符,用于把字符数折算为词数
    _CJK_CHARS_PER_WORD = 1.6

    _LENGTH_HINTS_BY_LANG = {
        "zh": {
            "short": "本次输入是短句。纠偏后直接输出连贯清晰的短文本，去掉句末语气词和无信息铺垫，不要改写句意，不要分段；“不改写”不限制纠偏本身，ASR 纠偏和用户词典候选的判断规则在短句中照常适用——该采用的候选照常采用，不该采用的照常忽略。若只是词汇、标题、搜索词、命令片段或非完整句，可不加句末标点；若含为什么、能不能、是不是、有没有、怎么样等疑问结构，必须用问号收束。",
            "medium": "本次输入是中等长度文本。整理成真实用户愿意直接粘贴的自然文本：默认输出 1 个清晰自然段；若原文明显包含步骤、并列事项、优缺点、问题与处理建议、会议待办等 2-4 个独立点，可轻量换行或用短列表；不要为了格式而加标题，不要全篇机械编号。删除句首无信息铺垫和句末啊、呀、对吧等口语噪声；保留否定、条件、先后顺序、用户视角和真实疑问，含为什么、能不能、是不是、有没有等请求式疑问必须用问号收束。",
            "long": "本次输入是长文本。请整理成自然的结构化纯文本，而不是机械地全篇改成一个有序列表。只保留原文已有的论述主线、结论和模块关系，再按语义分成若干模块：当内容包含 3 个以上语义块时，优先使用简短小标题或引导句；连续事实、证据、步骤、方案可在所属模块内部编号，且每个模块从 1 重新计数；解释性段落保持段落，不强行编号。对原文中的组织性内容，如结构、方案、行动项、待办等，可单独成块并在块内编号；编号只服务于清晰表达，不改变原文主次关系。允许使用“背景/核心判断/依据/建议结构/注意事项/总结”等标题概括原文模块，但标题只能概括原文内容，不得新增原文没有的观点。删除噪声，保留全部实质信息、数字、因果、转折和不确定语气。",
        },
        "en": {
            "short": "This is a short English utterance. Clean lightly: remove only empty openers such as um, uh, I mean, you know when they add no meaning; keep real questions, hedges, and politeness. Fix capitalization and punctuation only when natural. Labels, search terms, file names, and command fragments may have no final period; genuine questions should end with ?.",
            "medium": "This is medium-length English dictation. Format it as paste-ready text: usually one natural paragraph for a message, note, or request. If the speaker clearly gives 2-4 steps, options, pros/cons, issue/action points, or meeting todos, use light line breaks or a short list. Do not add decorative headings or mechanically number everything. Remove empty fillers and trailing tag noise only when they do not affect meaning; preserve real questions, hedging, politeness, negation, order, technical terms, and speaker viewpoint.",
            "long": "This is long English dictation. Produce polished structured plain text based on the actual meaning, not on length alone. Preserve the original main thread, conclusion if present, and relationships between ideas. Use paragraphs for flowing explanation or narrative; use short headings only when the speaker has distinct semantic sections; use bullets or numbered lists only for real rules, steps, decisions, options, evidence, or todos. Do not force rambling or low-information speech into a list. Keep explanatory prose as paragraphs. Remove speech noise without adding claims, changing tone, or summarizing away meaning.",
        },
        "ru": {
            "short": "Это короткая русская реплика. Правь легко: убирай только пустые вводные вроде э, эм, ну, короче, типа, если они ничего не добавляют. Не удаляй вопросительные конструкции с ли, можно ли, надо ли, почему и не меняй ты/вы. Короткие названия, поисковые фразы и команды могут быть без точки; настоящий вопрос должен заканчиваться ?.",
            "medium": "Это русская диктовка средней длины. Оформи её так, как человек реально вставил бы в рабочий чат или заметку: обычно один ясный абзац. Если явно есть 2-4 шага, варианта, плюса/минуса, связка проблема/действие или todo по встрече, используй лёгкие переносы строк или короткий список. Не добавляй заголовки ради красоты и не нумеруй всё подряд. Убирай пустой речевой шум, но сохраняй вопрос, сомнение, вежливость, отрицание, порядок, ты/вы и позицию говорящего.",
            "long": "Это длинная русская диктовка. Оформи её по реальной смысловой структуре, а не по длине самой по себе. Сохрани исходную основную мысль, порядок, вывод и причинно-следственные связи. Связное объяснение или рассказ оставляй абзацами; короткие заголовки используй только при явно разных смысловых разделах; списки используй только для настоящих правил, шагов, решений, вариантов, аргументов или задач. Не превращай потоковую или малосодержательную речь в список. Убирай речевой шум, но не добавляй факты и не сжимай смысл.",
        },
        "ko": {
            "short": "짧은 한국어 발화입니다. 가볍게 정리하세요: 의미 없는 시작 filler(음, 어, 그, 저, 그러니까 등)만 줄이고 띄어쓰기, 조사, 어미, 문장부호를 자연스럽게 고칩니다. 질문 어미나 부탁 어미는 의미이므로 삭제하지 않습니다. 짧은 제목, 검색어, 라벨, 명령어 조각은 마침표 없이 둘 수 있고, 실제 질문은 ?로 끝냅니다.",
            "medium": "중간 길이의 한국어 받아쓰기입니다. 실제 사용자가 채팅이나 메모에 바로 붙여 넣을 수 있게 정리합니다: 보통은 자연스러운 한 문단으로 둡니다. 원문에 2-4개의 단계, 선택지, 장단점, 문제/조치, 회의 todo가 뚜렷하면 가벼운 줄바꿈이나 짧은 목록을 사용합니다. 보기 좋게 만들려고 제목을 붙이거나 전부 번호 매기지 않습니다. 의미 없는 filler는 줄이되 질문, 부탁, 존댓말/반말, 부정, 조건, 순서, 화자 시점은 보존합니다.",
            "long": "긴 한국어 받아쓰기입니다. 길이만 보고 목록으로 바꾸지 말고 실제 의미 구조에 맞게 정리합니다. 원문에 있는 핵심 흐름, 결론, 의미 관계를 보존합니다. 이어지는 설명이나 이야기 흐름은 문단으로 두고, 의미 단위가 분명히 나뉠 때만 짧은 소제목이나 안내 문장을 사용합니다. 실제 규칙, 단계, 결정, 선택지, 근거, 할 일이 있을 때만 해당 부분을 번호나 bullet로 정리합니다. 내용이 흐름식이거나 정보량이 낮은 말은 억지로 목록화하지 않습니다. 말소리는 줄이되 의미를 추가하거나 요약해서 없애지 않습니다.",
        },
        "default": {
            "short": "This is a short utterance. Clean lightly, preserve the language and script, and avoid over-formatting. Remove only obvious empty fillers when safe. Fragments, labels, search terms, and commands may have no final punctuation; genuine questions should remain questions.",
            "medium": "This is medium-length dictation. Format it as paste-ready text: usually one clear paragraph. If the speaker clearly gives 2-4 steps, options, pros/cons, issues with actions, or todos, use light line breaks or a short list. Do not add decorative headings or mechanically number everything. Preserve the original language, script, viewpoint, questions, politeness, negation, order, and technical terms.",
            "long": "This is long dictation. Produce structured plain text according to the actual meaning, not length alone. Preserve the original language, script, main thread, order, relationships between ideas, and any existing conclusion. Use paragraphs for flowing explanation or narrative; use short headings only when there are distinct semantic sections; use bullets or numbered lists only for real rules, steps, decisions, options, evidence, recommendations, or todos. Do not force rambling or low-information speech into a list. Remove speech noise without adding facts or losing meaning.",
        },
    }

    @staticmethod
    def _is_cjk_ideograph(char: str) -> bool:
        """判断是否为无空格连写的表意/音节文字(中文汉字、日文汉字与假名)。
        韩文 Hangul 以空格分词,不计入此处,按普通空格语言处理。"""
        code = ord(char)
        return (
            0x4E00 <= code <= 0x9FFF       # CJK 统一表意文字
            or 0x3400 <= code <= 0x4DBF    # CJK 扩展 A
            or 0xF900 <= code <= 0xFAFF    # CJK 兼容表意文字
            or 0x3040 <= code <= 0x30FF    # 日文平假名 + 片假名
        )

    @classmethod
    def _estimate_word_count(cls, text: str) -> float:
        """跨语言估算词数,使"词数"在所有语言之间可比。
        英/俄/韩等空格语言按空格分词;中/日等无空格表意文字按字符数折算成词。"""
        cjk_chars = 0
        buffer = []
        for char in text:
            if cls._is_cjk_ideograph(char):
                cjk_chars += 1
                buffer.append(" ")  # CJK 字符以空格占位,避免粘连相邻的拉丁词
            else:
                buffer.append(char)
        spaced_words = len("".join(buffer).split())
        return spaced_words + cjk_chars / cls._CJK_CHARS_PER_WORD

    @classmethod
    def classify_length(cls, text: str, language: str = "") -> str:
        """把转写文本分为 short / medium / long 三档,决定注入哪种格式化提示词。
        长句门槛对所有语言统一为 40 词,阈值不再依赖具体语言;language 仅保留
        签名兼容(选取提示词由调用方按语言完成)。"""
        del language  # 阈值与语言无关,显式声明不使用
        end_count = sum(1 for char in text if char in cls._SENTENCE_END)
        mid_count = sum(1 for char in text if char in cls._SENTENCE_MID)
        words = cls._estimate_word_count(text)

        if words < cls._SHORT_WORD_LIMIT and end_count <= 1 and mid_count <= 1:
            return "short"
        if words >= cls._LONG_WORD_LIMIT or end_count >= cls._LONG_END_PUNCT:
            return "long"
        return "medium"

    def hint(self, transcript: str, language: str = "") -> str:
        lang = language_key(language)
        hints = self._LENGTH_HINTS_BY_LANG.get(lang) or self._LENGTH_HINTS_BY_LANG["default"]
        return hints[self.classify_length(transcript, lang)]
