"""
iOS 端音频处理接口。
POST /api/v1/audio/ios/process — iOS 专属语音识别接口。

平台标识：
  client_platform 固定为 "ios"（接口层强制注入，无需客户端传 X-Client-Platform）
  流程选择：由 PipelineManager 根据 X-Accept-Language Header 自动路由

功能说明：
  - transcribe / rewrite 已按移动端纯语音输入法流程支持
  - iOS 输入法暂不支持 agent / OpenClaw / 搜索类桌面能力
"""
from typing import Optional

from fastapi import APIRouter, File, Form, HTTPException, UploadFile, status

from app.decorators.client_context import ClientRequestContext, with_client_context
from app.models.schemas import AudioTranscribeResponse

router = APIRouter(prefix="/audio/ios", tags=["Audio - iOS"])

_IOS_PLATFORM = "ios"
_ALLOWED_OPERATIONS = {"transcribe", "rewrite"}


@router.post(
    "/process",
    response_model=AudioTranscribeResponse,
    summary="iOS 端：上传音频文件并返回处理结果",
    description="""
iOS 专属语音识别接口，提示词由 PipelineManager 根据语言自动路由。

支持的 operation：
- transcribe — 语音转文字 + 纠偏整理
- rewrite    — 语音指令改写选中文本

X-Client-Platform 无需传递，接口层强制注入 ios。
X-Accept-Language 由客户端传递当前语言类型，用于流程选择和提示词路由。
""",
)
@with_client_context(client_platform=_IOS_PLATFORM)
async def ios_process_audio(
    client_context: ClientRequestContext,
    file: UploadFile = File(..., description="音频文件，支持 mp3/wav/m4a/ogg/flac/webm"),
    operation: str = Form(..., description="操作类型：transcribe | rewrite"),
    selected_text: Optional[str] = Form(default=None, max_length=12000, description="客户端当前选中的文本"),
    clipboard_history: Optional[str] = Form(default=None, max_length=20000, description="剪贴板最近内容，JSON 数组格式"),
    provider: Optional[str] = Form(default=None, description="模型提供商，留空使用默认值"),
    model: Optional[str] = Form(default=None, description="模型名称，留空使用默认值"),
    fast_mode: bool = Form(default=False, description="极速模式：transcribe 仅返回 ASR 结果，跳过用户词典纠偏和 LLM"),
) -> AudioTranscribeResponse:
    if operation not in _ALLOWED_OPERATIONS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="iOS 输入法仅支持 transcribe 和 rewrite",
        )

    pipeline = client_context.get_pipeline(operation)
    return await pipeline.execute(
        file=file,
        operation=operation,
        selected_text=selected_text,
        clipboard_history=clipboard_history,
        provider=provider,
        model=model,
        user_email=client_context.user_email,
        openclaw_status=None,
        client_platform=client_context.client_platform,
        client_ui_lang=client_context.client_ui_lang,
        flow_name=client_context.flow_name,
        fast_mode=fast_mode,
    )
