"""tools 包 — Agent 工具注册中心。"""
from app.tools.text_tools import submit_text, rewrite_selected

TRANSCRIBE_TOOLS = [submit_text]
REWRITE_TOOLS = [submit_text]              # 无 selected_text 时使用
REWRITE_SELECTED_TOOLS = [rewrite_selected]  # 有 selected_text 时使用
AGENT_TOOLS = [submit_text]  # 后续扩展更多工具
