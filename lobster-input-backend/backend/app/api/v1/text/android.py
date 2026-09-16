"""
Android 端文本快捷处理接口。

POST /api/v1/text/android/quick-action — Android 输入法快捷键专用文本处理。

该模块只处理客户端传入的文本，不上传音频，不触发 ASR、用户词典纠偏、rewrite 工具链或 agent。
不同快捷键 action 通过本地 prompt 模板选择不同系统提示词。
"""
from fastapi import APIRouter

from app.decorators.client_context import ClientRequestContext, with_client_context
from app.models.schemas import AndroidQuickActionRequest, TextQuickActionResponse
from app.services.account.android_quick_action_service import AndroidQuickActionService

router = APIRouter(prefix="/text/android", tags=["Text - Android"])


@router.post(
    "/quick-action",
    response_model=TextQuickActionResponse,
    summary="Android 端：对已有文本执行一键快捷处理",
    description="""
Android 输入法专用文本快捷处理接口。

支持的 action：
- format  — 一键格式化：标点、分段、轻量结构
- polish  — 润色表达：更自然清楚
- concise — 精简压缩：删冗余保留重点
- bullets — 要点整理：清单/待办

该接口只处理客户端传入的 text，不上传音频，不支持 agent / OpenClaw。
""",
)
@with_client_context(client_platform="android")
async def android_quick_action(
    client_context: ClientRequestContext,
    body: AndroidQuickActionRequest,
) -> TextQuickActionResponse:
    return await AndroidQuickActionService().execute(
        body,
        user_email=client_context.user_email,
        client_ui_lang=client_context.client_ui_lang,
        flow_name=client_context.flow_name,
        client_platform=client_context.client_platform,
    )
