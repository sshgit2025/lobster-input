package com.lobster.input.core.network

import com.lobster.input.BuildConfig

object ApiConfig {
    // 后端API地址 - 由构建 flavor(productFlavors "env")注入:
    //   uat(公测环境)   -> https://api.example.com/lobster/
    //   preview(内测环境)-> https://api.example.net/lobster/
    //   prod             -> 未来正式环境,尚未部署(占位,暂未建 flavor)
    val BASE_URL: String = BuildConfig.BASE_URL

    // 开发环境可以使用本地地址
    // val BASE_URL = "http://10.0.2.2:8000/"  // Android模拟器访问本机
    // val BASE_URL = "http://192.168.1.100:8000/"  // 真机访问局域网
    
    // API版本
    const val API_VERSION = "v1"
    const val API_VERSION_V2 = "v2"
    const val CLIENT_PLATFORM = "android"
    const val API_PREFIX = "api/$API_VERSION"
    const val API_PREFIX_V2 = "api/$API_VERSION_V2"
    
    object Auth {
        const val SEND_CODE = "$API_PREFIX/auth/send-code"
        const val VERIFY = "$API_PREFIX/auth/verify"
        const val VERIFY_INVITE = "$API_PREFIX/auth/verify-invite"
        const val INVITE_CODES = "$API_PREFIX/auth/invite-codes"
        const val LOGOUT = "$API_PREFIX/auth/logout"
    }
    
    object Config {
        const val STARTUP = "$API_PREFIX/config/startup"
        const val PLAN = "$API_PREFIX/config/plan"
        const val RECORDING = "$API_PREFIX/config/recording"
    }

    object Payments {
        const val CATALOG = "$API_PREFIX/payments/catalog"
        const val SUBSCRIPTION_CHECKOUT = "$API_PREFIX/payments/subscription/checkout"
        const val CREDITS_TOPUP_CHECKOUT = "$API_PREFIX/payments/credits-topup/checkout"
    }

    object Subscription {
        const val CANCEL_RENEWAL = "$API_PREFIX/subscription/cancel-renewal"
    }
    
    object Audio {
        const val PROCESS = "$API_PREFIX/audio/android/process"
    }

    object AudioV2 {
        const val PROCESS_TEXT = "$API_PREFIX_V2/audio/android/process"
        const val REALTIME_ASR = "$API_PREFIX_V2/audio/android/asr/realtime"
    }

    object Text {
        const val QUICK_ACTION = "$API_PREFIX/text/android/quick-action"
    }

    object Update {
        // 在线更新清单地址 - 由构建 flavor 注入(uat/android/ 或 preview/android/)。
        // 旧路径 android/preview/update.json 仅作为老用户迁移桥,由发布脚本镜像 uat 内容。
        val FEED_URL: String = BuildConfig.UPDATE_FEED_URL
    }
    
    object HotWords {
        const val LIST = "$API_PREFIX/hotwords"
        const val ITEM = "$API_PREFIX/hotwords/{id}"
    }
    
    object Personas {
        const val LIST = "$API_PREFIX/personas"
        const val ITEM = "$API_PREFIX/personas/{id}"
        const val ACTIVATE = "$API_PREFIX/personas/{id}/activate"
        const val DEACTIVATE_ALL = "$API_PREFIX/personas/deactivate-all"
    }
    
    object Agreements {
        const val GET = "$API_PREFIX/agreements"
    }
    
    // 超时配置（秒）
    const val CONNECT_TIMEOUT = 30L
    const val READ_TIMEOUT = 60L
    const val WRITE_TIMEOUT = 60L
    
    // SharedPreferences名称
    const val PREFS_NAME = "lobster_input_prefs"
    // 旧版明文 token key（保留用于一次性迁移到加密存储）
    const val KEY_AUTH_TOKEN = "auth_token"
    // 加密后的 token key（Keystore AES/GCM 密文，Base64，含 IV）
    const val KEY_AUTH_TOKEN_ENC = "auth_token_enc"
    const val KEY_USER_EMAIL = "user_email"
    const val KEY_USER_TIER = "user_tier"
    const val KEY_REALTIME_RECOGNITION = "ime_realtime_recognition_enabled"
    // 验证码发送冷却：记录最近一次发码的邮箱与到期时间戳，退出 APP 重进仍可恢复倒计时
    const val KEY_SEND_CODE_EMAIL = "send_code_email"
    const val KEY_SEND_CODE_EXPIRES_AT = "send_code_expires_at"
    // 验证码发送冷却时长（秒），与后端 RESEND_COOLDOWN_SEC 保持一致
    const val SEND_CODE_COOLDOWN_SEC = 60
    
    // 音频配置
    const val AUDIO_SAMPLE_RATE = 16000
    const val AUDIO_CHANNEL = 1  // Mono
    const val AUDIO_BIT_DEPTH = 16
    const val DEFAULT_MAX_DURATION_SEC = 60
}
