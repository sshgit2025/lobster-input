package com.lobster.input.data.model

import android.content.Context
import com.google.gson.annotations.SerializedName
import com.lobster.input.core.locale.MobileStrings

// ==================== 认证相关 ====================

data class SendCodeRequest(
    val email: String
)

data class LoginRequest(
    val email: String,
    val code: String,
    @SerializedName("device_id")
    val deviceId: String,
    @SerializedName("hardware_fingerprint")
    val hardwareFingerprint: String = ""
)

data class AuthResponse(
    val token: String,
    val email: String,
    val tier: String = "trial",
    @SerializedName("is_new_user")
    val isNewUser: Boolean = false,
    @SerializedName("require_invite")
    val requireInvite: Boolean = false
)

data class VerifyInviteRequest(
    val email: String,
    @SerializedName("invite_code")
    val inviteCode: String,
    @SerializedName("device_id")
    val deviceId: String,
    @SerializedName("hardware_fingerprint")
    val hardwareFingerprint: String = ""
)

data class InviteCodeItem(
    val code: String,
    @SerializedName("is_used")
    val isUsed: Boolean,
    @SerializedName("used_by")
    val usedBy: String?,
    @SerializedName("used_at")
    val usedAt: String?
)

data class MyInviteCodesResponse(
    @SerializedName("invite_codes")
    val inviteCodes: List<InviteCodeItem>
)

// ==================== 套餐积分 ====================

data class UserPlanInfo(
    val tier: String = "none",
    // 后端按 X-Accept-Language 返回的本地化套餐名(套餐文案统一后端管理);优先展示,空则回退本地翻译
    @SerializedName("plan_name")
    val planName: String = "",
    @SerializedName("credits_total")
    val creditsTotal: Int = 0,
    @SerializedName("credits_used")
    val creditsUsed: Int = 0,
    @SerializedName("credits_remaining")
    val creditsRemaining: Int = 0,
    @SerializedName("credits_reset_at")
    val creditsResetAt: String? = null,
    @SerializedName("plan_expires_at")
    val planExpiresAt: String? = null,
    @SerializedName("subscription_expires_at")
    val subscriptionExpiresAt: String? = null,
    @SerializedName("registration_enabled")
    val registrationEnabled: Boolean = true,
    @SerializedName("invite_code_enabled")
    val inviteCodeEnabled: Boolean = false,
    @SerializedName("show_invite_codes_enabled")
    val showInviteCodesEnabled: Boolean = false,
    @SerializedName("auto_renew")
    val autoRenew: Boolean = false,
    @SerializedName("next_renewal_at")
    val nextRenewalAt: String? = null,
    @SerializedName("renewal_cancellable")
    val renewalCancellable: Boolean = false
)

// ==================== 订阅自动续费 ====================

/** 取消自动续费请求:后端约定空 JSON body,Gson 将无字段类序列化为 {}。 */
class CancelRenewalBody

data class CancelRenewalResponse(
    val status: String = "",
    @SerializedName("effective_until")
    val effectiveUntil: String? = null
)

// ==================== 支付与订阅 ====================

data class PaymentCatalogResponse(
    @SerializedName("active_provider")
    val activeProvider: String = "",
    val providers: List<PaymentProvider> = emptyList(),
    @SerializedName("payment_methods")
    val paymentMethods: List<PaymentMethod> = emptyList(),
    @SerializedName("subscription_module")
    val subscriptionModule: SubscriptionModuleState = SubscriptionModuleState(),
    @SerializedName("current_plan")
    val currentPlan: PaymentCurrentPlan = PaymentCurrentPlan(),
    val subscriptions: List<PaymentSubscriptionPlan> = emptyList(),
    @SerializedName("credits_topup")
    val creditsTopup: PaymentCreditsTopup = PaymentCreditsTopup(),
    val discount: PaymentDiscount = PaymentDiscount()
)

data class PaymentProvider(
    val code: String = "",
    val name: String = "",
    val status: String? = null
)

data class PaymentMethod(
    val code: String = "",
    val name: String = "",
    val description: String? = null,
    val enabled: Boolean? = null,
    @SerializedName("sort_order")
    val sortOrder: Int? = null,
    val currencies: List<String>? = null
)

data class SubscriptionModuleState(
    val enabled: Boolean = true
)

data class PaymentCurrentPlan(
    @SerializedName("plan_code")
    val planCode: String = "free",
    // 后端本地化套餐名(catalog current_plan);优先展示
    @SerializedName("plan_name")
    val planName: String = "",
    @SerializedName("plan_credits_total")
    val planCreditsTotal: Int = 0,
    @SerializedName("plan_credits_used")
    val planCreditsUsed: Int = 0,
    @SerializedName("plan_credits_remaining")
    val planCreditsRemaining: Int = 0,
    val paid: Boolean = false,
    @SerializedName("paid_topup_enabled")
    val paidTopupEnabled: Boolean = false,
    // 当前套餐的账期(monthly/yearly 等),旧后端不返回时为 null
    @SerializedName("billing_cycle")
    val billingCycle: String? = null
)

data class PaymentSubscriptionPlan(
    val type: String = "subscription",
    @SerializedName("plan_code")
    val planCode: String = "",
    val name: String = "",
    val credits: Int = 0,
    val rank: Int = 0,
    @SerializedName("billing_options")
    val billingOptions: List<PaymentBillingOption> = emptyList()
)

data class PaymentBillingOption(
    val cycle: String = "",
    @SerializedName("product_code")
    val productCode: String? = null,
    @SerializedName("price_cents")
    val priceCents: Int = 0,
    val currency: String? = null,
    @SerializedName("payment_methods")
    val paymentMethods: List<PaymentMethod>? = null,
    @SerializedName("duration_period")
    val durationPeriod: String? = null,
    @SerializedName("duration_count")
    val durationCount: Int = 1,
    // —— 以下为月付→年付补差价升级新增字段,旧后端不返回时均为 null ——
    // 实际应付金额(分),升级场景下为补差价后的金额
    @SerializedName("payable_price_cents")
    val payablePriceCents: Int? = null,
    // 结算方式:full_price(全价) / prorated_difference(按剩余价值补差价)
    @SerializedName("settlement_mode")
    val settlementMode: String? = null,
    // 升级时抵扣的未使用部分金额(分)
    @SerializedName("upgrade_credit_cents")
    val upgradeCreditCents: Int? = null,
    // 服务端权威的可购判定,null 表示旧后端未提供
    val purchasable: Boolean? = null,
    // 不可购原因:duplicate_purchase / lower_tier / cycle_downgrade
    @SerializedName("blocked_reason")
    val blockedReason: String? = null
) {
    /** 实际应付金额(分):优先取服务端下发的应付价,旧后端回退到原价。 */
    val effectivePriceCents: Int
        get() = payablePriceCents ?: priceCents

    /** 是否为补差价升级:服务端标记按剩余价值结算且应付价低于原价。 */
    val isProratedUpgrade: Boolean
        get() = settlementMode == "prorated_difference" && effectivePriceCents < priceCents
}

data class PaymentCreditsTopup(
    val type: String = "credits_topup",
    val provider: String = "",
    @SerializedName("product_code")
    val productCode: String? = null,
    val enabled: Boolean = false,
    val available: Boolean = false,
    val amount: Int? = null,
    @SerializedName("price_cents")
    val priceCents: Int? = null,
    val currency: String? = null,
    @SerializedName("payment_methods")
    val paymentMethods: List<PaymentMethod>? = null,
    @SerializedName("blocked_reason")
    val blockedReason: String? = null
)

data class PaymentDiscount(
    val supported: Boolean = true,
    @SerializedName("default_enabled")
    val defaultEnabled: Boolean = false
)

data class CreateSubscriptionCheckoutBody(
    @SerializedName("plan_code")
    val planCode: String,
    @SerializedName("billing_cycle")
    val billingCycle: String,
    @SerializedName("auto_renew")
    val autoRenew: Boolean,
    val provider: String,
    @SerializedName("product_code")
    val productCode: String,
    @SerializedName("payment_method")
    val paymentMethod: String,
    val currency: String,
    @SerializedName("settlement_mode")
    val settlementMode: String,
    @SerializedName("discount_code")
    val discountCode: String
)

data class CreateCreditsTopupCheckoutBody(
    val provider: String,
    @SerializedName("product_code")
    val productCode: String,
    @SerializedName("payment_method")
    val paymentMethod: String,
    val currency: String,
    @SerializedName("discount_code")
    val discountCode: String
)

data class PaymentCheckoutResponse(
    val provider: String = "",
    @SerializedName("request_id")
    val requestId: String? = null,
    @SerializedName("checkout_id")
    val checkoutId: String? = null,
    @SerializedName("checkout_url")
    val checkoutUrl: String = "",
    val status: String? = null
)

// ==================== App启动配置 ====================

data class AppStartupConfig(
    @SerializedName("registration_enabled")
    val registrationEnabled: Boolean = true,
    @SerializedName("invite_code_enabled")
    val inviteCodeEnabled: Boolean = true,
    @SerializedName("show_invite_codes_enabled")
    val showInviteCodesEnabled: Boolean = false,
    @SerializedName("registration_limit_enabled")
    val registrationLimitEnabled: Boolean = false,
    @SerializedName("registration_limit_count")
    val registrationLimitCount: Int = 1000
)

// ==================== 音频处理 ====================

enum class ActionType {
    @SerializedName("paste")
    PASTE,
    @SerializedName("clarify")
    CLARIFY,
    @SerializedName("show_markdown")
    SHOW_MARKDOWN,
    @SerializedName("tip")
    TIP
}

data class ConfigUpdatePayload(
    @SerializedName("max_duration_sec")
    val maxDurationSec: Int?
)

data class AudioProcessResponse(
    val operation: String,
    @SerializedName("action_type")
    val actionType: ActionType = ActionType.PASTE,
    val transcript: String,
    val result: String,
    @SerializedName("model_provider")
    val modelProvider: String? = null,
    @SerializedName("model_name")
    val modelName: String? = null,
    val warning: String? = null,
    @SerializedName("config_update")
    val configUpdate: ConfigUpdatePayload? = null,
    @SerializedName("clarify_question")
    val clarifyQuestion: String? = null,
    @SerializedName("credits_remaining")
    val creditsRemaining: Int? = null
)

data class TextProcessRequest(
    val operation: String,
    val text: String,
    @SerializedName("client_asr_text")
    val clientAsrText: String? = null,
    @SerializedName("asr_session_id")
    val asrSessionId: String? = null,
    @SerializedName("selected_text")
    val selectedText: String? = null,
    @SerializedName("clipboard_history")
    val clipboardHistory: List<String>? = null,
    val provider: String? = null,
    val model: String? = null,
    @SerializedName("fast_mode")
    val fastMode: Boolean = false,
    @SerializedName("transcript_language")
    val transcriptLanguage: String? = null
)

enum class AndroidQuickAction {
    @SerializedName("format")
    FORMAT,
    @SerializedName("polish")
    POLISH,
    @SerializedName("concise")
    CONCISE,
    @SerializedName("bullets")
    BULLETS
}

data class AndroidQuickActionRequest(
    val action: AndroidQuickAction,
    val text: String,
    @SerializedName("source_operation")
    val sourceOperation: String? = null
)

data class TextQuickActionResponse(
    val operation: String,
    @SerializedName("action_type")
    val actionType: ActionType = ActionType.PASTE,
    @SerializedName("input_text")
    val inputText: String,
    val result: String,
    @SerializedName("model_provider")
    val modelProvider: String? = null,
    @SerializedName("model_name")
    val modelName: String? = null,
    @SerializedName("credits_remaining")
    val creditsRemaining: Int? = null,
    val transcript: String? = null
)

// ==================== 错误处理 ====================

data class ApiErrorResponse(
    val code: String,
    val message: String,
    @SerializedName("config_update")
    val configUpdate: ConfigUpdatePayload? = null
)

sealed class ApiException(message: String) : Exception(message) {
    data class HttpError(
        val statusCode: Int,
        val errorResponse: ApiErrorResponse?
    ) : ApiException(errorResponse?.message ?: "未知错误")
    
    data class NetworkError(override val cause: Throwable) : ApiException("网络连接失败")
    data class DecodingError(override val cause: Throwable) : ApiException("数据解析失败")
    object Unauthorized : ApiException("登录已过期，请重新登录")
    object UserBanned : ApiException("账号已被禁用")
    object NotLoggedIn : ApiException("请先登录")
    
    val errorCode: String?
        get() = (this as? HttpError)?.errorResponse?.code
    
    val configUpdate: ConfigUpdatePayload?
        get() = (this as? HttpError)?.errorResponse?.configUpdate
    
    val isCreditsExhausted: Boolean
        get() = errorCode == "CREDITS_EXHAUSTED"
    
    val isNonRetryable: Boolean
        get() = errorCode == "DURATION_EXCEEDED"
}

/**
 * 面向 UI 的本地化错误文案:异常自带的 message 是简体中文常量,不能直接展示。
 * 固定类型错误按当前语言映射;HttpError 优先服务端 message;未知异常回退调用方给的本地化 fallback。
 */
fun Throwable.displayMessage(context: Context, fallback: String): String = when (this) {
    is ApiException.Unauthorized -> MobileStrings.sessionExpired(context)
    is ApiException.NotLoggedIn -> MobileStrings.loginRequired(context)
    is ApiException.UserBanned -> MobileStrings.userBanned(context)
    is ApiException.NetworkError -> MobileStrings.networkError(context)
    is ApiException.DecodingError -> fallback
    is ApiException.HttpError -> MobileStrings.apiErrorMessage(context, errorResponse?.code, errorResponse?.message ?: fallback)
    else -> message ?: fallback
}

// ==================== 录音配置 ====================

data class RecordingConfigResponse(
    @SerializedName("max_duration_sec")
    val maxDurationSec: Int
)

// ==================== 词典（热词） ====================

data class HotWordItem(
    val id: String,
    val word: String,
    @SerializedName("created_at")
    val createdAt: String?
)

data class HotWordCreateBody(
    val word: String
)

data class HotWordUpdateBody(
    val word: String
)

data class HotWordListResponse(
    val hotwords: List<HotWordItem>
)

// ==================== 人设配置 ====================

const val PERSONA_PROMPT_MAX_LENGTH = 4000
const val PERSONA_NAME_MAX_LENGTH = 60
const val PERSONA_DESC_MAX_LENGTH = 200
const val PERSONA_MAX_COUNT = 10

data class PersonaPrompts(
    @SerializedName("transcribe_prompt")
    val transcribePrompt: String? = null,
    @SerializedName("transcribe_enabled")
    val transcribeEnabled: Boolean = false,
    @SerializedName("rewrite_prompt")
    val rewritePrompt: String? = null,
    @SerializedName("rewrite_enabled")
    val rewriteEnabled: Boolean = false,
    @SerializedName("intent_hint")
    val intentHint: String? = null,
    @SerializedName("intent_enabled")
    val intentEnabled: Boolean = false
)

data class PersonaItem(
    val id: String,
    val name: String,
    val description: String? = null,
    @SerializedName("is_active")
    val isActive: Boolean = false,
    @SerializedName("is_builtin")
    val isBuiltin: Boolean = false,
    val prompts: PersonaPrompts = PersonaPrompts()
)

data class PersonaListResponse(
    val personas: List<PersonaItem>
)

data class PersonaCreateBody(
    val name: String,
    val description: String?,
    val prompts: PersonaPrompts
)

data class PersonaUpdateBody(
    val name: String?,
    val description: String?,
    val prompts: PersonaPrompts?
)

// ==================== 协议 ====================

data class AgreementItem(
    val id: String,
    val type: String,
    val title: String,
    val content: String,
    val version: String
)

data class AgreementsResponse(
    val agreements: List<AgreementItem>
)
