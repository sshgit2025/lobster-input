// 移植自 Android: core/network/ApiConfig.kt
// 端点路径、key 名、超时与音频常量与安卓端逐项对齐。

// ==================== 环境配置 ====================
// 环境体系(与其它端统一):
// - dev     = http://localhost:8000/                      本地开发
// - uat     = https://api.example.com/lobster/      公测环境(原 "preview" 改名,.com 域名)
// - preview = https://api.example.net/lobster/       内测环境(.cn 域名)
// - prod    = 未来正式环境,尚未部署,仅占位
const BASE_URL_DEV: string = 'http://localhost:8000/';
const BASE_URL_UAT: string = 'https://api.example.com/lobster/';
const BASE_URL_PREVIEW: string = 'https://api.example.net/lobster/';
// prod 未来正式环境,尚未部署(占位,勿启用)
const BASE_URL_PROD: string = 'https://api.example.org/lobster/';

// R2 更新清单按环境隔离,两环境的包与清单绝不交叉
const FEED_URL_UAT: string = 'https://downloads.example.com/uat/harmony/update.json';
const FEED_URL_PREVIEW: string = 'https://downloads.example.com/preview/harmony/update.json';

/**
 * 当前激活环境:'preview'(内测)或 'uat'(公测正式版)。
 * 日常开发/内测默认 preview;发布时由 scripts/release.sh 用 sed 切换,勿改动本行格式。
 */
export const ACTIVE_ENV: string = 'preview';

function resolveBaseUrl(env: string): string {
  if (env === 'uat') {
    return BASE_URL_UAT;
  }
  if (env === 'dev') {
    return BASE_URL_DEV;
  }
  if (env === 'prod') {
    return BASE_URL_PROD;
  }
  return BASE_URL_PREVIEW;
}

function resolveFeedUrl(env: string): string {
  return env === 'uat' ? FEED_URL_UAT : FEED_URL_PREVIEW;
}

const API_VERSION: string = 'v1';
const API_VERSION_V2: string = 'v2';
const API_PREFIX: string = `api/${API_VERSION}`;
const API_PREFIX_V2: string = `api/${API_VERSION_V2}`;

/** 认证相关端点(对应 Kotlin ApiConfig.Auth) */
class AuthEndpoints {
  readonly SEND_CODE: string = `${API_PREFIX}/auth/send-code`;
  readonly VERIFY: string = `${API_PREFIX}/auth/verify`;
  readonly VERIFY_INVITE: string = `${API_PREFIX}/auth/verify-invite`;
  readonly INVITE_CODES: string = `${API_PREFIX}/auth/invite-codes`;
  readonly LOGOUT: string = `${API_PREFIX}/auth/logout`;
}

/** 配置端点(对应 Kotlin ApiConfig.Config) */
class ConfigEndpoints {
  readonly STARTUP: string = `${API_PREFIX}/config/startup`;
  readonly PLAN: string = `${API_PREFIX}/config/plan`;
  readonly RECORDING: string = `${API_PREFIX}/config/recording`;
}

/** 支付端点(对应 Kotlin ApiConfig.Payments) */
class PaymentsEndpoints {
  readonly CATALOG: string = `${API_PREFIX}/payments/catalog`;
  readonly SUBSCRIPTION_CHECKOUT: string = `${API_PREFIX}/payments/subscription/checkout`;
  readonly CREDITS_TOPUP_CHECKOUT: string = `${API_PREFIX}/payments/credits-topup/checkout`;
}

/** 订阅自动续费管理端点 */
class SubscriptionEndpoints {
  readonly CANCEL_RENEWAL: string = `${API_PREFIX}/subscription/cancel-renewal`;
}

/** 音频处理端点 v1(对应 Kotlin ApiConfig.Audio) */
class AudioEndpoints {
  readonly PROCESS: string = `${API_PREFIX}/audio/harmony/process`;
}

/** 音频处理端点 v2(对应 Kotlin ApiConfig.AudioV2) */
class AudioV2Endpoints {
  readonly PROCESS_TEXT: string = `${API_PREFIX_V2}/audio/harmony/process`;
  readonly REALTIME_ASR: string = `${API_PREFIX_V2}/audio/harmony/asr/realtime`;
}

/** 文本快捷操作端点(对应 Kotlin ApiConfig.Text) */
class TextEndpoints {
  readonly QUICK_ACTION: string = `${API_PREFIX}/text/harmony/quick-action`;
}

/** 更新检查(对应 Kotlin ApiConfig.Update);feed 按 ACTIVE_ENV 派生,不再复用 android 路径 */
class UpdateEndpoints {
  readonly FEED_URL: string = resolveFeedUrl(ACTIVE_ENV);
}

/** 热词端点(对应 Kotlin ApiConfig.HotWords) */
class HotWordsEndpoints {
  readonly LIST: string = `${API_PREFIX}/hotwords`;
  readonly ITEM: string = `${API_PREFIX}/hotwords/{id}`;
}

/** 人设端点(对应 Kotlin ApiConfig.Personas) */
class PersonasEndpoints {
  readonly LIST: string = `${API_PREFIX}/personas`;
  readonly ITEM: string = `${API_PREFIX}/personas/{id}`;
  readonly ACTIVATE: string = `${API_PREFIX}/personas/{id}/activate`;
  readonly DEACTIVATE_ALL: string = `${API_PREFIX}/personas/deactivate-all`;
}

/** 协议端点(对应 Kotlin ApiConfig.Agreements) */
class AgreementsEndpoints {
  readonly GET: string = `${API_PREFIX}/agreements`;
}

export class ApiConfig {
  /** 当前激活环境标识(uat/preview),UI 徽章等由它派生,禁止写死 */
  static readonly ENVIRONMENT: string = ACTIVE_ENV;
  // 后端API地址 - 由 ACTIVE_ENV 派生,切环境改顶部 ACTIVE_ENV
  static readonly BASE_URL: string = resolveBaseUrl(ACTIVE_ENV);

  // API版本
  static readonly API_VERSION: string = API_VERSION;
  static readonly API_VERSION_V2: string = API_VERSION_V2;
  // 2026-07 后端已支持 harmony 独立平台(中间件枚举/登录态/音频路由/quick-action):
  // 登录态按平台隔离(active_sessions.harmony),与安卓设备互不踢线;
  // /api/v*/audio/harmony/ 专属路径要求 X-Client-Platform=harmony,两者必须配套。
  static readonly CLIENT_PLATFORM: string = 'harmony';
  static readonly API_PREFIX: string = API_PREFIX;
  static readonly API_PREFIX_V2: string = API_PREFIX_V2;

  static readonly Auth: AuthEndpoints = new AuthEndpoints();
  static readonly Config: ConfigEndpoints = new ConfigEndpoints();
  static readonly Payments: PaymentsEndpoints = new PaymentsEndpoints();
  static readonly Subscription: SubscriptionEndpoints = new SubscriptionEndpoints();
  static readonly Audio: AudioEndpoints = new AudioEndpoints();
  static readonly AudioV2: AudioV2Endpoints = new AudioV2Endpoints();
  static readonly Text: TextEndpoints = new TextEndpoints();
  static readonly Update: UpdateEndpoints = new UpdateEndpoints();
  static readonly HotWords: HotWordsEndpoints = new HotWordsEndpoints();
  static readonly Personas: PersonasEndpoints = new PersonasEndpoints();
  static readonly Agreements: AgreementsEndpoints = new AgreementsEndpoints();

  // 超时配置(秒)
  static readonly CONNECT_TIMEOUT: number = 30;
  static readonly READ_TIMEOUT: number = 60;
  static readonly WRITE_TIMEOUT: number = 60;

  // Preferences 名称(对齐安卓 SharedPreferences 文件名)
  static readonly PREFS_NAME: string = 'lobster_input_prefs';
  // 旧版明文 token key(保留用于一次性迁移/降级存储)
  static readonly KEY_AUTH_TOKEN: string = 'auth_token';
  // 加密 token 的标记 key(鸿蒙端 token 明文存于 AssetStoreKit,此 key 存放存储位置标记)
  static readonly KEY_AUTH_TOKEN_ENC: string = 'auth_token_enc';
  static readonly KEY_USER_EMAIL: string = 'user_email';
  static readonly KEY_USER_TIER: string = 'user_tier';
  static readonly KEY_REALTIME_RECOGNITION: string = 'ime_realtime_recognition_enabled';
  // 验证码发送冷却:记录最近一次发码的邮箱与到期时间戳,退出 APP 重进仍可恢复倒计时
  static readonly KEY_SEND_CODE_EMAIL: string = 'send_code_email';
  static readonly KEY_SEND_CODE_EXPIRES_AT: string = 'send_code_expires_at';
  // 验证码发送冷却时长(秒),与后端 RESEND_COOLDOWN_SEC 保持一致
  static readonly SEND_CODE_COOLDOWN_SEC: number = 60;

  // 音频配置
  static readonly AUDIO_SAMPLE_RATE: number = 16000;
  static readonly AUDIO_CHANNEL: number = 1; // Mono
  static readonly AUDIO_BIT_DEPTH: number = 16;
  static readonly DEFAULT_MAX_DURATION_SEC: number = 60;

  /**
   * 由 BASE_URL 推导 WebSocket 地址(对齐安卓 RealtimeAsrWebSocketClient.buildUrl 的前缀逻辑):
   * 去掉末尾斜杠, https→wss / http→ws,再拼接相对路径。
   */
  static wsUrl(path: string): string {
    let base: string = ApiConfig.BASE_URL;
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.startsWith('https://')) {
      base = 'wss://' + base.substring('https://'.length);
    } else if (base.startsWith('http://')) {
      base = 'ws://' + base.substring('http://'.length);
    }
    let p: string = path;
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    return `${base}/${p}`;
  }
}
