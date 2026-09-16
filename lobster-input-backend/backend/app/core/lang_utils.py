"""
语言标识符工具函数。
供 PipelineSelector（流程选择）和 PromptManager（提示词路由）共用。
"""


def normalize_lang(lang: str) -> str:
    """规范化语言标识符：小写 + 取主标签（zh-CN → zh，en-US → en）。"""
    return (lang or "").lower().strip().split("-")[0].split("_")[0]
