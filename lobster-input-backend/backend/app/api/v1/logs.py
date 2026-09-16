"""
客户端日志上报接口。
  POST /api/v1/logs/report  — 客户端批量上报日志条目（需登录态）
"""
import json
from typing import Optional
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field, field_validator
from app.middleware.auth import verify_user
from app.repositories.client_log_repository import ClientLogRepository

router = APIRouter(prefix="/logs", tags=["Logs"])


class LogEntry(BaseModel):
    level: str = Field(..., min_length=1, max_length=16, description="日志级别: debug / info / warn / error")
    tag: str = Field(..., min_length=1, max_length=80, description="模块标签，如 Permission / OpenClaw / HotKey")
    message: str = Field(..., min_length=1, max_length=2000, description="日志内容")
    extra: Optional[dict] = Field(None, description="附加结构化数据")
    timestamp: Optional[str] = Field(None, max_length=64, description="客户端本地时间 ISO8601")

    @field_validator("level")
    @classmethod
    def validate_level(cls, v: str) -> str:
        value = v.strip().lower()
        if value not in {"debug", "info", "warn", "warning", "error", "fatal", "critical"}:
            raise ValueError("invalid log level")
        return value

    @field_validator("extra")
    @classmethod
    def validate_extra_size(cls, v: Optional[dict]) -> Optional[dict]:
        if v is not None and len(json.dumps(v, ensure_ascii=False, default=str)) > 65536:
            raise ValueError("extra too large")
        return v


class LogReportRequest(BaseModel):
    app_version: str = Field(..., max_length=64, description="客户端版本号，如 0.1.4")
    os_version: str = Field(..., max_length=128, description="macOS 版本，如 15.3.1")
    entries: list[LogEntry] = Field(..., max_length=50, description="日志条目列表，单次最多50条")


@router.post("/report", summary="客户端批量上报日志")
async def report_logs(
    body: LogReportRequest,
    payload: dict = Depends(verify_user),
):
    repo = ClientLogRepository()
    for entry in body.entries:
        await repo.insert({
            "user_email": payload.get("sub", "unknown"),
            "app_version": body.app_version,
            "os_version": body.os_version,
            "level": entry.level,
            "tag": entry.tag,
            "message": entry.message,
            "extra": entry.extra,
            "client_timestamp": entry.timestamp,
        })
    return {"accepted": len(body.entries)}
