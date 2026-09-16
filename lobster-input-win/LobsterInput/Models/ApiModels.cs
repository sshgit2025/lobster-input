using System.Net.Http;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text.Json;
using System.Text.Json.Serialization;
using LobsterInput.Helpers;
using LobsterInput.Services;

namespace LobsterInput.Models;

public record SendCodeRequest(
    [property: JsonPropertyName("email")] string Email);

public record LoginRequest(
    [property: JsonPropertyName("email")] string Email,
    [property: JsonPropertyName("code")] string Code,
    [property: JsonPropertyName("device_id")] string DeviceId,
    [property: JsonPropertyName("hardware_fingerprint")] string HardwareFingerprint);

public class AuthResponse {
    [JsonPropertyName("token")] public string Token { get; set; } = "";
    [JsonPropertyName("email")] public string Email { get; set; } = "";
    [JsonPropertyName("tier")] public string Tier { get; set; } = "trial";
    [JsonPropertyName("is_new_user")] public bool IsNewUser { get; set; }
    [JsonPropertyName("require_invite")] public bool RequireInvite { get; set; }
}

public class VerifyInviteRequest {
    [JsonPropertyName("email")] public string Email { get; set; } = "";
    [JsonPropertyName("invite_code")] public string InviteCode { get; set; } = "";
    [JsonPropertyName("device_id")] public string DeviceId { get; set; } = "";
    [JsonPropertyName("hardware_fingerprint")] public string HardwareFingerprint { get; set; } = "";
}

public class InviteCodeItem {
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("is_used")] public bool IsUsed { get; set; }
    [JsonPropertyName("used_by")] public string? UsedBy { get; set; }
    [JsonPropertyName("used_at")] public string? UsedAt { get; set; }
    [JsonIgnore] public string Id => Code;
}

public class MyInviteCodesResponse {
    [JsonPropertyName("invite_codes")] public List<InviteCodeItem> InviteCodes { get; set; } = new();
}

public class UserPlanInfo {
    [JsonPropertyName("tier")] public string Tier { get; set; } = "none";
    [JsonPropertyName("plan_name")] public string PlanName { get; set; } = "";
    [JsonPropertyName("credits_total")] public int CreditsTotal { get; set; }
    [JsonPropertyName("credits_used")] public int CreditsUsed { get; set; }
    [JsonPropertyName("credits_remaining")] public int CreditsRemaining { get; set; }
    [JsonPropertyName("credit_items")] public List<CreditBalanceItem> CreditItems { get; set; } = new();
    [JsonPropertyName("credits_reset_at")] public string? CreditsResetAt { get; set; }
    [JsonPropertyName("registration_enabled")] public bool RegistrationEnabled { get; set; } = true;
    [JsonPropertyName("invite_code_enabled")] public bool InviteCodeEnabled { get; set; }
    [JsonPropertyName("show_invite_codes_enabled")] public bool ShowInviteCodesEnabled { get; set; }
    [JsonPropertyName("show_subscription_module_enabled")] public bool ShowSubscriptionModuleEnabled { get; set; } = true;
    [JsonPropertyName("auto_renew")] public bool AutoRenew { get; set; }
    [JsonPropertyName("next_renewal_at")] public string? NextRenewalAt { get; set; }
    [JsonPropertyName("renewal_cancellable")] public bool RenewalCancellable { get; set; }
}

public class CreditBalanceItem {
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("source")] public string Source { get; set; } = "";
    [JsonPropertyName("label")] public string Label { get; set; } = "";
    [JsonPropertyName("credits_total")] public int CreditsTotal { get; set; }
    [JsonPropertyName("credits_used")] public int CreditsUsed { get; set; }
    [JsonPropertyName("credits_remaining")] public int CreditsRemaining { get; set; }
    [JsonPropertyName("expires_at")] public string? ExpiresAt { get; set; }
}

public class AppStartupConfig {
    [JsonPropertyName("registration_enabled")] public bool RegistrationEnabled { get; set; } = true;
    [JsonPropertyName("invite_code_enabled")] public bool InviteCodeEnabled { get; set; } = true;
    [JsonPropertyName("show_invite_codes_enabled")] public bool ShowInviteCodesEnabled { get; set; }
    [JsonPropertyName("show_subscription_module_enabled")] public bool ShowSubscriptionModuleEnabled { get; set; } = true;
    [JsonPropertyName("registration_limit_enabled")] public bool RegistrationLimitEnabled { get; set; }
    [JsonPropertyName("registration_limit_count")] public int RegistrationLimitCount { get; set; } = 1000;
}

public class PaymentCatalogResponse {
    [JsonPropertyName("active_provider")] public string ActiveProvider { get; set; } = "";
    [JsonPropertyName("providers")] public List<PaymentProvider> Providers { get; set; } = new();
    [JsonPropertyName("payment_methods")] public List<PaymentMethod> PaymentMethods { get; set; } = new();
    [JsonPropertyName("subscription_module")] public SubscriptionModuleState SubscriptionModule { get; set; } = new();
    [JsonPropertyName("current_plan")] public PaymentCurrentPlan CurrentPlan { get; set; } = new();
    [JsonPropertyName("subscriptions")] public List<PaymentSubscriptionPlan> Subscriptions { get; set; } = new();
    [JsonPropertyName("credits_topup")] public PaymentCreditsTopup CreditsTopup { get; set; } = new();
    [JsonPropertyName("discount")] public PaymentDiscount Discount { get; set; } = new();
}

public class PaymentProvider {
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("status")] public string? Status { get; set; }
}

public class PaymentMethod {
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("enabled")] public bool? Enabled { get; set; }
    [JsonPropertyName("sort_order")] public int? SortOrder { get; set; }
    [JsonPropertyName("currencies")] public List<string>? Currencies { get; set; }
}

public class SubscriptionModuleState {
    [JsonPropertyName("enabled")] public bool Enabled { get; set; } = true;
}

public class PaymentCurrentPlan {
    [JsonPropertyName("plan_code")] public string PlanCode { get; set; } = "";
    [JsonPropertyName("plan_credits_total")] public int PlanCreditsTotal { get; set; }
    [JsonPropertyName("plan_credits_used")] public int PlanCreditsUsed { get; set; }
    [JsonPropertyName("plan_credits_remaining")] public int PlanCreditsRemaining { get; set; }
    [JsonPropertyName("paid")] public bool Paid { get; set; }
    [JsonPropertyName("paid_topup_enabled")] public bool PaidTopupEnabled { get; set; }
    [JsonPropertyName("billing_cycle")] public string? BillingCycle { get; set; }
}

public class PaymentSubscriptionPlan {
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("plan_code")] public string PlanCode { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("credits")] public int Credits { get; set; }
    [JsonPropertyName("rank")] public int Rank { get; set; }
    [JsonPropertyName("billing_options")] public List<PaymentBillingOption> BillingOptions { get; set; } = new();
}

public class PaymentBillingOption {
    [JsonPropertyName("cycle")] public string Cycle { get; set; } = "";
    [JsonPropertyName("product_code")] public string? ProductCode { get; set; }
    [JsonPropertyName("price_cents")] public int PriceCents { get; set; }
    [JsonPropertyName("currency")] public string? Currency { get; set; }
    [JsonPropertyName("payment_methods")] public List<PaymentMethod>? PaymentMethods { get; set; }
    [JsonPropertyName("duration_period")] public string? DurationPeriod { get; set; }
    [JsonPropertyName("duration_count")] public int DurationCount { get; set; }
    [JsonPropertyName("payable_price_cents")] public int? PayablePriceCents { get; set; }
    [JsonPropertyName("settlement_mode")] public string? SettlementMode { get; set; }
    [JsonPropertyName("upgrade_credit_cents")] public int? UpgradeCreditCents { get; set; }
    [JsonPropertyName("purchasable")] public bool? Purchasable { get; set; }
    [JsonPropertyName("blocked_reason")] public string? BlockedReason { get; set; }

    [JsonIgnore] public int EffectivePriceCents => PayablePriceCents ?? PriceCents;
    [JsonIgnore] public bool IsProratedUpgrade => SettlementMode == "prorated_difference" && EffectivePriceCents < PriceCents;
}

public class PaymentCreditsTopup {
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    [JsonPropertyName("product_code")] public string? ProductCode { get; set; }
    [JsonPropertyName("enabled")] public bool Enabled { get; set; }
    [JsonPropertyName("available")] public bool Available { get; set; }
    [JsonPropertyName("blocked_reason")] public string? BlockedReason { get; set; }
    [JsonPropertyName("amount")] public int? Amount { get; set; }
    [JsonPropertyName("price_cents")] public int? PriceCents { get; set; }
    [JsonPropertyName("currency")] public string? Currency { get; set; }
    [JsonPropertyName("payment_methods")] public List<PaymentMethod>? PaymentMethods { get; set; }
}

public class PaymentDiscount {
    [JsonPropertyName("supported")] public bool Supported { get; set; }
    [JsonPropertyName("default_enabled")] public bool DefaultEnabled { get; set; }
}

public class PaymentCheckoutResponse {
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    [JsonPropertyName("checkout_id")] public string? CheckoutId { get; set; }
    [JsonPropertyName("checkout_url")] public string CheckoutUrl { get; set; } = "";
    [JsonPropertyName("status")] public string Status { get; set; } = "";
}

public record CreateSubscriptionCheckoutBody(
    [property: JsonPropertyName("plan_code")] string PlanCode,
    [property: JsonPropertyName("billing_cycle")] string BillingCycle,
    [property: JsonPropertyName("auto_renew")] bool AutoRenew,
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("product_code")] string ProductCode,
    [property: JsonPropertyName("payment_method")] string PaymentMethod,
    [property: JsonPropertyName("currency")] string Currency,
    [property: JsonPropertyName("settlement_mode")] string SettlementMode,
    [property: JsonPropertyName("discount_code")] string DiscountCode);

public class CancelRenewalResponse {
    // status: cancelled（本次取消成功）| already_cancelled（此前已取消，幂等）| apple_managed（需在订阅设备的应用商店中管理）
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("effective_until")] public string? EffectiveUntil { get; set; }
}

/// 空 JSON 请求体（序列化为 {}），用于仅依赖鉴权信息的 POST 接口
public record EmptyJsonBody;

public record CreateCreditsTopupCheckoutBody(
    [property: JsonPropertyName("provider")] string Provider,
    [property: JsonPropertyName("product_code")] string ProductCode,
    [property: JsonPropertyName("payment_method")] string PaymentMethod,
    [property: JsonPropertyName("currency")] string Currency,
    [property: JsonPropertyName("discount_code")] string DiscountCode);

public class ActionTypeConverter : JsonConverter<ActionType> {
    public override ActionType Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) {
        var value = reader.GetString();
        return value switch {
            "paste" => ActionType.Paste,
            "clarify" => ActionType.Clarify,
            "show_markdown" => ActionType.ShowMarkdown,
            "tip" => ActionType.Tip,
            "openclaw_execute" => ActionType.OpenclawExecute,
            "openclaw_slash_command" => ActionType.OpenclawSlashCommand,
            "openclaw_cli_command" => ActionType.OpenclawCliCommand,
            "openclaw_interactive" => ActionType.OpenclawInteractive,
            _ => throw new JsonException($"Unknown ActionType: {value}")
        };
    }

    public override void Write(Utf8JsonWriter writer, ActionType value, JsonSerializerOptions options) {
        var str = value switch {
            ActionType.Paste => "paste",
            ActionType.Clarify => "clarify",
            ActionType.ShowMarkdown => "show_markdown",
            ActionType.Tip => "tip",
            ActionType.OpenclawExecute => "openclaw_execute",
            ActionType.OpenclawSlashCommand => "openclaw_slash_command",
            ActionType.OpenclawCliCommand => "openclaw_cli_command",
            ActionType.OpenclawInteractive => "openclaw_interactive",
            _ => throw new JsonException($"Unknown ActionType: {value}")
        };
        writer.WriteStringValue(str);
    }
}

[JsonConverter(typeof(ActionTypeConverter))]
public enum ActionType {
    Paste,
    Clarify,
    ShowMarkdown,
    Tip,
    OpenclawExecute,
    OpenclawSlashCommand,
    OpenclawCliCommand,
    OpenclawInteractive,
}

public class ConfigUpdatePayload {
    [JsonPropertyName("max_duration_sec")] public int? MaxDurationSec { get; set; }
}

public class AudioProcessResponse {
    [JsonPropertyName("operation")] public string Operation { get; set; } = "";
    [JsonPropertyName("action_type")] public ActionType ActionType { get; set; }
    [JsonPropertyName("transcript")] public string Transcript { get; set; } = "";
    [JsonPropertyName("result")] public string Result { get; set; } = "";
    [JsonPropertyName("model_provider")] public string? ModelProvider { get; set; }
    [JsonPropertyName("model_name")] public string? ModelName { get; set; }
    [JsonPropertyName("warning")] public string? Warning { get; set; }
    [JsonPropertyName("config_update")] public ConfigUpdatePayload? ConfigUpdate { get; set; }
    [JsonPropertyName("clarify_question")] public string? ClarifyQuestion { get; set; }
    [JsonPropertyName("credits_remaining")] public int? CreditsRemaining { get; set; }
    [JsonPropertyName("asr_resolution_source")] public string? AsrResolutionSource { get; set; }
    [JsonPropertyName("agent_intent")] public string? AgentIntent { get; set; }
}

public class TextProcessRequest {
    [JsonPropertyName("operation")] public string Operation { get; set; } = "";
    [JsonPropertyName("text")] public string Text { get; set; } = "";
    [JsonPropertyName("client_asr_text")] public string ClientAsrText { get; set; } = "";
    [JsonPropertyName("asr_session_id")] public string AsrSessionId { get; set; } = "";
    [JsonPropertyName("selected_text")] public string? SelectedText { get; set; }
    [JsonPropertyName("clipboard_history")] public List<string>? ClipboardHistory { get; set; }
    [JsonPropertyName("clipboard_items")] public List<ClipboardContextItem>? ClipboardItems { get; set; }
    [JsonPropertyName("provider")] public string? Provider { get; set; }
    [JsonPropertyName("model")] public string? Model { get; set; }
    [JsonPropertyName("openclaw_status")] public string? OpenclawStatus { get; set; }
    [JsonPropertyName("openclaw_session_active")] public bool OpenclawSessionActive { get; set; }
    [JsonPropertyName("fast_mode")] public bool FastMode { get; set; }
    [JsonPropertyName("transcript_language")] public string? TranscriptLanguage { get; set; }
}

public class ApiErrorResponse {
    [JsonPropertyName("code")] public string Code { get; set; } = "";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("config_update")] public ConfigUpdatePayload? ConfigUpdate { get; set; }
}

public class RecordingConfigResponse {
    [JsonPropertyName("max_duration_sec")] public int MaxDurationSec { get; set; }
}

public record FeedbackSubmitRequest(
    [property: JsonPropertyName("content")] string Content,
    [property: JsonPropertyName("phone")] string? Phone,
    [property: JsonPropertyName("email")] string? Email,
    [property: JsonPropertyName("app_version")] string? AppVersion,
    [property: JsonPropertyName("os_version")] string? OsVersion);

public class HotWordItem {
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("word")] public string Word { get; set; } = "";
    [JsonPropertyName("created_at")] public string? CreatedAt { get; set; }
}

public record HotWordCreateBody(
    [property: JsonPropertyName("word")] string Word);

public record HotWordUpdateBody(
    [property: JsonPropertyName("word")] string Word);

public class HotWordListResponse {
    [JsonPropertyName("hotwords")] public List<HotWordItem> Hotwords { get; set; } = new();
    [JsonPropertyName("total")] public int Total { get; set; }
    [JsonPropertyName("page")] public int Page { get; set; } = 1;
    [JsonPropertyName("page_size")] public int PageSize { get; set; } = 50;
    [JsonPropertyName("has_more")] public bool HasMore { get; set; }
}

public static class PersonaConstants {
    public const int PromptMaxLength = 4000;
    public const int NameMaxLength = 60;
    public const int DescMaxLength = 200;
    public const int MaxCount = 10;
}

public class PersonaPrompts {
    [JsonPropertyName("transcribe_prompt")] public string? TranscribePrompt { get; set; }
    [JsonPropertyName("transcribe_enabled")] public bool TranscribeEnabled { get; set; }
    [JsonPropertyName("rewrite_prompt")] public string? RewritePrompt { get; set; }
    [JsonPropertyName("rewrite_enabled")] public bool RewriteEnabled { get; set; }
    [JsonPropertyName("intent_hint")] public string? IntentHint { get; set; }
    [JsonPropertyName("intent_enabled")] public bool IntentEnabled { get; set; }
}

public class PersonaItem {
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("is_active")] public bool IsActive { get; set; }
    [JsonPropertyName("is_builtin")] public bool IsBuiltin { get; set; }
    [JsonPropertyName("prompts")] public PersonaPrompts Prompts { get; set; } = new();
}

public class PersonaListResponse {
    [JsonPropertyName("personas")] public List<PersonaItem> Personas { get; set; } = new();
}

public class PersonaCreateBody {
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("prompts")] public PersonaPrompts Prompts { get; set; } = new();
}

public class PersonaUpdateBody {
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("description")] public string? Description { get; set; }
    [JsonPropertyName("prompts")] public PersonaPrompts? Prompts { get; set; }
}

public record EmptyResponse;

public class MessageResponse {
    [JsonPropertyName("message")] public string Message { get; set; } = "";
}

public class ApiException : Exception {
    public int StatusCode { get; }
    public ApiErrorResponse? ErrorResponse { get; }
    public string? ErrorCode => ErrorResponse?.Code;
    public ConfigUpdatePayload? ConfigUpdate => ErrorResponse?.ConfigUpdate;
    public bool IsNonRetryable => ErrorCode == "DURATION_EXCEEDED";
    public bool IsCreditsExhausted => ErrorCode == "CREDITS_EXHAUSTED";
    public bool RequiresLogout => StatusCode == 401 || ErrorCode == "USER_BANNED";

    public ApiException(int statusCode, string message, ApiErrorResponse? errorResponse = null)
        : base(message) {
        StatusCode = statusCode;
        ErrorResponse = errorResponse;
    }
}

// ── Log 上报共享类型（供 LogReporterService 与 ApiClient 共同使用）──

public class LogEntry
{
    [JsonPropertyName("level")] public string Level { get; set; } = "info";
    [JsonPropertyName("tag")] public string Tag { get; set; } = "";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("extra")] public Dictionary<string, string>? Extra { get; set; }
    [JsonPropertyName("timestamp")] public string Timestamp { get; set; } = "";
}

public class LogReportBody
{
    [JsonPropertyName("app_version")] public string AppVersion { get; set; } = "";
    [JsonPropertyName("os_version")] public string OsVersion { get; set; } = "";
    [JsonPropertyName("entries")] public List<LogEntry> Entries { get; set; } = [];
}

// ── 错误格式化工具 ──

public static class ApiErrorExtensions
{
    /// <summary>
    /// 将异常转为可展示的错误文案。
    /// 网络传输层异常(HttpRequestException/WebSocketException/SocketException,
    /// 以及 ApiClient 对它们的 ApiException(StatusCode==0) 包装)在弱网下携带的是底层英文
    /// 原文,统一映射为本地化网络错误提示;其余异常使用其 Message。
    /// </summary>
    public static string ToDisplayMessage(this Exception ex)
    {
        if (ex is ApiException api)
            return api.StatusCode == 0 ? L10n.ErrorNetwork : api.Message;
        if (ex is HttpRequestException or WebSocketException or SocketException)
            return L10n.ErrorNetwork;
        return ex.Message;
    }
}
