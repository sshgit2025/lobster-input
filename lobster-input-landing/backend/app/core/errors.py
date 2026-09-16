"""统一业务异常与错误响应格式。

返回结构 {"detail": {"code": "...", "message": "..."}}，前端据此展示文案并对
特定 code（如 UNAUTHENTICATED）做重新登录处理。
"""
from fastapi import Request
from fastapi.responses import JSONResponse


class AppError(Exception):
    def __init__(self, status_code: int, code: str, message: str):
        self.status_code = status_code
        self.code = code
        self.message = message
        super().__init__(message)


async def app_error_handler(_: Request, exc: AppError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": {"code": exc.code, "message": exc.message}},
    )
