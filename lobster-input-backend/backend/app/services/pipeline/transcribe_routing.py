"""transcribe 路由兜底判断。

当整段识别结果只是无实义的语气/感叹词（如“嗯”“呃啊”“um uh”）时，直接返回原文，
跳过用户词典纠偏与 LLM，避免对无意义输入浪费一次大模型调用与积分。

刻意做得很窄，只认纯语气/感叹字且核心极短：
  - “那个/这个/就是/对吧”等多字填充词不纳入（语境中可能有义或需 LLM 清理）；
  - “好的”等有效确认更不纳入；
这些仍照常走 LLM。判定按语言区分阈值，避免误伤正常短句。
"""
from __future__ import annotations

import re

# 中文纯语气/感叹字（无实义）。不含“那个/这个/就是/对吧”等多字填充词。
_ZH_INTERJECTION_CHARS = set("嗯呃啊哦唉额噢欸诶哼呵呣呐")
# 英文口头语气词。
_EN_INTERJECTIONS = {"um", "uh", "uhh", "eh", "hmm", "hm", "ah", "oh", "er", "erm", "mm", "mmm"}

# 剥离标点与空白后判断核心内容。
_STRIP_RE = re.compile(r"[\s。．，,、.!！?？…~～·\-—_]+")
_EN_WORD_RE = re.compile(r"[a-z]+")

# 中文核心字符数上限（如“嗯嗯嗯”=3）。
_ZH_MAX_CORE = 3
# 英文语气词个数上限（如“uh um”=2）。
_EN_MAX_WORDS = 2


def _lang_key(language: str = "") -> str:
    return (language or "").lower().replace("_", "-").split("-", 1)[0]


def is_pure_interjection(text: str, language: str = "") -> bool:
    """文本是否为极短纯语气词（命中则可直返、跳过纠偏与 LLM）。"""
    if not text:
        return False
    core = _STRIP_RE.sub("", text)
    if not core:
        return False

    lang = _lang_key(language)
    if lang == "en" or (not lang and core.isascii()):
        words = _EN_WORD_RE.findall(text.lower())
        return 0 < len(words) <= _EN_MAX_WORDS and all(w in _EN_INTERJECTIONS for w in words)

    # 中文及其它语言：核心必须全部为中文语气字，且数量极少
    return len(core) <= _ZH_MAX_CORE and all(c in _ZH_INTERJECTION_CHARS for c in core)
