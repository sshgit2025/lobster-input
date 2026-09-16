import Foundation

enum APIConfig {

    /// 部署环境标识。
    /// - dev: 本地开发环境
    /// - uat: 公测环境(原 "preview" 改名,.com 域名)
    /// - preview: 内测环境(.cn 域名)
    /// - prod: 未来正式环境,尚未部署,仅占位
    enum Environment {
        case dev
        case uat
        case preview
        case prod

        var baseURL: String {
            switch self {
            case .dev: return APIConfig.dev
            case .uat: return APIConfig.uat
            case .preview: return APIConfig.preview
            case .prod: return APIConfig.prod
            }
        }
    }

    static let dev = "http://localhost:8000"
    /// uat 公测环境(原 preview 常量改名,api.example.com)
    static let uat = "https://api.example.com/lobster"
    /// preview 内测环境(api.example.net)
    static let preview = "https://api.example.net/lobster"
    /// prod 未来正式环境,尚未部署(占位)
    static let prod = "https://api.example.org/lobster"

    /// 当前激活环境:日常开发/内测默认 .preview;发 uat(公测正式版)包前必须改为 .uat。
    static let environment: Environment = .preview
    /// 当前环境 Base URL(由 environment 派生,所有端点引用它,勿直接改这里)
    static let current = environment.baseURL

    static let clientPlatform = "ios"

    /// App Group 标识符，用于主 App 与键盘扩展共享数据
    static let appGroupID = "group.ssh2026.lobster-input"

    private static let v1 = "\(current)/api/v1"
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

    enum Auth {
        static let sendCode     = "\(v1)/auth/send-code"
        static let verify       = "\(v1)/auth/verify"
        static let verifyInvite = "\(v1)/auth/verify-invite"
        static let inviteCodes  = "\(v1)/auth/invite-codes"
        static let logout       = "\(v1)/auth/logout"
    }

    enum Audio {
        static let process = "\(v1)/audio/ios/process"
    }

    enum AudioV2 {
        static let processText = "\(v2)/audio/ios/process"
        static let realtimeASR = "\(wsV2)/audio/ios/asr/realtime"
    }

    enum Text {
        // The backend currently exposes one shared mobile quick-action route under
        // the Android path; it accepts X-Client-Platform=ios through middleware.
        static let quickAction = "\(v1)/text/android/quick-action"
    }

    enum Config {
        static let startup   = "\(v1)/config/startup"
        static let plan      = "\(v1)/config/plan"
        static let recording = "\(v1)/config/recording"
    }

    enum HotWords {
        static let list = "\(v1)/hotwords"
        static func item(_ id: String) -> String { "\(v1)/hotwords/\(id)" }
    }

    enum Personas {
        static let list = "\(v1)/personas"
        static func item(_ id: String) -> String { "\(v1)/personas/\(id)" }
        static func activate(_ id: String) -> String { "\(v1)/personas/\(id)/activate" }
        static let deactivateAll = "\(v1)/personas/deactivate-all"
    }

    enum Subscription {
        static let cancelRenewal = "\(v1)/subscription/cancel-renewal"
    }

    enum Payments {
        static let appleProducts = "\(v1)/payments/apple/products"
        static let appleVerify   = "\(v1)/payments/apple/verify"
        static let appleRestore  = "\(v1)/payments/apple/restore"
    }

    enum Logs {
        static let report = "\(v1)/logs/report"
    }

    enum Agreements {
        static let get = "\(v1)/agreements"
    }

    static let health = "\(current)/health"
}
