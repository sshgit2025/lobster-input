// 移植自 Android: data/model/ApiModels.kt(461 行,全部 DTO)。
// 约定:
// - interface 字段名与 JSON 序列化名严格一致(即 Kotlin @SerializedName 标注的真实字段名,
//   无标注的取 Kotlin 属性名),保证 JSON.stringify 直接产出正确的请求体。
// - 每个响应 DTO 提供 parseXxx(json: string) 工厂函数,内部做 undefined 兜底,
//   默认值与 Kotlin data class 的默认参数逐项对齐。
import { MobileStrings } from '../../core/locale/MobileStrings';

// ==================== JSON 解析辅助(内部) ====================

function asRecord(o: Object): Record<string, Object> {
  return o as Record<string, Object>;
}

function emptyRecord(): Record<string, Object> {
  const r: Record<string, Object> = {};
  return r;
}

function recOrNull(rec: Record<string, Object>, key: string): Record<string, Object> | null {
  const v: Object | undefined = rec[key];
  if (v !== undefined && v !== null && typeof v === 'object' && !(v instanceof Array)) {
    return asRecord(v);
  }
  return null;
}

function arrOr(rec: Record<string, Object>, key: string): Object[] {
  const v: Object | undefined = rec[key];
  if (v !== undefined && v !== null && v instanceof Array) {
    return v as Object[];
  }
  return [];
}

function arrOrNull(rec: Record<string, Object>, key: string): Object[] | null {
  const v: Object | undefined = rec[key];
  if (v !== undefined && v !== null && v instanceof Array) {
    return v as Object[];
  }
  return null;
}

function strOr(rec: Record<string, Object>, key: string, def: string): string {
  const v: Object | undefined = rec[key];
  return typeof v === 'string' ? v : def;
}

function strOrNull(rec: Record<string, Object>, key: string): string | null {
  const v: Object | undefined = rec[key];
  return typeof v === 'string' ? v : null;
}

function numOr(rec: Record<string, Object>, key: string, def: number): number {
  const v: Object | undefined = rec[key];
  return typeof v === 'number' ? v : def;
}

function numOrNull(rec: Record<string, Object>, key: string): number | null {
  const v: Object | undefined = rec[key];
  return typeof v === 'number' ? v : null;
}

function boolOr(rec: Record<string, Object>, key: string, def: boolean): boolean {
  const v: Object | undefined = rec[key];
  return typeof v === 'boolean' ? v : def;
}

function boolOrNull(rec: Record<string, Object>, key: string): boolean | null {
  const v: Object | undefined = rec[key];
  return typeof v === 'boolean' ? v : null;
}

function strListOrNull(rec: Record<string, Object>, key: string): string[] | null {
  const arr = arrOrNull(rec, key);
  if (arr === null) {
    return null;
  }
  const out: string[] = [];
  for (let i = 0; i < arr.length; i++) {
    const it: Object = arr[i];
    if (typeof it === 'string') {
      out.push(it);
    }
  }
  return out;
}

// ==================== 认证相关 ====================

export interface SendCodeRequest {
  email: string;
}

export interface LoginRequest {
  email: string;
  code: string;
  device_id: string;
  hardware_fingerprint: string;
}

export interface AuthResponse {
  token: string;
  email: string;
  tier: string; // 默认 "trial"
  is_new_user: boolean; // 默认 false
  require_invite: boolean; // 默认 false
}

function authResponseFrom(rec: Record<string, Object>): AuthResponse {
  const result: AuthResponse = {
    token: strOr(rec, 'token', ''),
    email: strOr(rec, 'email', ''),
    tier: strOr(rec, 'tier', 'trial'),
    is_new_user: boolOr(rec, 'is_new_user', false),
    require_invite: boolOr(rec, 'require_invite', false),
  };
  return result;
}

export function parseAuthResponse(json: string): AuthResponse {
  return authResponseFrom(asRecord(JSON.parse(json) as object));
}

export interface VerifyInviteRequest {
  email: string;
  invite_code: string;
  device_id: string;
  hardware_fingerprint: string;
}

export interface InviteCodeItem {
  code: string;
  is_used: boolean;
  used_by: string | null;
  used_at: string | null;
}

function inviteCodeItemFrom(rec: Record<string, Object>): InviteCodeItem {
  const result: InviteCodeItem = {
    code: strOr(rec, 'code', ''),
    is_used: boolOr(rec, 'is_used', false),
    used_by: strOrNull(rec, 'used_by'),
    used_at: strOrNull(rec, 'used_at'),
  };
  return result;
}

export interface MyInviteCodesResponse {
  invite_codes: InviteCodeItem[];
}

export function parseMyInviteCodesResponse(json: string): MyInviteCodesResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const items: InviteCodeItem[] = [];
  const arr = arrOr(rec, 'invite_codes');
  for (let i = 0; i < arr.length; i++) {
    items.push(inviteCodeItemFrom(asRecord(arr[i])));
  }
  const result: MyInviteCodesResponse = { invite_codes: items };
  return result;
}

// ==================== 套餐积分 ====================

export interface UserPlanInfo {
  tier: string; // 默认 "none"
  plan_name?: string; // 后端按 X-Accept-Language 返回的本地化套餐名(套餐文案统一后端管理);优先展示,空则回退本地
  credits_total: number;
  credits_used: number;
  credits_remaining: number;
  credits_reset_at: string | null;
  plan_expires_at: string | null; // 当前套餐到期时间，免费/永久套餐为空
  subscription_expires_at: string | null; // 当前订阅到期时间，免费套餐可能为空
  registration_enabled: boolean; // 默认 true
  invite_code_enabled: boolean; // 默认 false
  show_invite_codes_enabled: boolean; // 默认 false
  auto_renew: boolean; // 订阅是否开启自动续费,默认 false
  next_renewal_at: string | null; // 下次自动续费时间,未开启自动续费为空
  renewal_cancellable: boolean; // 当前渠道是否支持在本端取消自动续费,默认 false
}

export function parseUserPlanInfo(json: string): UserPlanInfo {
  const rec = asRecord(JSON.parse(json) as object);
  const result: UserPlanInfo = {
    tier: strOr(rec, 'tier', 'none'),
    credits_total: numOr(rec, 'credits_total', 0),
    credits_used: numOr(rec, 'credits_used', 0),
    credits_remaining: numOr(rec, 'credits_remaining', 0),
    credits_reset_at: strOrNull(rec, 'credits_reset_at'),
    plan_expires_at: strOrNull(rec, 'plan_expires_at'),
    subscription_expires_at: strOrNull(rec, 'subscription_expires_at'),
    registration_enabled: boolOr(rec, 'registration_enabled', true),
    invite_code_enabled: boolOr(rec, 'invite_code_enabled', false),
    show_invite_codes_enabled: boolOr(rec, 'show_invite_codes_enabled', false),
    auto_renew: boolOr(rec, 'auto_renew', false),
    next_renewal_at: strOrNull(rec, 'next_renewal_at'),
    renewal_cancellable: boolOr(rec, 'renewal_cancellable', false),
  };
  return result;
}

// ==================== 订阅自动续费管理 ====================

/** POST subscription/cancel-renewal 响应。status: cancelled | already_cancelled | apple_managed。 */
export interface CancelRenewalResponse {
  status: string;
  effective_until: string | null; // 取消后套餐仍可使用到的时间,可能为空
}

export function parseCancelRenewalResponse(json: string): CancelRenewalResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const result: CancelRenewalResponse = {
    status: strOr(rec, 'status', ''),
    effective_until: strOrNull(rec, 'effective_until'),
  };
  return result;
}

// ==================== 支付与订阅 ====================

export interface PaymentProvider {
  code: string;
  name: string;
  status: string | null;
}

function paymentProviderFrom(rec: Record<string, Object>): PaymentProvider {
  const result: PaymentProvider = {
    code: strOr(rec, 'code', ''),
    name: strOr(rec, 'name', ''),
    status: strOrNull(rec, 'status'),
  };
  return result;
}

export interface PaymentMethod {
  code: string;
  name: string;
  description: string | null;
  enabled: boolean | null;
  sort_order: number | null;
  currencies: string[] | null;
}

function paymentMethodFrom(rec: Record<string, Object>): PaymentMethod {
  const result: PaymentMethod = {
    code: strOr(rec, 'code', ''),
    name: strOr(rec, 'name', ''),
    description: strOrNull(rec, 'description'),
    enabled: boolOrNull(rec, 'enabled'),
    sort_order: numOrNull(rec, 'sort_order'),
    currencies: strListOrNull(rec, 'currencies'),
  };
  return result;
}

function paymentMethodListFrom(arr: Object[]): PaymentMethod[] {
  const out: PaymentMethod[] = [];
  for (let i = 0; i < arr.length; i++) {
    out.push(paymentMethodFrom(asRecord(arr[i])));
  }
  return out;
}

export interface SubscriptionModuleState {
  enabled: boolean; // 默认 true
}

function subscriptionModuleStateFrom(rec: Record<string, Object> | null): SubscriptionModuleState {
  const result: SubscriptionModuleState = {
    enabled: rec !== null ? boolOr(rec, 'enabled', true) : true,
  };
  return result;
}

export interface PaymentCurrentPlan {
  plan_code: string; // 默认 "free"
  plan_name?: string; // 后端本地化套餐名(catalog current_plan);优先展示
  plan_credits_total: number;
  plan_credits_used: number;
  plan_credits_remaining: number;
  paid: boolean;
  paid_topup_enabled: boolean;
  /** 当前套餐账期(如 "monthly"/"yearly"),旧后端无此字段时为 undefined。 */
  billing_cycle?: string;
}

function paymentCurrentPlanFrom(rec: Record<string, Object> | null): PaymentCurrentPlan {
  const r: Record<string, Object> = rec !== null ? rec : emptyRecord();
  const result: PaymentCurrentPlan = {
    plan_code: strOr(r, 'plan_code', 'free'),
    plan_credits_total: numOr(r, 'plan_credits_total', 0),
    plan_credits_used: numOr(r, 'plan_credits_used', 0),
    plan_credits_remaining: numOr(r, 'plan_credits_remaining', 0),
    paid: boolOr(r, 'paid', false),
    paid_topup_enabled: boolOr(r, 'paid_topup_enabled', false),
  };
  const billingCycle: string | null = strOrNull(r, 'billing_cycle');
  if (billingCycle !== null) {
    result.billing_cycle = billingCycle;
  }
  return result;
}

export interface PaymentBillingOption {
  cycle: string;
  product_code: string | null;
  price_cents: number;
  currency: string | null;
  payment_methods: PaymentMethod[] | null;
  duration_period: string | null;
  duration_count: number; // 默认 1
  // ==== 2026-07 月付→年付补差价升级规则新增字段(旧后端不下发时均为 undefined)====
  /** 实际应付金额(分),补差价升级时为补差价;展示价格优先取此值。 */
  payable_price_cents?: number;
  /** 结算方式:"full_price" 全额 | "prorated_difference" 补差价。 */
  settlement_mode?: string;
  /** 升级抵扣金额(分),即未使用部分折算的抵扣额。 */
  upgrade_credit_cents?: number;
  /** 服务端权威可购判定;undefined 表示旧后端,客户端沿用本地判定。 */
  purchasable?: boolean;
  /** 不可购原因:"duplicate_purchase" | "lower_tier" | "cycle_downgrade",可购时为 undefined。 */
  blocked_reason?: string;
}

function paymentBillingOptionFrom(rec: Record<string, Object>): PaymentBillingOption {
  const methodsArr = arrOrNull(rec, 'payment_methods');
  const result: PaymentBillingOption = {
    cycle: strOr(rec, 'cycle', ''),
    product_code: strOrNull(rec, 'product_code'),
    price_cents: numOr(rec, 'price_cents', 0),
    currency: strOrNull(rec, 'currency'),
    payment_methods: methodsArr !== null ? paymentMethodListFrom(methodsArr) : null,
    duration_period: strOrNull(rec, 'duration_period'),
    duration_count: numOr(rec, 'duration_count', 1),
  };
  // 新字段仅在服务端下发时写入,缺省保持 undefined 以区分旧后端。
  const payablePriceCents: number | null = numOrNull(rec, 'payable_price_cents');
  if (payablePriceCents !== null) {
    result.payable_price_cents = payablePriceCents;
  }
  const settlementMode: string | null = strOrNull(rec, 'settlement_mode');
  if (settlementMode !== null) {
    result.settlement_mode = settlementMode;
  }
  const upgradeCreditCents: number | null = numOrNull(rec, 'upgrade_credit_cents');
  if (upgradeCreditCents !== null) {
    result.upgrade_credit_cents = upgradeCreditCents;
  }
  const purchasable: boolean | null = boolOrNull(rec, 'purchasable');
  if (purchasable !== null) {
    result.purchasable = purchasable;
  }
  const blockedReason: string | null = strOrNull(rec, 'blocked_reason');
  if (blockedReason !== null) {
    result.blocked_reason = blockedReason;
  }
  return result;
}

export interface PaymentSubscriptionPlan {
  type: string; // 默认 "subscription"
  plan_code: string;
  name: string;
  credits: number;
  rank: number;
  billing_options: PaymentBillingOption[];
}

function paymentSubscriptionPlanFrom(rec: Record<string, Object>): PaymentSubscriptionPlan {
  const optionsArr = arrOr(rec, 'billing_options');
  const options: PaymentBillingOption[] = [];
  for (let i = 0; i < optionsArr.length; i++) {
    options.push(paymentBillingOptionFrom(asRecord(optionsArr[i])));
  }
  const result: PaymentSubscriptionPlan = {
    type: strOr(rec, 'type', 'subscription'),
    plan_code: strOr(rec, 'plan_code', ''),
    name: strOr(rec, 'name', ''),
    credits: numOr(rec, 'credits', 0),
    rank: numOr(rec, 'rank', 0),
    billing_options: options,
  };
  return result;
}

export interface PaymentCreditsTopup {
  type: string; // 默认 "credits_topup"
  provider: string;
  product_code: string | null;
  enabled: boolean;
  available: boolean;
  amount: number | null;
  price_cents: number | null;
  currency: string | null;
  payment_methods: PaymentMethod[] | null;
  blocked_reason: string | null;
}

function paymentCreditsTopupFrom(rec: Record<string, Object> | null): PaymentCreditsTopup {
  const r: Record<string, Object> = rec !== null ? rec : emptyRecord();
  const methodsArr = arrOrNull(r, 'payment_methods');
  const result: PaymentCreditsTopup = {
    type: strOr(r, 'type', 'credits_topup'),
    provider: strOr(r, 'provider', ''),
    product_code: strOrNull(r, 'product_code'),
    enabled: boolOr(r, 'enabled', false),
    available: boolOr(r, 'available', false),
    amount: numOrNull(r, 'amount'),
    price_cents: numOrNull(r, 'price_cents'),
    currency: strOrNull(r, 'currency'),
    payment_methods: methodsArr !== null ? paymentMethodListFrom(methodsArr) : null,
    blocked_reason: strOrNull(r, 'blocked_reason'),
  };
  return result;
}

export interface PaymentDiscount {
  supported: boolean; // 默认 true
  default_enabled: boolean; // 默认 false
}

function paymentDiscountFrom(rec: Record<string, Object> | null): PaymentDiscount {
  const r: Record<string, Object> = rec !== null ? rec : emptyRecord();
  const result: PaymentDiscount = {
    supported: boolOr(r, 'supported', true),
    default_enabled: boolOr(r, 'default_enabled', false),
  };
  return result;
}

export interface PaymentCatalogResponse {
  active_provider: string;
  providers: PaymentProvider[];
  payment_methods: PaymentMethod[];
  subscription_module: SubscriptionModuleState;
  current_plan: PaymentCurrentPlan;
  subscriptions: PaymentSubscriptionPlan[];
  credits_topup: PaymentCreditsTopup;
  discount: PaymentDiscount;
}

export function parsePaymentCatalogResponse(json: string): PaymentCatalogResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const providersArr = arrOr(rec, 'providers');
  const providers: PaymentProvider[] = [];
  for (let i = 0; i < providersArr.length; i++) {
    providers.push(paymentProviderFrom(asRecord(providersArr[i])));
  }
  const subsArr = arrOr(rec, 'subscriptions');
  const subscriptions: PaymentSubscriptionPlan[] = [];
  for (let i = 0; i < subsArr.length; i++) {
    subscriptions.push(paymentSubscriptionPlanFrom(asRecord(subsArr[i])));
  }
  const result: PaymentCatalogResponse = {
    active_provider: strOr(rec, 'active_provider', ''),
    providers: providers,
    payment_methods: paymentMethodListFrom(arrOr(rec, 'payment_methods')),
    subscription_module: subscriptionModuleStateFrom(recOrNull(rec, 'subscription_module')),
    current_plan: paymentCurrentPlanFrom(recOrNull(rec, 'current_plan')),
    subscriptions: subscriptions,
    credits_topup: paymentCreditsTopupFrom(recOrNull(rec, 'credits_topup')),
    discount: paymentDiscountFrom(recOrNull(rec, 'discount')),
  };
  return result;
}

export interface CreateSubscriptionCheckoutBody {
  plan_code: string;
  billing_cycle: string;
  auto_renew: boolean;
  provider: string;
  product_code: string;
  payment_method: string;
  currency: string;
  settlement_mode: string;
  discount_code: string;
}

export interface CreateCreditsTopupCheckoutBody {
  provider: string;
  product_code: string;
  payment_method: string;
  currency: string;
  discount_code: string;
}

export interface PaymentCheckoutResponse {
  provider: string;
  request_id: string | null;
  checkout_id: string | null;
  checkout_url: string;
  status: string | null;
}

export function parsePaymentCheckoutResponse(json: string): PaymentCheckoutResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const result: PaymentCheckoutResponse = {
    provider: strOr(rec, 'provider', ''),
    request_id: strOrNull(rec, 'request_id'),
    checkout_id: strOrNull(rec, 'checkout_id'),
    checkout_url: strOr(rec, 'checkout_url', ''),
    status: strOrNull(rec, 'status'),
  };
  return result;
}

// ==================== App启动配置 ====================

export interface AppStartupConfig {
  registration_enabled: boolean; // 默认 true
  invite_code_enabled: boolean; // 默认 true
  show_invite_codes_enabled: boolean; // 默认 false
  registration_limit_enabled: boolean; // 默认 false
  registration_limit_count: number; // 默认 1000
}

export function parseAppStartupConfig(json: string): AppStartupConfig {
  const rec = asRecord(JSON.parse(json) as object);
  const result: AppStartupConfig = {
    registration_enabled: boolOr(rec, 'registration_enabled', true),
    invite_code_enabled: boolOr(rec, 'invite_code_enabled', true),
    show_invite_codes_enabled: boolOr(rec, 'show_invite_codes_enabled', false),
    registration_limit_enabled: boolOr(rec, 'registration_limit_enabled', false),
    registration_limit_count: numOr(rec, 'registration_limit_count', 1000),
  };
  return result;
}

// ==================== 音频处理 ====================

/** 序列化值即枚举值(对应 Kotlin ActionType 的 @SerializedName)。 */
export enum ActionType {
  PASTE = 'paste',
  CLARIFY = 'clarify',
  SHOW_MARKDOWN = 'show_markdown',
  TIP = 'tip',
}

function actionTypeFrom(raw: string | null): ActionType {
  switch (raw) {
    case 'clarify':
      return ActionType.CLARIFY;
    case 'show_markdown':
      return ActionType.SHOW_MARKDOWN;
    case 'tip':
      return ActionType.TIP;
    default:
      return ActionType.PASTE;
  }
}

export interface ConfigUpdatePayload {
  max_duration_sec: number | null;
}

function configUpdatePayloadFrom(rec: Record<string, Object> | null): ConfigUpdatePayload | null {
  if (rec === null) {
    return null;
  }
  const result: ConfigUpdatePayload = {
    max_duration_sec: numOrNull(rec, 'max_duration_sec'),
  };
  return result;
}

export interface AudioProcessResponse {
  operation: string;
  action_type: ActionType; // 默认 PASTE
  transcript: string;
  result: string;
  model_provider: string | null;
  model_name: string | null;
  warning: string | null;
  config_update: ConfigUpdatePayload | null;
  clarify_question: string | null;
  credits_remaining: number | null;
}

export function parseAudioProcessResponse(json: string): AudioProcessResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const result: AudioProcessResponse = {
    operation: strOr(rec, 'operation', ''),
    action_type: actionTypeFrom(strOrNull(rec, 'action_type')),
    transcript: strOr(rec, 'transcript', ''),
    result: strOr(rec, 'result', ''),
    model_provider: strOrNull(rec, 'model_provider'),
    model_name: strOrNull(rec, 'model_name'),
    warning: strOrNull(rec, 'warning'),
    config_update: configUpdatePayloadFrom(recOrNull(rec, 'config_update')),
    clarify_question: strOrNull(rec, 'clarify_question'),
    credits_remaining: numOrNull(rec, 'credits_remaining'),
  };
  return result;
}

export interface TextProcessRequest {
  operation: string;
  text: string;
  client_asr_text?: string;
  asr_session_id?: string;
  selected_text?: string;
  clipboard_history?: string[];
  provider?: string;
  model?: string;
  fast_mode: boolean; // 默认 false
  transcript_language?: string;
}

/** 序列化值即枚举值(对应 Kotlin AndroidQuickAction 的 @SerializedName)。 */
export enum AndroidQuickAction {
  FORMAT = 'format',
  POLISH = 'polish',
  CONCISE = 'concise',
  BULLETS = 'bullets',
}

export interface AndroidQuickActionRequest {
  action: AndroidQuickAction;
  text: string;
  source_operation?: string;
}

export interface TextQuickActionResponse {
  operation: string;
  action_type: ActionType; // 默认 PASTE
  input_text: string;
  result: string;
  model_provider: string | null;
  model_name: string | null;
  credits_remaining: number | null;
  transcript: string | null;
}

export function parseTextQuickActionResponse(json: string): TextQuickActionResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const result: TextQuickActionResponse = {
    operation: strOr(rec, 'operation', ''),
    action_type: actionTypeFrom(strOrNull(rec, 'action_type')),
    input_text: strOr(rec, 'input_text', ''),
    result: strOr(rec, 'result', ''),
    model_provider: strOrNull(rec, 'model_provider'),
    model_name: strOrNull(rec, 'model_name'),
    credits_remaining: numOrNull(rec, 'credits_remaining'),
    transcript: strOrNull(rec, 'transcript'),
  };
  return result;
}

// ==================== 错误处理 ====================

export interface ApiErrorResponse {
  code: string;
  message: string;
  config_update: ConfigUpdatePayload | null;
}

export function parseApiErrorResponse(json: string): ApiErrorResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const result: ApiErrorResponse = {
    code: strOr(rec, 'code', ''),
    message: strOr(rec, 'message', ''),
    config_update: configUpdatePayloadFrom(recOrNull(rec, 'config_update')),
  };
  return result;
}

/** 对应 Kotlin sealed class ApiException 的各分支。 */
export enum ApiExceptionKind {
  HTTP_ERROR = 0,
  NETWORK_ERROR = 1,
  DECODING_ERROR = 2,
  UNAUTHORIZED = 3,
  USER_BANNED = 4,
  NOT_LOGGED_IN = 5,
}

/**
 * 对应 Kotlin sealed class ApiException。
 * 用 kind 区分子类型;message 为简体中文常量(与安卓一致),
 * 展示给用户前必须经 displayMessage() 做本地化映射。
 */
export class ApiException extends Error {
  readonly kind: ApiExceptionKind;
  readonly statusCode: number;
  readonly errorResponse: ApiErrorResponse | null;
  readonly causeError: Error | null;

  private constructor(
    kind: ApiExceptionKind,
    message: string,
    statusCode: number,
    errorResponse: ApiErrorResponse | null,
    causeError: Error | null
  ) {
    super(message);
    this.name = 'ApiException';
    this.kind = kind;
    this.statusCode = statusCode;
    this.errorResponse = errorResponse;
    this.causeError = causeError;
  }

  static httpError(statusCode: number, errorResponse: ApiErrorResponse | null): ApiException {
    // 与 Kotlin `errorResponse?.message ?: "未知错误"` 一致:仅 errorResponse 为 null 时才用兜底文案。
    const msg = errorResponse !== null ? errorResponse.message : '未知错误';
    return new ApiException(ApiExceptionKind.HTTP_ERROR, msg, statusCode, errorResponse, null);
  }

  static networkError(cause: Error): ApiException {
    return new ApiException(ApiExceptionKind.NETWORK_ERROR, '网络连接失败', 0, null, cause);
  }

  static decodingError(cause: Error): ApiException {
    return new ApiException(ApiExceptionKind.DECODING_ERROR, '数据解析失败', 0, null, cause);
  }

  static unauthorized(): ApiException {
    return new ApiException(ApiExceptionKind.UNAUTHORIZED, '登录已过期，请重新登录', 401, null, null);
  }

  static userBanned(): ApiException {
    return new ApiException(ApiExceptionKind.USER_BANNED, '账号已被禁用', 403, null, null);
  }

  static notLoggedIn(): ApiException {
    return new ApiException(ApiExceptionKind.NOT_LOGGED_IN, '请先登录', 0, null, null);
  }

  get errorCode(): string | null {
    if (this.kind === ApiExceptionKind.HTTP_ERROR && this.errorResponse !== null) {
      return this.errorResponse.code;
    }
    return null;
  }

  get configUpdate(): ConfigUpdatePayload | null {
    if (this.kind === ApiExceptionKind.HTTP_ERROR && this.errorResponse !== null) {
      return this.errorResponse.config_update;
    }
    return null;
  }

  get isCreditsExhausted(): boolean {
    return this.errorCode === 'CREDITS_EXHAUSTED';
  }

  get isNonRetryable(): boolean {
    return this.errorCode === 'DURATION_EXCEEDED';
  }
}

/**
 * 面向 UI 的本地化错误文案:异常自带的 message 是简体中文常量,不能直接展示。
 * 固定类型错误按当前语言映射;HttpError 优先服务端 message;未知异常回退调用方给的本地化 fallback。
 * (对应 Kotlin 的 Throwable.displayMessage 扩展函数,鸿蒙端无 Context 参数。)
 */
export function displayMessage(error: Error, fallback: string): string {
  if (error instanceof ApiException) {
    switch (error.kind) {
      case ApiExceptionKind.UNAUTHORIZED:
        return MobileStrings.sessionExpired();
      case ApiExceptionKind.NOT_LOGGED_IN:
        return MobileStrings.loginRequired();
      case ApiExceptionKind.USER_BANNED:
        return MobileStrings.userBanned();
      case ApiExceptionKind.NETWORK_ERROR:
        return MobileStrings.networkError();
      case ApiExceptionKind.DECODING_ERROR:
        return fallback;
      case ApiExceptionKind.HTTP_ERROR: {
        // 与 Kotlin `errorResponse?.message ?: fallback` 一致:仅 errorResponse 为 null 时才用 fallback。
        const code: string | null = error.errorResponse !== null ? error.errorResponse.code : null;
        const msg: string = error.errorResponse !== null ? error.errorResponse.message : fallback;
        return MobileStrings.apiErrorMessage(code, msg);
      }
      default:
        return error.message.length > 0 ? error.message : fallback;
    }
  }
  return error.message.length > 0 ? error.message : fallback;
}

// ==================== 录音配置 ====================

export interface RecordingConfigResponse {
  max_duration_sec: number;
}

export function parseRecordingConfigResponse(json: string): RecordingConfigResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const result: RecordingConfigResponse = {
    max_duration_sec: numOr(rec, 'max_duration_sec', 0),
  };
  return result;
}

// ==================== 词典（热词） ====================

export interface HotWordItem {
  id: string;
  word: string;
  created_at: string | null;
}

function hotWordItemFrom(rec: Record<string, Object>): HotWordItem {
  const result: HotWordItem = {
    id: strOr(rec, 'id', ''),
    word: strOr(rec, 'word', ''),
    created_at: strOrNull(rec, 'created_at'),
  };
  return result;
}

export function parseHotWordItem(json: string): HotWordItem {
  return hotWordItemFrom(asRecord(JSON.parse(json) as object));
}

export interface HotWordCreateBody {
  word: string;
}

export interface HotWordUpdateBody {
  word: string;
}

export interface HotWordListResponse {
  hotwords: HotWordItem[];
}

export function parseHotWordListResponse(json: string): HotWordListResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const arr = arrOr(rec, 'hotwords');
  const items: HotWordItem[] = [];
  for (let i = 0; i < arr.length; i++) {
    items.push(hotWordItemFrom(asRecord(arr[i])));
  }
  const result: HotWordListResponse = { hotwords: items };
  return result;
}

// ==================== 人设配置 ====================

export const PERSONA_PROMPT_MAX_LENGTH: number = 4000;
export const PERSONA_NAME_MAX_LENGTH: number = 60;
export const PERSONA_DESC_MAX_LENGTH: number = 200;
export const PERSONA_MAX_COUNT: number = 10;

export interface PersonaPrompts {
  transcribe_prompt: string | null;
  transcribe_enabled: boolean; // 默认 false
  rewrite_prompt: string | null;
  rewrite_enabled: boolean; // 默认 false
  intent_hint: string | null;
  intent_enabled: boolean; // 默认 false
}

/** 构造空 PersonaPrompts(等价 Kotlin PersonaPrompts() 全默认值)。 */
export function emptyPersonaPrompts(): PersonaPrompts {
  const result: PersonaPrompts = {
    transcribe_prompt: null,
    transcribe_enabled: false,
    rewrite_prompt: null,
    rewrite_enabled: false,
    intent_hint: null,
    intent_enabled: false,
  };
  return result;
}

function personaPromptsFrom(rec: Record<string, Object> | null): PersonaPrompts {
  if (rec === null) {
    return emptyPersonaPrompts();
  }
  const result: PersonaPrompts = {
    transcribe_prompt: strOrNull(rec, 'transcribe_prompt'),
    transcribe_enabled: boolOr(rec, 'transcribe_enabled', false),
    rewrite_prompt: strOrNull(rec, 'rewrite_prompt'),
    rewrite_enabled: boolOr(rec, 'rewrite_enabled', false),
    intent_hint: strOrNull(rec, 'intent_hint'),
    intent_enabled: boolOr(rec, 'intent_enabled', false),
  };
  return result;
}

export interface PersonaItem {
  id: string;
  name: string;
  description: string | null;
  is_active: boolean; // 默认 false
  is_builtin: boolean; // 默认 false
  prompts: PersonaPrompts;
}

function personaItemFrom(rec: Record<string, Object>): PersonaItem {
  const result: PersonaItem = {
    id: strOr(rec, 'id', ''),
    name: strOr(rec, 'name', ''),
    description: strOrNull(rec, 'description'),
    is_active: boolOr(rec, 'is_active', false),
    is_builtin: boolOr(rec, 'is_builtin', false),
    prompts: personaPromptsFrom(recOrNull(rec, 'prompts')),
  };
  return result;
}

export function parsePersonaItem(json: string): PersonaItem {
  return personaItemFrom(asRecord(JSON.parse(json) as object));
}

export interface PersonaListResponse {
  personas: PersonaItem[];
}

export function parsePersonaListResponse(json: string): PersonaListResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const arr = arrOr(rec, 'personas');
  const items: PersonaItem[] = [];
  for (let i = 0; i < arr.length; i++) {
    items.push(personaItemFrom(asRecord(arr[i])));
  }
  const result: PersonaListResponse = { personas: items };
  return result;
}

export interface PersonaCreateBody {
  name: string;
  description: string | null;
  prompts: PersonaPrompts;
}

export interface PersonaUpdateBody {
  name: string | null;
  description: string | null;
  prompts: PersonaPrompts | null;
}

// ==================== 协议 ====================

export interface AgreementItem {
  id: string;
  type: string;
  title: string;
  content: string;
  version: string;
}

function agreementItemFrom(rec: Record<string, Object>): AgreementItem {
  const result: AgreementItem = {
    id: strOr(rec, 'id', ''),
    type: strOr(rec, 'type', ''),
    title: strOr(rec, 'title', ''),
    content: strOr(rec, 'content', ''),
    version: strOr(rec, 'version', ''),
  };
  return result;
}

export interface AgreementsResponse {
  agreements: AgreementItem[];
}

export function parseAgreementsResponse(json: string): AgreementsResponse {
  const rec = asRecord(JSON.parse(json) as object);
  const arr = arrOr(rec, 'agreements');
  const items: AgreementItem[] = [];
  for (let i = 0; i < arr.length; i++) {
    items.push(agreementItemFrom(asRecord(arr[i])));
  }
  const result: AgreementsResponse = { agreements: items };
  return result;
}
