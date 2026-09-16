"""
文本处理工具 — 供 LLM 工具调用输出结果。

工具分工：
  submit_text       — transcribe / rewrite 无选中文本时使用，输出纠偏文本或生成内容
  rewrite_selected  — rewrite 有选中文本时专用
                      消息结构（每轮最新若干条 user msg，按序出现）：
                        [clipboard]\n{剪贴板内容}   ← 只读参考上下文（可选）
                        [selected text]\n{选中文本}  ← 改写操作对象
                        [voice text]\n{语音指令}     ← 操作指令
                      通过标记而非位置定位各角色，多轮历史下同样准确
"""
from langchain_core.tools import tool


@tool
def submit_text(text: str) -> str:
    """Submit the final text result. Use this for cleaned dictation, generated text, transformed clipboard content, or any rewrite result when no selected text exists. Always call this tool for final output; do not answer directly."""
    return text


@tool
def rewrite_selected(original: str, rewritten: str) -> str:
    """Rewrite the selected text and submit the result.

    Message roles:
    - [clipboard] is optional read-only context.
    - [selected text] is the only text object to transform.
    - [voice text] is the spoken instruction.

    Arguments:
    - original: copy the full [selected text] exactly.
    - rewritten: the transformed version of original according to [voice text].

    Rules:
    1. Transform only original; never transform [voice text] itself.
    2. Support translation, polishing, shortening, expansion, formatting, style change, grammar fixes, and summarization.
    3. For translation, use the requested target language; if no target language is given, keep the original language.
    4. Preserve meaning, key terms, identifiers, code, URLs, emails, and mixed-language fragments unless the instruction asks to change them.
    5. If the instruction is unclear or unrelated to original, copy original into rewritten.
    """
    return rewritten
