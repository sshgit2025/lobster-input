from pydantic import BaseModel, Field
from typing import Optional, Literal
from datetime import datetime

AlertLevel = Literal["info", "warning", "critical"]
AlertStatus = Literal["pending", "resolved"]
AlertSource = Literal["backup", "system", "manual"]


class AlertCreateRequest(BaseModel):
    """外部（如备份脚本）调用写入告警的请求体。"""
    source: AlertSource = "backup"
    level: AlertLevel = "warning"
    title: str
    message: str
    extra: Optional[dict] = None


class AlertResolveRequest(BaseModel):
    note: Optional[str] = None


class AlertItem(BaseModel):
    id: str
    source: str
    level: str
    title: str
    message: str
    status: str
    extra: Optional[dict] = None
    created_at: datetime
    resolved_at: Optional[datetime] = None
    resolve_note: Optional[str] = None
