"""
请求/响应 Pydantic Schema 定义。
所有 API 接口的输入输出数据模型均在此统一管理。
"""
import re
from enum import Enum
from typing import Any, Optional
from pydantic import BaseModel, Field, field_validator
from datetime import datetime

from app.core.content_i18n import SUPPORTED_LANGS

# SHA-256 输出的 64 位小写十六进制字符串，各端设备指纹统一格式
_SHA256_HEX_RE = re.compile(r'^[0-9a-f]{64}$')
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _normalize_email(v: str) -> str:
    email = (v or "").strip().lower()
    if not _EMAIL_RE.match(email):
        raise ValueError("邮箱地址格式不合法")
    return email


def _normalize_sha256_hex(v: str, *, allow_empty: bool = False) -> str:
    value = (v or "").strip().lower()
    if allow_empty and not value:
        return ""
    if not _SHA256_HEX_RE.match(value):
        raise ValueError("必须为 SHA-256 哈希的 64 位小写十六进制字符串")
    return value


# ── 音频处理 ──────────────────────────────────────────────

class ActionType(str, Enum):
    """后端处理结果的操作类型，客户端据此决定如何消费 result 字段。"""
    paste = "paste"                                     # 写入剪贴板 + 自动粘贴到目标输入框（当前默认行为）
    clarify = "clarify"                                 # LLM 无法确定意图，result 为原封不动的选中文本，clarify_question 为询问文案
    show_markdown = "show_markdown"                     # 拉起悬浮窗展示 Markdown 格式内容（搜索结果等），不写入输入框
    tip = "tip"                                         # 居中下方短暂 tip 提示（4秒自动消失），result 为 code 码，客户端通过 L10n 映射文案
    openclaw_execute = "openclaw_execute"               # 将 result 自然语言任务文本通过 Gateway RPC 发给 openclaw（经 AI 处理）
    openclaw_slash_command = "openclaw_slash_command"   # /stop 等会话控制命令，通过 Gateway RPC 中断或发送到 agent 会话
    openclaw_cli_command = "openclaw_cli_command"       # `openclaw status` 等无交互 CLI 命令，复用 openclaw 专属终端执行
    openclaw_interactive = "openclaw_interactive"       # 需用户交互的 CLI 命令（auth login/onboard 等），新开独立终端执行


class ConfigUpdate(BaseModel):
    """后端配置变更通知，客户端收到后应覆盖本地缓存。"""
    max_duration_sec: Optional[int] = None


class AudioTranscribeResponse(BaseModel):
    """音频处理接口统一响应体，包含语音识别原文、处理结果和操作类型。"""
    operation: str                          # 入参操作类型（transcribe / rewrite / agent 等）
    action_type: ActionType = ActionType.paste  # 后端决定的结果操作类型
    transcript: str                         # Whisper 语音识别原文
    result: str                             # 最终结果文本（可能是识别原文或 LLM 处理后的文本）
    model_provider: Optional[str] = None    # 实际使用的 LLM 提供商（未调用 LLM 时为 None）
    model_name: Optional[str] = None        # 实际使用的模型名称（未调用 LLM 时为 None）
    warning: Optional[str] = None           # 非致命警告（如时长超限），客户端应弹窗提示用户
    config_update: Optional[ConfigUpdate] = None  # 配置变更通知，客户端收到后覆盖本地缓存
    clarify_question: Optional[str] = None  # 仅 action_type=clarify 时有值，LLM 生成的意图询问文案
    credits_remaining: Optional[int] = None  # 本次操作后的剩余积分，客户端据此更新本地积分显示
    asr_resolution_source: Optional[str] = None  # v2 实时 ASR 文本来源：server_final / client_fallback 等
    agent_intent: Optional[str] = None      # agent 操作最终真实执行的分支：SEARCH / REWRITE / TRANSCRIBE / OPENCLAW_*


class TextProcessRequest(BaseModel):
    """v2 文本处理接口请求体：ASR 已在实时 WebSocket 完成，这里只处理后续业务节点。"""
    operation: str = Field(..., max_length=40, description="操作类型：transcribe | rewrite | agent")
    text: str = Field("", max_length=20000, description="兼容字段：客户端实时 ASR 完整文本兜底")
    client_asr_text: Optional[str] = Field(default=None, max_length=20000, description="客户端实时 ASR 完整文本兜底")
    asr_session_id: Optional[str] = Field(default=None, max_length=96, description="实时 ASR WebSocket 会话 ID")
    selected_text: Optional[str] = Field(default=None, max_length=12000, description="客户端当前选中的文本")
    clipboard_history: Optional[list[str]] = Field(default=None, description="剪贴板最近文本内容")
    clipboard_items: Optional[list[dict[str, Any]]] = Field(default=None, description="结构化剪贴板内容")
    provider: Optional[str] = Field(default=None, max_length=80, description="模型提供商，留空使用默认值")
    model: Optional[str] = Field(default=None, max_length=120, description="模型名称，留空使用默认值")
    openclaw_status: Optional[str] = Field(default=None, max_length=40, description="OpenClaw 状态")
    openclaw_session_active: bool = Field(default=False, description="客户端本地 OpenClaw 模式是否已开启")
    fast_mode: bool = Field(default=False, description="极速模式：transcribe 仅返回 ASR 结果")
    transcript_language: Optional[str] = Field(default=None, max_length=40, description="ASR 识别语言")


class AndroidQuickAction(str, Enum):
    """Android 输入法一键处理动作。"""
    format = "format"       # 整理段落、标点、换行和轻量结构
    polish = "polish"       # 润色表达，保持原意
    concise = "concise"     # 压缩冗余，保留关键信息
    bullets = "bullets"     # 转成要点/待办清单


class AndroidQuickActionRequest(BaseModel):
    """Android 输入法对已有文本执行一键处理。"""
    action: AndroidQuickAction
    text: str = Field(..., min_length=1, max_length=12000, description="待处理文本")
    source_operation: Optional[str] = Field(None, max_length=40, description="客户端来源操作，如 transcribe/rewrite")


class TextQuickActionResponse(BaseModel):
    """文本快捷处理接口响应体，不绑定音频/ASR 流程。"""
    operation: str
    action_type: ActionType = ActionType.paste
    input_text: str
    result: str
    model_provider: Optional[str] = None
    model_name: Optional[str] = None
    credits_remaining: Optional[int] = None
    # Android 当前历史记录仍读取 transcript；保留兼容字段，但语义是 input_text，不是 ASR transcript。
    transcript: str = ""


# ── 认证 ──────────────────────────────────────────────────

class SendCodeRequest(BaseModel):
    """发送验证码请求体。"""
    email: str = Field(..., description="邮箱地址")

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _normalize_email(v)


class LoginRequest(BaseModel):
    """验证码登录请求体。"""
    email: str
    code: str = Field(..., description="邮箱验证码")
    device_id: str = Field("", description="客户端设备唯一标识，SHA-256 64位十六进制字符串")
    hardware_fingerprint: str = Field("", description="硬件指纹 SHA-256 64位十六进制字符串；空字符串表示该端暂不支持")

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _normalize_email(v)

    @field_validator("device_id")
    @classmethod
    def validate_device_id(cls, v: str) -> str:
        return _normalize_sha256_hex(v, allow_empty=True)

    @field_validator("hardware_fingerprint")
    @classmethod
    def validate_hardware_fingerprint(cls, v: str) -> str:
        return _normalize_sha256_hex(v, allow_empty=True)


class AuthResponse(BaseModel):
    """登录/注册成功响应体。"""
    token: str                              # JWT Token
    email: str                              # 用户邮箱
    tier: str = Field(..., description="用户等级: trial | vip | ...")
    is_new_user: bool = Field(False, description="是否为首次注册的新用户")
    require_invite: bool = Field(False, description="是否需要填写邀请码（is_new_user=True 时可能为 True）")


class VerifyInviteRequest(BaseModel):
    """新用户填写邀请码完成注册的请求体。"""
    email: str = Field(..., description="邮箱地址（与验证码流程中一致）")
    invite_code: str = Field(..., description="8位邀请码")
    device_id: str = Field(..., description="客户端设备唯一标识，SHA-256 64位十六进制字符串")
    hardware_fingerprint: str = Field("", description="硬件指纹 SHA-256 64位十六进制字符串；空字符串表示该端暂不支持")
    client_ip: Optional[str] = Field(None, description="客户端 IP（后端自动从请求中提取，此字段备用）")

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str) -> str:
        return _normalize_email(v)

    @field_validator("invite_code")
    @classmethod
    def validate_invite_code(cls, v: str) -> str:
        value = "".join(ch for ch in (v or "").strip().upper() if ch in "ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        if len(value) != 8:
            raise ValueError("邀请码格式不合法")
        return value

    @field_validator("device_id")
    @classmethod
    def validate_device_id(cls, v: str) -> str:
        """
        device_id 必须是 SHA-256 输出的 64 位小写十六进制字符串。
        这是各端通用格式：MAC 使用 IOPlatformUUID，Windows 使用 MachineGuid，
        Android 使用 ANDROID_ID，均经过 SHA-256 哈希后上报。
        强制格式校验可阻止 curl 直接传随意字符串进行暴力注册。
        """
        v = _normalize_sha256_hex(v)
        if not _SHA256_HEX_RE.match(v):
            raise ValueError("device_id 必须为 SHA-256 哈希的 64 位小写十六进制字符串")
        return v

    @field_validator("hardware_fingerprint")
    @classmethod
    def validate_hardware_fingerprint(cls, v: str) -> str:
        """
        hardware_fingerprint 允许为空字符串（表示该平台暂不支持多维指纹）。
        若非空，则必须符合 SHA-256 的 64 位十六进制格式。
        """
        v = _normalize_sha256_hex(v, allow_empty=True)
        if v and not _SHA256_HEX_RE.match(v):
            raise ValueError("hardware_fingerprint 若非空，必须为 SHA-256 哈希的 64 位小写十六进制字符串")
        return v


class InviteCodeItem(BaseModel):
    """单条邀请码信息。"""
    code: str = Field(..., description="8位邀请码")
    is_used: bool = Field(..., description="是否已被使用")
    used_by: Optional[str] = Field(None, description="使用者邮箱（脱敏）")
    used_at: Optional[datetime] = Field(None, description="使用时间")


class MyInviteCodesResponse(BaseModel):
    """我的邀请码列表响应体。"""
    invite_codes: list[InviteCodeItem]


class CreditBalanceItem(BaseModel):
    """有效积分明细项。"""
    id: str = Field(..., description="明细项唯一标识")
    type: str = Field(..., description="积分类型: plan | bonus | paid_topup")
    source: str = Field("", description="来源")
    label: str = Field("", description="展示标签")
    credits_total: int = Field(0, description="该项有效总积分")
    credits_used: int = Field(0, description="该项已使用积分")
    credits_remaining: int = Field(0, description="该项剩余积分")
    expires_at: Optional[datetime] = Field(None, description="该项失效时间（UTC）")


class UserPlanInfo(BaseModel):
    """用户套餐积分信息响应体。"""
    tier: str = Field(..., description="套餐等级: trial | none | ...")
    plan_name: str = Field("", description="套餐本地化展示名（按 X-Accept-Language 返回，对齐 persona 策略）")
    credits_total: int = Field(0, description="本周期总积分额度")
    credits_used: int = Field(0, description="本周期已消耗积分")
    credits_remaining: int = Field(0, description="本周期剩余积分")
    credits_reset_at: Optional[datetime] = Field(None, description="下次积分重置时间（UTC）")
    bonus_credits_remaining: int = Field(0, description="非套餐奖励积分剩余")
    paid_topup_credits_remaining: int = Field(0, description="付费加购积分剩余")
    credit_items: list[CreditBalanceItem] = Field(default_factory=list, description="所有有效积分明细")
    plan_expires_at: Optional[datetime] = Field(None, description="当前套餐到期时间（UTC）")
    subscription_expires_at: Optional[datetime] = Field(None, description="当前订阅到期时间（UTC，免费套餐可为空）")
    subscription_billing_cycle: Optional[str] = Field(None, description="当前订阅支付周期: monthly | quarterly | yearly")
    subscription_auto_renew: bool = Field(False, description="是否开启自动续费")
    auto_renew: bool = Field(False, description="是否开启自动续费（订阅管理入口用，与 subscription_auto_renew 同值）")
    next_renewal_at: Optional[datetime] = Field(None, description="下次自动续费扣款时间（UTC，未开启自动续费时为空）")
    renewal_cancellable: bool = Field(False, description="是否可取消自动续费（客户端据此显示「取消订阅」入口）")
    pending_plan_code: Optional[str] = Field(None, description="待生效套餐 code")
    pending_effective_at: Optional[datetime] = Field(None, description="待生效套餐生效时间（UTC）")
    pending_billing_cycle: Optional[str] = Field(None, description="待生效套餐支付周期")
    registration_enabled: bool = Field(True, description="注册总开关，关闭后新用户无法注册")
    invite_code_enabled: bool = Field(False, description="邀请码注册功能是否开启（控制注册流程是否需要邀请码）")
    show_invite_codes_enabled: bool = Field(False, description="客户端是否显示邀请码查看入口（独立于注册开关）")
    show_subscription_module_enabled: bool = Field(True, description="客户端是否显示套餐订阅入口")


class AppStartupConfig(BaseModel):
    """App 启动时拉取的全局配置（无需鉴权）。"""
    registration_enabled: bool = Field(True, description="注册总开关，关闭后新用户无法注册")
    invite_code_enabled: bool = Field(True, description="邀请码注册功能是否开启")
    show_invite_codes_enabled: bool = Field(False, description="客户端登录后是否显示邀请码查看入口")
    show_subscription_module_enabled: bool = Field(True, description="客户端登录后是否显示套餐订阅入口")
    registration_limit_enabled: bool = Field(False, description="注册总人数限制是否开启")
    registration_limit_count: int = Field(1000, description="注册总人数上限（仅 registration_limit_enabled=True 时有效）")


class PendingVerifyResponse(BaseModel):
    """新用户验证码通过但需要邀请码时的响应体（不携带 token）。"""
    require_invite: bool = True
    email: str = Field(..., description="已验证的邮箱，用于后续邀请码步骤")


# ── 管理/运营接口（注册封禁排查 + 解封） ────────────────────

class RegAccountInfo(BaseModel):
    """
    单个关联账号的注册明文信息。
    供运营人员排查误封禁、关联溯源使用。
    """
    email: str                                      # 账号邮箱
    tier: str = ""                                  # 账号等级
    is_active: bool = True                          # 是否正常（False=已被禁用）
    reg_device_id: str = ""                         # 注册时的设备 UUID（明文）
    reg_ip: str = ""                                # 注册时的 IP 地址（明文）
    reg_hw_fingerprint: str = ""                    # 注册时的硬件指纹 SHA-256（明文）
    invited_by: str = ""                            # 被谁的邀请码邀请注册
    created_at: Optional[datetime] = None           # 注册时间（UTC）


class RegDeviceGroup(BaseModel):
    """
    同设备码下所有关联账号分组视图（管理巡检用）。
    account_count >= max_accounts_per_device 时表示该设备已达封禁阈值。
    """
    device_id: str                                  # 设备 UUID
    account_count: int                              # 该设备下注册的账号总数
    accounts: list[RegAccountInfo]                  # 关联账号明文列表（含注册 IP / 指纹）


class RegDeviceGroupListResponse(BaseModel):
    """聚合查询响应：返回多组设备关联账号。"""
    total_groups: int
    max_accounts_per_device: int                    # 当前封禁阈值，便于运营判断
    groups: list[RegDeviceGroup]


class AdminQueryRequest(BaseModel):
    """
    管理端关联账号查询请求体。
    四种维度任选其一，优先级：email > device_id > ip > hw_fingerprint
    """
    email: Optional[str] = Field(None, description="按邮箱精确或前缀查询（模糊匹配）")
    device_id: Optional[str] = Field(None, description="按设备 UUID 精确查询")
    ip: Optional[str] = Field(None, description="按注册 IP 精确查询")
    hw_fingerprint: Optional[str] = Field(None, description="按硬件指纹精确查询")


class AdminQueryResponse(BaseModel):
    """管理端查询结果：命中的关联账号列表 + 基础封禁状态。"""
    query_key: str                                  # 本次查询条件描述，如 "device_id=XXXX"
    account_count: int                              # 命中账号总数
    max_accounts_per_device: int                    # 封禁阈值
    is_over_limit: bool                             # 是否已超出封禁阈值
    accounts: list[RegAccountInfo]                  # 关联账号完整明文列表


class UnbanRequest(BaseModel):
    """
    解封操作请求体。
    mode=delete  → 硬删除账号（释放设备名额，适合误封场景）
    mode=disable → 软禁用账号（保留注册记录，适合违规封号）
    """
    email: str = Field(..., description="要解封/禁用的账号邮箱")
    mode: str = Field("delete", description="操作类型: delete（硬删除解封）| disable（软禁用）")
    reason: Optional[str] = Field(None, description="操作原因备注（记录到日志）")


class UnbanResponse(BaseModel):
    """解封操作响应。"""
    email: str
    mode: str
    success: bool
    message: str


class SetRegLimitRequest(BaseModel):
    """修改注册上限请求体。"""
    max_accounts: int = Field(..., ge=1, le=100, description="新的每设备最大注册账号数")


# ── 词典（热词）────────────────────────────────────────────

class HotWord(BaseModel):
    """热词条目（专有名词表），后续在语音识别/LLM 处理时作为参考词汇。"""
    id: str = Field(..., description="热词唯一 ID")
    word: str = Field(..., description="标准词（期望输出的正确写法）")
    created_at: Optional[datetime] = None


class HotWordCreateRequest(BaseModel):
    """新增热词请求体。"""
    word: str = Field(..., min_length=1, max_length=20, description="标准词，最长20字符")


class HotWordUpdateRequest(BaseModel):
    """更新热词请求体。"""
    word: str = Field(..., min_length=1, max_length=20, description="标准词，最长20字符")


class HotWordListResponse(BaseModel):
    """热词列表响应体（翻页版）。"""
    hotwords: list[HotWord]
    total: int = Field(0, description="当前用户热词总数")
    page: int = Field(1, description="当前页码（从1开始）")
    page_size: int = Field(50, description="每页条数")
    has_more: bool = Field(False, description="是否还有更多数据")


# ── 人设配置 ───────────────────────────────────────────────
# 提示词字段最大长度：4000 字符；名称最大 60 字符；描述最大 200 字符
# 每用户最多 10 个用户自定义人设；内置人设不计入额度；同时只能激活一个人设

PERSONA_PROMPT_MAX_LEN = 4000
PERSONA_NAME_MAX_LEN   = 60
PERSONA_DESC_MAX_LEN   = 200
PERSONA_MAX_COUNT      = 10
PERSONA_I18N_LANGS = SUPPORTED_LANGS  # 语言集单一真源在 core.content_i18n


class PersonaPrompts(BaseModel):
    """
    人设内三个可独立配置的提示词模块。
    每个模块有 prompt（内容）+ enabled（是否启用）两个字段。
    enabled=False 时即使有 prompt 也使用内置，方便临时回退而不丢失内容。

    - transcribe_prompt / transcribe_enabled: 语音转文字模块（替换静态系统规则）
    - rewrite_prompt   / rewrite_enabled:     改写/生成模块（替换静态系统规则）
    - intent_hint      / intent_enabled:      Agent 意图识别补充（追加到内置末尾）
    """
    transcribe_prompt: Optional[str] = Field(None, max_length=PERSONA_PROMPT_MAX_LEN)
    transcribe_enabled: bool = Field(False)
    rewrite_prompt: Optional[str] = Field(None, max_length=PERSONA_PROMPT_MAX_LEN)
    rewrite_enabled: bool = Field(False)
    intent_hint: Optional[str] = Field(None, max_length=PERSONA_PROMPT_MAX_LEN)
    intent_enabled: bool = Field(False)


class PersonaItem(BaseModel):
    """单条人设列表数据。内置人设对客户端隐藏实际提示词内容。"""
    id: str = Field(..., description="人设唯一 ID（UUID）")
    name: str = Field(..., max_length=PERSONA_NAME_MAX_LEN, description="人设名称")
    description: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN, description="人设描述")
    is_active: bool = Field(False, description="是否为当前激活的人设")
    is_builtin: bool = Field(False, description="是否为管理端配置的公共内置人设")
    is_enabled: bool = Field(True, description="内置人设是否已由管理端启用；用户自定义人设恒为 true")
    prompts: PersonaPrompts = Field(default_factory=PersonaPrompts)


class PersonaListResponse(BaseModel):
    """人设列表响应体。"""
    personas: list[PersonaItem]


class PersonaCreateRequest(BaseModel):
    """新建人设请求体（name 必填，其余可选）。"""
    name: str = Field(..., min_length=1, max_length=PERSONA_NAME_MAX_LEN)
    description: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN)
    prompts: PersonaPrompts = Field(default_factory=PersonaPrompts)


class PersonaUpdateRequest(BaseModel):
    """更新人设请求体（所有字段均可选，只更新传入的字段）。"""
    name: Optional[str] = Field(None, min_length=1, max_length=PERSONA_NAME_MAX_LEN)
    description: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN)
    prompts: Optional[PersonaPrompts] = None


class BuiltinPersonaI18nText(BaseModel):
    """管理端配置的内置人设可见文案。提示词正文不做国际化。"""
    zh: str = Field(..., min_length=1, max_length=PERSONA_NAME_MAX_LEN)
    zh_hant: Optional[str] = Field(None, alias="zh-Hant", max_length=PERSONA_NAME_MAX_LEN)
    yue: Optional[str] = Field(None, max_length=PERSONA_NAME_MAX_LEN)
    en: Optional[str] = Field(None, max_length=PERSONA_NAME_MAX_LEN)
    ru: Optional[str] = Field(None, max_length=PERSONA_NAME_MAX_LEN)
    ko: Optional[str] = Field(None, max_length=PERSONA_NAME_MAX_LEN)


class BuiltinPersonaI18nDescription(BaseModel):
    zh: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN)
    zh_hant: Optional[str] = Field(None, alias="zh-Hant", max_length=PERSONA_DESC_MAX_LEN)
    yue: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN)
    en: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN)
    ru: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN)
    ko: Optional[str] = Field(None, max_length=PERSONA_DESC_MAX_LEN)


class BuiltinPersonaCreateRequest(BaseModel):
    """管理端新建内置人设请求体。"""
    localized_names: BuiltinPersonaI18nText
    localized_descriptions: BuiltinPersonaI18nDescription = Field(default_factory=BuiltinPersonaI18nDescription)
    prompts: PersonaPrompts = Field(default_factory=PersonaPrompts)


class BuiltinPersonaUpdateRequest(BaseModel):
    """管理端更新内置人设请求体。"""
    localized_names: Optional[BuiltinPersonaI18nText] = None
    localized_descriptions: Optional[BuiltinPersonaI18nDescription] = None
    prompts: Optional[PersonaPrompts] = None
