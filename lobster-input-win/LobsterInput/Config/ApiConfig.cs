namespace LobsterInput.Config;

public static class ApiConfig {
    public const string AppVariant = "standard";
    public const string Dev = "http://localhost:8000";
    // uat:公测环境(原 preview 常量改名而来)
    public const string Uat = "https://api.example.com/lobster";
    // preview:内测环境(新建,.cn 域名)
    public const string Preview = "https://api.example.net/lobster";
    // prod:未来正式环境,尚未部署,仅占位
    public const string Prod = "https://api.example.org/lobster";
    public static string Current =>
#if LOBSTER_UAT
        Uat;
#elif LOBSTER_PROD
        Prod;
#else
        Preview;
#endif

    // 当前激活环境名,徽章等 UI 展示必须由此派生,禁止写死
    public static string EnvName =>
#if LOBSTER_UAT
        "uat";
#elif LOBSTER_PROD
        "prod";
#else
        "preview";
#endif

    private static string V1 => $"{Current}/api/v1";
    private static string V2 => $"{Current}/api/v2";
    private static string WsV2
    {
        get
        {
            var current = Current.TrimEnd('/');
            if (current.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                return "wss://" + current["https://".Length..] + "/api/v2";
            if (current.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
                return "ws://" + current["http://".Length..] + "/api/v2";
            return current + "/api/v2";
        }
    }

    public static class Auth {
        public static string SendCode => $"{V1}/auth/send-code";
        public static string Verify => $"{V1}/auth/verify";
        public static string VerifyInvite => $"{V1}/auth/verify-invite";
        public static string InviteCodes => $"{V1}/auth/invite-codes";
        public static string Logout => $"{V1}/auth/logout";
    }

    public static class Audio {
        public static string Process => $"{V1}/audio/windows/process";
        public static string ProcessStream => $"{V1}/audio/windows/process/stream";
    }

    public static class AudioV2 {
        public static string ProcessText => $"{V2}/audio/windows/process";
        public static string ProcessTextStream => $"{V2}/audio/windows/process/stream";
        public static string RealtimeASR => $"{WsV2}/audio/windows/asr/realtime";
    }

    public static class Config {
        public static string Startup => $"{V1}/config/startup";
        public static string Plan => $"{V1}/config/plan";
        public static string Recording => $"{V1}/config/recording";
    }

    public static class Payments {
        public static string Catalog => $"{V1}/payments/catalog";
        public static string SubscriptionCheckout => $"{V1}/payments/subscription/checkout";
        public static string CreditsTopupCheckout => $"{V1}/payments/credits-topup/checkout";
    }

    public static class Subscription {
        public static string CancelRenewal => $"{V1}/subscription/cancel-renewal";
    }

    public static class HotWords {
        public static string List => $"{V1}/hotwords";
        public static string Item(string id) => $"{V1}/hotwords/{id}";
    }

    public static class Personas {
        public static string List => $"{V1}/personas";
        public static string Item(string id) => $"{V1}/personas/{id}";
        public static string Activate(string id) => $"{V1}/personas/{id}/activate";
        public static string DeactivateAll => $"{V1}/personas/deactivate-all";
    }

    public static class Logs {
        public static string Report => $"{V1}/logs/report";
    }

    public static class Feedback {
        public static string Submit => $"{V1}/feedback";
    }

    public static class Agreements {
        public static string Get => $"{V1}/agreements";
    }

    public static string Health => $"{Current}/health";

    public static class OpenClaw {
        public const string GatewayBase = "http://127.0.0.1:18789";
        public const string GatewayWs = "ws://127.0.0.1:18789";
    }

    public static class Update {
        // 新 R2 布局:<env>/<platform>,环境前缀在前
        private const string UatVelopackFeedUrl = "https://downloads.example.com/uat/windows";
        private const string PreviewVelopackFeedUrl = "https://downloads.example.com/preview/windows";
        // prod 未部署,仅占位
        private const string ProdVelopackFeedUrl = "https://downloads.example.com/prod/windows";

        public static string VelopackFeedUrl =>
#if LOBSTER_UAT
            UatVelopackFeedUrl;
#elif LOBSTER_PROD
            ProdVelopackFeedUrl;
#else
            PreviewVelopackFeedUrl;
#endif
    }
}
