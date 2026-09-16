using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Models;

namespace LobsterInput.Stores;

public sealed partial class AuthStore : ObservableObject
{
    private static readonly string SettingsDir = AppPaths.AppDataDir;

    private static readonly string SettingsPath =
        Path.Combine(SettingsDir, "settings.json");

    public static AuthStore Instance { get; } = new();

    [ObservableProperty]
    private string? _token;

    [ObservableProperty]
    private string? _email;

    [ObservableProperty]
    private string _tier = "trial";

    // 后端本地化套餐展示名（按 X-Accept-Language 返回）；为空回退本地翻译
    [ObservableProperty]
    private string _planName = "";

    [ObservableProperty]
    private int _creditsTotal;

    [ObservableProperty]
    private int _creditsUsed;

    [ObservableProperty]
    private int _creditsRemaining;

    [ObservableProperty]
    private List<CreditBalanceItem> _creditItems = new();

    [ObservableProperty]
    private string? _creditsResetAt;

    [ObservableProperty]
    private bool _inviteCodeEnabled;

    [ObservableProperty]
    private bool _registrationEnabled = true;

    [ObservableProperty]
    private bool _showInviteCodesEnabled;

    [ObservableProperty]
    private bool _showSubscriptionModuleEnabled = true;

    [ObservableProperty]
    private string? _pendingInviteEmail;

    public bool IsLoggedIn => Token is not null;

    private AuthStore()
    {
        Load();
    }

    public string? FormattedResetDate(CultureInfo? culture = null)
    {
        if (CreditsResetAt is null)
            return null;

        if (!DateTime.TryParse(CreditsResetAt,
                CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind,
                out var date))
            return null;

        var ci = culture ?? CultureInfo.CurrentCulture;
        return date.ToString("d", ci);
    }

    public void Save(AuthResponse response)
    {
        Email = string.IsNullOrEmpty(response.Email) ? null : response.Email;
        Tier = string.IsNullOrEmpty(response.Tier) ? "trial" : response.Tier;
        Token = string.IsNullOrEmpty(response.Token) ? null : response.Token;
        OnPropertyChanged(nameof(IsLoggedIn));
        Persist();
    }

    public void UpdatePlanInfo(UserPlanInfo info)
    {
        CreditsTotal = info.CreditsTotal;
        CreditsUsed = info.CreditsUsed;
        CreditsRemaining = info.CreditsRemaining;
        CreditItems = info.CreditItems;
        CreditsResetAt = info.CreditsResetAt;
        RegistrationEnabled = info.RegistrationEnabled;
        InviteCodeEnabled = info.InviteCodeEnabled;
        ShowInviteCodesEnabled = info.ShowInviteCodesEnabled;
        ShowSubscriptionModuleEnabled = info.ShowSubscriptionModuleEnabled;
        if (!string.IsNullOrEmpty(info.Tier))
            Tier = info.Tier;
        PlanName = info.PlanName;
        Persist();
    }

    public void UpdateStartupConfig(AppStartupConfig config)
    {
        RegistrationEnabled = config.RegistrationEnabled;
        InviteCodeEnabled = config.InviteCodeEnabled;
        ShowInviteCodesEnabled = config.ShowInviteCodesEnabled;
        ShowSubscriptionModuleEnabled = config.ShowSubscriptionModuleEnabled;
        Persist();
    }

    public void Logout()
    {
        Token = null;
        Email = null;
        Tier = "trial";
        CreditsTotal = 0;
        CreditsUsed = 0;
        CreditsRemaining = 0;
        CreditItems = new List<CreditBalanceItem>();
        CreditsResetAt = null;
        PendingInviteEmail = null;
        OnPropertyChanged(nameof(IsLoggedIn));
        Persist();
    }

    public void ClearPendingInvite()
    {
        PendingInviteEmail = null;
    }

    // ── Persistence via JSON file ──

    private void Load()
    {
        if (!File.Exists(SettingsPath))
            return;

        try
        {
            var json = File.ReadAllText(SettingsPath);
            var data = JsonSerializer.Deserialize<PersistedData>(json);
            if (data is null) return;

            Token = ProtectedDataHelper.Unprotect(data.Token);
            Email = data.Email;
            Tier = data.Tier ?? "trial";
            PlanName = data.PlanName ?? "";
            CreditsTotal = data.CreditsTotal;
            CreditsUsed = data.CreditsUsed;
            CreditsRemaining = data.CreditsRemaining;
            CreditItems = data.CreditItems ?? new List<CreditBalanceItem>();
            CreditsResetAt = data.CreditsResetAt;
            RegistrationEnabled = data.RegistrationEnabled;
            InviteCodeEnabled = data.InviteCodeEnabled;
            ShowInviteCodesEnabled = data.ShowInviteCodesEnabled;
            ShowSubscriptionModuleEnabled = data.ShowSubscriptionModuleEnabled;
        }
        catch
        {
            // corrupted file; start fresh
        }
    }

    private void Persist()
    {
        try
        {
            Directory.CreateDirectory(SettingsDir);

            var data = new PersistedData
            {
                Token = ProtectedDataHelper.Protect(Token),
                Email = Email,
                Tier = Tier,
                PlanName = PlanName,
                CreditsTotal = CreditsTotal,
                CreditsUsed = CreditsUsed,
                CreditsRemaining = CreditsRemaining,
                CreditItems = CreditItems,
                CreditsResetAt = CreditsResetAt,
                RegistrationEnabled = RegistrationEnabled,
                InviteCodeEnabled = InviteCodeEnabled,
                ShowInviteCodesEnabled = ShowInviteCodesEnabled,
                ShowSubscriptionModuleEnabled = ShowSubscriptionModuleEnabled,
            };

            var json = JsonSerializer.Serialize(data, new JsonSerializerOptions
            {
                WriteIndented = true
            });
            File.WriteAllText(SettingsPath, json);
        }
        catch
        {
            // best-effort persistence
        }
    }

    private class PersistedData
    {
        public string? Token { get; set; }
        public string? Email { get; set; }
        public string? Tier { get; set; }
        public string? PlanName { get; set; }
        public int CreditsTotal { get; set; }
        public int CreditsUsed { get; set; }
        public int CreditsRemaining { get; set; }
        public List<CreditBalanceItem>? CreditItems { get; set; }
        public string? CreditsResetAt { get; set; }
        public bool RegistrationEnabled { get; set; } = true;
        public bool InviteCodeEnabled { get; set; }
        public bool ShowInviteCodesEnabled { get; set; }
        public bool ShowSubscriptionModuleEnabled { get; set; } = true;
    }

    // ── DPAPI 加密助手（仅用于落盘凭证加密；内存中 Token 始终明文）──
    private static class ProtectedDataHelper
    {
        // 明文 → DPAPI(CurrentUser) → Base64。空值原样返回。
        public static string? Protect(string? plainText)
        {
            if (string.IsNullOrEmpty(plainText))
                return plainText;

            try
            {
                var bytes = Encoding.UTF8.GetBytes(plainText);
                var encrypted = ProtectedData.Protect(
                    bytes,
                    optionalEntropy: null,
                    DataProtectionScope.CurrentUser);
                return Convert.ToBase64String(encrypted);
            }
            catch
            {
                // 加密失败：不落明文，返回 null（下次启动视为登出，重新登录即可）。
                return null;
            }
        }

        // Base64 → DPAPI(CurrentUser) 解密 → 明文。
        public static string? Unprotect(string? storedValue)
        {
            if (string.IsNullOrEmpty(storedValue))
                return null;

            try
            {
                var encrypted = Convert.FromBase64String(storedValue);
                var bytes = ProtectedData.Unprotect(
                    encrypted,
                    optionalEntropy: null,
                    DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(bytes);
            }
            catch
            {
                // 从未上线、测试版：不兼容旧明文，解密/Base64 失败即视为登出（返回 null），
                // 换机/换用户致密钥不可用同样降级为重新登录，不崩溃。
                return null;
            }
        }
    }
}
