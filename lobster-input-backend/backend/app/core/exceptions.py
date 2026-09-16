"""
统一业务异常定义。
所有业务异常继承 AppException，由 app/main.py 中的全局异常处理器
统一捕获并转为 JSON 响应: {"code": "...", "message": "..."}
"""
from fastapi import HTTPException, status


class AppException(HTTPException):
    """业务异常基类，携带结构化错误码和消息。"""
    def __init__(self, status_code: int, code: str, message: str):
        super().__init__(status_code=status_code, detail={"code": code, "message": message})


class UnauthorizedException(AppException):
    """401 未授权（JWT 无效或 API Key 不匹配）。"""
    def __init__(self, message: str = "Unauthorized"):
        super().__init__(status.HTTP_401_UNAUTHORIZED, "UNAUTHORIZED", message)


class InvalidAudioException(AppException):
    """400 音频文件无效（格式不支持或超出大小限制）。"""
    def __init__(self, message: str = "Invalid audio file"):
        super().__init__(status.HTTP_400_BAD_REQUEST, "INVALID_AUDIO", message)


class AudioDurationExceededException(AppException):
    """
    400 音频时长超出限制。
    携带 config_update 让客户端同步更新本地录音上限配置。
    此类错误属于前置校验拦截，客户端不应提供重试。
    """
    def __init__(self, message: str, config_update: dict | None = None):
        super().__init__(status.HTTP_400_BAD_REQUEST, "DURATION_EXCEEDED", message)
        self.config_update = config_update


class UnsupportedOperationException(AppException):
    """400 不支持的操作类型（无对应提示词模板）。"""
    def __init__(self, operation: str):
        super().__init__(
            status.HTTP_400_BAD_REQUEST,
            "UNSUPPORTED_OPERATION",
            f"Unsupported operation type: {operation}",
        )


class ProviderException(AppException):
    """502 上游提供商错误（LLM / Whisper 调用失败）。"""
    def __init__(self, message: str):
        super().__init__(status.HTTP_502_BAD_GATEWAY, "PROVIDER_ERROR", message)


class InvalidVerificationCodeException(AppException):
    """400 验证码无效或已过期。"""
    def __init__(self):
        super().__init__(status.HTTP_400_BAD_REQUEST, "INVALID_CODE", "Verification code is invalid or expired")


class PersonaNotFoundException(AppException):
    def __init__(self):
        super().__init__(status.HTTP_404_NOT_FOUND, "PERSONA_NOT_FOUND", "Persona not found")


class PersonaBuiltinReadonlyException(AppException):
    def __init__(self):
        super().__init__(status.HTTP_403_FORBIDDEN, "PERSONA_BUILTIN_READONLY", "Builtin persona is read-only")


class HotwordDuplicateException(AppException):
    def __init__(self):
        super().__init__(status.HTTP_409_CONFLICT, "HOTWORD_DUPLICATE", "Hotword already exists")


class HotwordNotFoundException(AppException):
    def __init__(self):
        super().__init__(status.HTTP_404_NOT_FOUND, "HOTWORD_NOT_FOUND", "Hotword not found")


class HotwordLimitReachedException(AppException):
    def __init__(self):
        super().__init__(status.HTTP_422_UNPROCESSABLE_ENTITY, "HOTWORD_LIMIT_REACHED", "Hotword limit reached")


class ShortcutNotFoundException(AppException):
    def __init__(self):
        super().__init__(status.HTTP_404_NOT_FOUND, "SHORTCUT_NOT_FOUND", "Shortcut not found")


class CreditsExhaustedException(AppException):
    """403 积分耗尽，需要充值或等待重置。"""
    def __init__(self, message: str = "Credits exhausted"):
        super().__init__(status.HTTP_403_FORBIDDEN, "CREDITS_EXHAUSTED", message)


class ServiceTemporarilyUnavailableException(AppException):
    """503 服务临时不可用，例如连续上游失败后的短暂保护。"""
    def __init__(self, message: str = "Service temporarily unavailable"):
        super().__init__(status.HTTP_503_SERVICE_UNAVAILABLE, "SERVICE_TEMPORARILY_UNAVAILABLE", message)


class UserBannedException(AppException):
    """403 用户已被禁用。"""
    def __init__(self):
        super().__init__(status.HTTP_403_FORBIDDEN, "USER_BANNED", "Account has been banned")


class SecurityBlockedException(AppException):
    """403 风控限制中。"""
    def __init__(self, message: str = "Request blocked for security reasons"):
        super().__init__(status.HTTP_403_FORBIDDEN, "SECURITY_BLOCKED", message)
