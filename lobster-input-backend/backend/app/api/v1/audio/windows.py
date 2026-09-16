"""
Windows 端音频处理接口。
POST /api/v1/audio/windows/process — Windows 专属语音识别接口。

平台标识：
  client_platform 固定为 "windows"（接口层强制注入）
  流程选择：由 PipelineManager 根据 X-Accept-Language Header 自动路由

功能说明：
  - transcribe / rewrite / agent 架构骨架已就绪
  - 支持 Windows 选区与结构化剪贴板上下文
  - OpenClaw 功能在 Windows 端按 Mac 端链路执行
"""
from typing import Optional

from fastapi import APIRouter, File, Form, HTTPException, UploadFile, status

from app.api.streaming import audio_process_stream
from app.decorators.client_context import ClientRequestContext, with_client_context
from app.models.schemas import AudioTranscribeResponse

router = APIRouter(prefix="/audio/windows", tags=["Audio - Windows"])

_WINDOWS_PLATFORM = "windows"
_ALLOWED_OPERATIONS = {"transcribe", "rewrite", "agent"}


@router.post(
    "/process",
    response_model=AudioTranscribeResponse,
    summary="Windows 端：上传音频文件并返回处理结果",
    description="""
Windows 专属语音识别接口，提示词由 PipelineManager 根据语言自动路由。
支持文本和图片形式的结构化剪贴板上下文。

支持的 operation：
- transcribe — 语音转文字 + 纠偏整理
- rewrite    — 语音指令改写选中文本
- agent      — 多意图智能分发

X-Client-Platform 无需传递，接口层强制注入 windows。
X-Accept-Language 由客户端传递当前语言类型，用于流程选择和提示词路由。
""",
)
@with_client_context(client_platform=_WINDOWS_PLATFORM)
async def windows_process_audio(
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
            detail="Windows 端仅支持 transcribe、rewrite 和 agent",
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
    summary="Windows 端：上传音频文件并流式返回搜索结果",
    description="仅联网搜索节点会输出 delta；非搜索 agent 只返回 final 事件。",
)
@with_client_context(client_platform=_WINDOWS_PLATFORM)
async def windows_process_audio_stream(
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
