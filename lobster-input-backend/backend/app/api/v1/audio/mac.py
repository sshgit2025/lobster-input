"""
Mac 端音频处理接口。
POST /api/v1/audio/mac/process — Mac 专属语音识别接口。

平台标识：
  client_platform 固定为 "macos"（接口层强制注入，无需客户端传具体变体值）
  流程选择：由 PipelineManager 根据 X-Accept-Language Header 自动路由

功能完整：transcribe / rewrite / agent（含 OpenClaw 完整路由）
Mac 端流程统一，不区分客户端变体，保持稳定。

语言类型说明：
  X-Accept-Language — 客户端 UI 语言，用于流程选择（PipelineSelector）
  ASR 返回语言     — 由 ASR 服务识别，用于提示词目录路由（PromptManager）
"""
from typing import Optional

from fastapi import APIRouter, File, Form, HTTPException, UploadFile, status

from app.api.streaming import audio_process_stream
from app.decorators.client_context import ClientRequestContext, with_client_context
from app.models.schemas import AudioTranscribeResponse

router = APIRouter(prefix="/audio/mac", tags=["Audio - Mac"])

_MAC_PLATFORM = "macos"
_ALLOWED_OPERATIONS = {"transcribe", "rewrite", "agent"}


@router.post(
    "/process",
    response_model=AudioTranscribeResponse,
    summary="Mac 端：上传音频文件并返回处理结果",
    description="""
Mac 专属语音识别接口，提示词由 PipelineManager 根据语言自动路由。

支持的 operation：
- transcribe — 语音转文字 + 纠偏整理
- rewrite    — 语音指令改写选中文本
- agent      — 多意图智能分发（含 OpenClaw 会话功能）

X-Client-Platform 传 macos 即可，接口层统一注入，不区分变体。
X-Accept-Language 由客户端传递当前 UI 语言类型，用于流程选择（必填）。
""",
)
@with_client_context(client_platform=_MAC_PLATFORM)
async def mac_process_audio(
    client_context: ClientRequestContext,
    file: UploadFile = File(..., description="音频文件，支持 mp3/wav/m4a/ogg/flac/webm"),
    operation: str = Form(..., description="操作类型：transcribe | rewrite | agent"),
    selected_text: Optional[str] = Form(default=None, max_length=12000, description="客户端当前选中的文本"),
    clipboard_history: Optional[str] = Form(default=None, max_length=20000, description="剪贴板最近内容，JSON 数组格式"),
    clipboard_items: Optional[str] = Form(default=None, max_length=5000000, description="结构化剪贴板内容，支持文本和图片 Data URL"),
    provider: Optional[str] = Form(default=None, description="模型提供商，留空使用默认值"),
    model: Optional[str] = Form(default=None, description="模型名称，留空使用默认值"),
    openclaw_status: Optional[str] = Form(default=None, description="OpenClaw 状态: installed|service_down|not_installed"),
    openclaw_session_active: bool = Form(default=False, description="客户端本地 OpenClaw 模式是否已开启"),
    fast_mode: bool = Form(default=False, description="极速模式：transcribe 仅返回 ASR 结果，跳过用户词典纠偏和 LLM"),
) -> AudioTranscribeResponse:
    if operation not in _ALLOWED_OPERATIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Mac 端仅支持 transcribe、rewrite 和 agent",
        )

    pipeline = client_context.get_pipeline(operation)
    return await pipeline.execute(
        file=file,
        operation=operation,
        selected_text=selected_text,
        clipboard_history=clipboard_history,
        clipboard_items=clipboard_items,
        provider=provider,
        model=model,
        user_email=client_context.user_email,
        openclaw_status=openclaw_status,
        openclaw_session_active=openclaw_session_active,
        client_platform=client_context.client_platform,
        client_ui_lang=client_context.client_ui_lang,
        flow_name=client_context.flow_name,
        fast_mode=fast_mode,
    )


@router.post(
    "/process/stream",
    summary="Mac 端：上传音频文件并流式返回搜索结果",
    description="仅联网搜索节点会输出 delta；非搜索 agent 只返回 final 事件。",
)
@with_client_context(client_platform=_MAC_PLATFORM)
async def mac_process_audio_stream(
    client_context: ClientRequestContext,
    file: UploadFile = File(..., description="音频文件，支持 mp3/wav/m4a/ogg/flac/webm"),
    operation: str = Form(..., description="操作类型：agent"),
    selected_text: Optional[str] = Form(default=None, max_length=12000, description="客户端当前选中的文本"),
    clipboard_history: Optional[str] = Form(default=None, max_length=20000, description="剪贴板最近内容，JSON 数组格式"),
    clipboard_items: Optional[str] = Form(default=None, max_length=5000000, description="结构化剪贴板内容，支持文本和图片 Data URL"),
    provider: Optional[str] = Form(default=None, description="模型提供商，留空使用默认值"),
    model: Optional[str] = Form(default=None, description="模型名称，留空使用默认值"),
    openclaw_status: Optional[str] = Form(default=None, description="OpenClaw 状态: installed|service_down|not_installed"),
    openclaw_session_active: bool = Form(default=False, description="客户端本地 OpenClaw 模式是否已开启"),
    fast_mode: bool = Form(default=False, description="极速模式：agent 下忽略"),
):
    operation = (operation or "").strip().lower()
    if operation != "agent":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="流式接口仅用于 agent 操作",
        )

    pipeline = client_context.get_pipeline(operation)

    async def run(emit_event):
        async def emit_delta(text: str) -> None:
            if text:
                await emit_event("delta", {"text": text})
        return await pipeline.execute(
            file=file,
            operation=operation,
            selected_text=selected_text,
            clipboard_history=clipboard_history,
            clipboard_items=clipboard_items,
            provider=provider,
            model=model,
            user_email=client_context.user_email,
            openclaw_status=openclaw_status,
            openclaw_session_active=openclaw_session_active,
            client_platform=client_context.client_platform,
            client_ui_lang=client_context.client_ui_lang,
            flow_name=client_context.flow_name,
            fast_mode=fast_mode,
            stream_callback=emit_delta,
            stream_event_callback=emit_event,
        )

    return audio_process_stream(run)
