"""
告警管理 API。
  POST /api/v1/alerts          — 内部服务写入告警（用 X-Alert-Key 鉴权）
  GET  /api/v1/alerts          — 分页查询告警列表（需管理员登录）
  GET  /api/v1/alerts/latest-pending — 最新未处理告警（需管理员登录）
  POST /api/v1/alerts/{id}/resolve   — 标记告警为已处理（需管理员登录）
"""
import hmac
import logging
from typing import Optional
from fastapi import APIRouter, Depends, Query, Header, HTTPException, status
from app.api.v1.deps import get_current_admin, get_alert_repo
from app.models.alert import AlertCreateRequest, AlertResolveRequest
from app.core.config import settings

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1/alerts", tags=["alerts"])


def _verify_internal_key(x_alert_key: Optional[str] = Header(None)) -> None:
    """验证内部服务调用密钥(常量时间比较,防时序侧信道)。"""
    expected = settings.ALERT_INTERNAL_KEY
    if not x_alert_key or not expected or not hmac.compare_digest(x_alert_key, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="无效的内部密钥",
        )


@router.post("", status_code=201)
async def create_alert(
    body: AlertCreateRequest,
    _: None = Depends(_verify_internal_key),
    repo=Depends(get_alert_repo),
):
    """内部服务（如备份脚本）写入告警，使用 X-Alert-Key header 鉴权。"""
    alert_id = await repo.create(
        source=body.source,
        level=body.level,
        title=body.title,
        message=body.message,
        extra=body.extra,
    )
    logger.info("Alert created: id=%s level=%s title=%s", alert_id, body.level, body.title)
    return {"id": alert_id, "status": "created"}


@router.get("/latest-pending")
async def get_latest_pending(
    _: str = Depends(get_current_admin),
    repo=Depends(get_alert_repo),
):
    """获取最新一条未处理告警，用于登录后全局展示。"""
    alert = await repo.get_latest_pending()
    return {"alert": alert}


@router.get("")
async def list_alerts(
    alert_status: Optional[str] = Query(None, alias="status"),
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    _: str = Depends(get_current_admin),
    repo=Depends(get_alert_repo),
):
    """分页查询告警列表。"""
    total, items = await repo.list_alerts(
        status=alert_status,
        page=page,
        page_size=page_size,
    )
    return {"total": total, "page": page, "page_size": page_size, "items": items}


@router.post("/{alert_id}/resolve")
async def resolve_alert(
    alert_id: str,
    body: AlertResolveRequest,
    _: str = Depends(get_current_admin),
    repo=Depends(get_alert_repo),
):
    """将告警标记为已处理。"""
    ok = await repo.resolve(alert_id, body.note)
    if not ok:
        raise HTTPException(status_code=404, detail="告警不存在或已处理")
    return {"status": "resolved"}
