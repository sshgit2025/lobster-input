using System.Globalization;
using System.IO;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;

namespace LobsterInput.Helpers;

public enum AppLanguage
{
    Zh,
    ZhHant,
    Yue,
    En,
    Ru,
    Ko
}

public sealed partial class LanguageManager : ObservableObject
{
    private static readonly string SettingsPath = Path.Combine(
        AppPaths.AppDataDir, "language.json");

    public static LanguageManager Instance { get; } = new();

    [ObservableProperty]
    private AppLanguage _current;

    private LanguageManager()
    {
        string? saved = null;
        try
        {
            if (File.Exists(SettingsPath))
                saved = File.ReadAllText(SettingsPath).Trim().Trim('"');
        }
        catch { /* ignore */ }

        if (!string.IsNullOrEmpty(saved) && TryParseCode(saved, out var lang))
        {
            _current = lang;
        }
        else
        {
            _current = DetectSystemLanguage();
            SaveLanguage(_current);
        }
    }

    partial void OnCurrentChanged(AppLanguage value)
    {
        SaveLanguage(value);
    }

    private static void SaveLanguage(AppLanguage lang)
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(GetLanguageCode(lang)));
        }
        catch { /* best-effort */ }
    }

    public static string GetLanguageCode(AppLanguage lang) => lang switch
    {
        AppLanguage.Zh => "zh",
        AppLanguage.ZhHant => "zh-Hant",
        AppLanguage.Yue => "yue",
        AppLanguage.En => "en",
        AppLanguage.Ru => "ru",
        AppLanguage.Ko => "ko",
        _ => "en"
    };

    public static string GetDisplayName(AppLanguage lang) => lang switch
    {
        AppLanguage.Zh => "\u7b80\u4f53\u4e2d\u6587",
        AppLanguage.ZhHant => "\u7e41\u9ad4\u4e2d\u6587",
        AppLanguage.Yue => "\u7cb5\u8a9e\uff08\u5ee3\u6771\u7701\u7248\uff09",
        AppLanguage.En => "English",
        AppLanguage.Ru => "\u0420\u0443\u0441\u0441\u043a\u0438\u0439",
        AppLanguage.Ko => "\ud55c\uad6d\uc5b4",
        _ => "English"
    };

    private static bool TryParseCode(string code, out AppLanguage lang)
    {
        switch (code)
        {
            case "zh": lang = AppLanguage.Zh; return true;
            case "zh-Hant": lang = AppLanguage.ZhHant; return true;
            case "yue": lang = AppLanguage.Yue; return true;
            case "en": lang = AppLanguage.En; return true;
            case "ru": lang = AppLanguage.Ru; return true;
            case "ko": lang = AppLanguage.Ko; return true;
            default: lang = AppLanguage.En; return false;
        }
    }

    private static AppLanguage DetectSystemLanguage()
    {
        var culture = CultureInfo.CurrentUICulture;
        var name = culture.Name.ToLowerInvariant();

        if (name.StartsWith("yue")) return AppLanguage.Yue;
        if (name.StartsWith("zh-hant") || name.StartsWith("zh-tw")) return AppLanguage.ZhHant;
        if (name.StartsWith("zh-hk") || name.StartsWith("zh-mo")) return AppLanguage.Yue;
        if (name.StartsWith("zh")) return AppLanguage.Zh;
        if (name.StartsWith("ko")) return AppLanguage.Ko;
        if (name.StartsWith("ru")) return AppLanguage.Ru;
        if (name.StartsWith("en")) return AppLanguage.En;

        return AppLanguage.En;
    }
}
