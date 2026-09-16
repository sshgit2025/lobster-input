/// APIConfig.swift
/// 统一管理所有后端域名和 API 路径。
/// 修改接口地址或域名时，只需改动本文件，业务代码无需改动。
import Foundation

/// 应用环境
/// - dev: 本地开发
/// - uat: 公测环境（现网，原名 "preview"，域名 example.com），客户端徽章显示"正式版"
/// - preview: 内测环境（新建，域名 example.net），客户端徽章显示"内测版"
/// - prod: 未来正式环境，尚未部署（占位）
enum AppEnvironment {
    case dev, uat, preview, prod
}

enum APIConfig {

    // MARK: - 当前激活环境
    // 日常开发/内测默认 preview；发布 uat 包时按发布文档
    // （docs/release/sparkle-build-guide-uat.md）切换为 .uat，
    // 并同步修改 Info.plist 的 SUFeedURL。
    static let environment: AppEnvironment = .preview

    // MARK: - App 变体标识
    // 后端通过请求头 X-App-Variant 区分请求来源是哪个客户端分支
    // standard = 标准版，diy = DIY 定制版
    static let appVariant = "standard"

    // MARK: - 域名配置
    // 切换环境只需修改上方 environment，current 自动派生

    /// 本地开发环境
    static let dev     = "http://localhost:8000"
    /// 公测环境（现网，原 "preview"）
    static let uat     = "https://api.example.com/lobster"
    /// 内测环境（新建）
    static let preview = "https://api.example.net/lobster"
    /// 未来正式环境，尚未部署（占位符，勿用）
    static let prod    = "https://api.example.org/lobster"

    /// 当前生效的 host（由 environment 派生，业务代码继续引用 current 即可）
    static let current: String = {
        switch environment {
        case .dev:     return dev
        case .uat:     return uat
        case .preview: return preview
        case .prod:    return prod
        }
    }()

    // MARK: - Sparkle 自动更新 appcast
    // 每个变体维护独立的 appcast.xml，互不影响升级节奏。
    // 注意：Sparkle 运行时实际读取的是 Info.plist 的 SUFeedURL，
    // 此常量按环境派生，供代码/文档对照，两处必须保持一致。
    enum Sparkle {
        private static let r2Public = "https://downloads.example.com"

        static let appcastURL: String? = {
            switch environment {
            case .dev:     return nil                                             // 开发构建不走在线更新
            case .uat:     return "\(r2Public)/uat/mac/appcast-standard.xml"      // 公测通道
            case .preview: return "\(r2Public)/preview/mac/appcast-standard.xml"  // 内测通道
            case .prod:    return nil                                             // 未部署，占位
            }
        }()
    }

    /// v1 前缀
    private static let v1 = "\(current)/api/v1"
    /// v2 前缀：实时 ASR 最终文本业务处理
    private static let v2 = "\(current)/api/v2"
    private static let wsV2: String = {
        if current.hasPrefix("https://") {
            return "wss://" + String(current.dropFirst("https://".count)) + "/api/v2"
        }
        if current.hasPrefix("http://") {
            return "ws://" + String(current.dropFirst("http://".count)) + "/api/v2"
        }
        return current + "/api/v2"
    }()

    // MARK: - Auth
    enum Auth {
        static let sendCode     = "\(v1)/auth/send-code"
        static let verify       = "\(v1)/auth/verify"
        static let verifyInvite = "\(v1)/auth/verify-invite"
        static let inviteCodes  = "\(v1)/auth/invite-codes"
        static let logout       = "\(v1)/auth/logout"
    }

    // MARK: - Audio
    enum Audio {
        static let process = "\(v1)/audio/mac/process"
        static let processStream = "\(v1)/audio/mac/process/stream"
    }

    // MARK: - Audio v2
    enum AudioV2 {
        static let processText = "\(v2)/audio/mac/process"
        static let processTextStream = "\(v2)/audio/mac/process/stream"
        static let realtimeASR = "\(wsV2)/audio/mac/asr/realtime"
    }

    // MARK: - Config
    enum Config {
        static let startup   = "\(v1)/config/startup"
        static let plan      = "\(v1)/config/plan"
        static let recording = "\(v1)/config/recording"
    }

    // MARK: - Payments
    enum Payments {
        static let catalog = "\(v1)/payments/catalog"
        static let subscriptionCheckout = "\(v1)/payments/subscription/checkout"
        static let creditsTopupCheckout = "\(v1)/payments/credits-topup/checkout"
    }

    // MARK: - Subscription（订阅管理）
    enum Subscription {
        static let cancelRenewal = "\(v1)/subscription/cancel-renewal"
    }

    // MARK: - HotWords（词典）
    enum HotWords {
        static let list = "\(v1)/hotwords"
        static func item(_ id: String) -> String { "\(v1)/hotwords/\(id)" }
    }

    // MARK: - Personas（人设）
    enum Personas {
        static let list              = "\(v1)/personas"
        static func item(_ id: String)     -> String { "\(v1)/personas/\(id)" }
        static func activate(_ id: String) -> String { "\(v1)/personas/\(id)/activate" }
        static let deactivateAll     = "\(v1)/personas/deactivate-all"
    }

    // MARK: - Logs（客户端日志上报）
    enum Logs {
        static let report = "\(v1)/logs/report"
    }

    // MARK: - Feedback（用户反馈）
    enum Feedback {
        static let submit = "\(v1)/feedback"
    }

    // MARK: - Agreements（用户协议 / 隐私政策）
    enum Agreements {
        static let get = "\(v1)/agreements"
    }

    // MARK: - Health
    static let health = "\(current)/health"

    // MARK: - OpenClaw 本地 Gateway
    // OpenClaw 是运行在用户本机的本地 Gateway 服务，地址固定为 127.0.0.1
    enum OpenClaw {
        static let gatewayBase      = "http://127.0.0.1:18789"
        static let gatewayWS        = "ws://127.0.0.1:18789"
    }
}
