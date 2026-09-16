using System.ComponentModel;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace LobsterInput.Services;

public enum AppThemeMode
{
    SandLight,
    SandDark
}

public enum AppTheme
{
    Light,
    Dark
}

public enum AppAccent
{
    Sand,
    Mono,
    Blue,
    Orange,
    Red,
    Green,
    Purple
}

public sealed class ThemeManager : INotifyPropertyChanged
{
    private static readonly string DefaultSettingsPath = Path.Combine(
        AppPaths.AppDataDir, "theme.json");

    public static ThemeManager Instance { get; } = new(DefaultSettingsPath);

    private readonly string _settingsPath;
    private AppTheme _theme;
    private AppAccent _accent;

    public event PropertyChangedEventHandler? PropertyChanged;

    public AppThemeMode Mode
    {
        get => _theme == AppTheme.Dark ? AppThemeMode.SandDark : AppThemeMode.SandLight;
        set
        {
            var targetTheme = value == AppThemeMode.SandDark ? AppTheme.Dark : AppTheme.Light;
            SetThemeAccent(targetTheme, _accent, raiseThemeAndAccent: true);
        }
    }

    public AppTheme Theme
    {
        get => _theme;
        set => SetThemeAccent(value, _accent);
    }

    public AppAccent Accent
    {
        get => _accent;
        set => SetThemeAccent(_theme, value);
    }

    private ThemeManager()
        : this(DefaultSettingsPath)
    {
    }

    internal ThemeManager(string settingsPath)
    {
        _settingsPath = settingsPath;
        var loaded = Load(settingsPath);
        _theme = loaded.Theme;
        _accent = loaded.Accent;

        if (loaded.MigratedFromLegacy)
            Save();
    }

    public void Toggle()
    {
        Mode = Mode == AppThemeMode.SandLight ? AppThemeMode.SandDark : AppThemeMode.SandLight;
    }

    public void ApplyCurrentTheme()
    {
        var resources = Application.Current?.Resources;
        if (resources == null) return;

        var palette = AccentPalette.For(Theme, Accent);
        var neutral = AccentPalette.NeutralFor(Theme, Accent);
        var state = AccentPalette.StateFor(Theme);
        var shadows = AccentPalette.ShadowsFor(Theme);

        ApplyDesignTokens(resources, neutral, state, palette, shadows);
        ApplyLegacyAliases(resources, neutral, state, palette);

        SetLinearGradient(resources, "BgGradientBrush", neutral.Bg, neutral.Bg);
        SetLinearGradient(resources, "SidebarGradientBrush", neutral.BgSunken, neutral.BgSunken);
        SetLinearGradient(resources, "ActiveTabBgBrush", neutral.BgActive, neutral.BgActive);
        SetLinearGradient(resources, "NeonGreenGradient", palette.Accent, palette.Accent);
        SetLinearGradient(
            resources,
            "SidebarDividerBrush",
            Transparent(neutral.LineStrong),
            neutral.LineStrong,
            Transparent(neutral.LineStrong));
    }

    private void SetThemeAccent(AppTheme theme, AppAccent accent, bool raiseThemeAndAccent = false)
    {
        var oldTheme = _theme;
        var oldAccent = _accent;

        if (oldTheme == theme && oldAccent == accent)
            return;

        _theme = theme;
        _accent = accent;

        Save();
        ApplyCurrentTheme();

        if (raiseThemeAndAccent || oldTheme != _theme)
            OnPropertyChanged(nameof(Theme));
        if (raiseThemeAndAccent || oldAccent != _accent)
            OnPropertyChanged(nameof(Accent));

        OnPropertyChanged(nameof(Mode));
    }

    private static void ApplyDesignTokens(
        ResourceDictionary resources,
        NeutralPalette neutral,
        StatePalette state,
        AccentPalette palette,
        ShadowPalette shadows)
    {
        SetColorBrushPair(resources, "DsBg", neutral.Bg);
        SetColorBrushPair(resources, "DsBgElev", neutral.BgElev);
        SetColorBrushPair(resources, "DsBgSunken", neutral.BgSunken);
        SetColorBrushPair(resources, "DsBgHover", neutral.BgHover);
        SetColorBrushPair(resources, "DsBgActive", neutral.BgActive);
        SetColorBrushPair(resources, "DsLine", neutral.Line);
        SetColorBrushPair(resources, "DsLineStrong", neutral.LineStrong);
        SetColorBrushPair(resources, "DsFg", neutral.Fg);
        SetColorBrushPair(resources, "DsFgMuted", neutral.FgMuted);
        SetColorBrushPair(resources, "DsFgSubtle", neutral.FgSubtle);
        SetColorBrushPair(resources, "DsFgFaint", neutral.FgFaint);

        SetColorBrushPair(resources, "DsAccent", palette.Accent);
        SetColorBrushPair(resources, "DsAccentSoft", palette.AccentSoft);
        SetColorBrushPair(resources, "DsAccentFg", palette.AccentFg);
        SetColorBrushPair(resources, "DsAccentRing", palette.AccentRing);

        SetColorBrushPair(resources, "DsSuccess", state.Success);
        SetColorBrushPair(resources, "DsWarning", state.Warning);
        SetColorBrushPair(resources, "DsDanger", state.Danger);
        SetColorBrushPair(resources, "DsDangerSoft", WithAlpha(state.Danger, 0x0F));
        SetColorBrushPair(resources, "DsDangerRing", WithAlpha(state.Danger, 0x33));
        SetColorBrushPair(resources, "DsDangerActive", WithAlpha(state.Danger, 0x1F));
        SetColorBrushPair(resources, "DsInfo", state.Info);

        SetDropShadow(resources, "DsShadowSmEffect", shadows.Small);
        SetDropShadow(resources, "DsShadowMdEffect", shadows.Medium);
        SetDropShadow(resources, "DsShadowLgEffect", shadows.Large);
    }

    private static void ApplyLegacyAliases(
        ResourceDictionary resources,
        NeutralPalette neutral,
        StatePalette state,
        AccentPalette palette)
    {
        SetColorBrushPair(resources, "BgDeep", "BgDeepBrush", neutral.Bg);
        SetColorBrushPair(resources, "BgDark", "BgDarkBrush", neutral.Bg);
        SetColorBrushPair(resources, "BgPanel", "BgPanelBrush", neutral.BgElev);
        SetColorBrushPair(resources, "BgSidebar", "BgSidebarBrush", neutral.BgSunken);
        SetColorBrushPair(resources, "BgCard", "BgCardBrush", neutral.BgElev);
        SetColorBrushPair(resources, "BgInput", "BgInputBrush", neutral.BgElev);
        SetColorBrushPair(resources, "BgHover", "BgHoverBrush", neutral.BgHover);
        SetColorBrushPair(resources, "BgActive", "BgActiveBrush", neutral.BgActive);

        SetColorBrushPair(resources, "AccentColor", "AccentBrush", palette.Accent);
        SetColorBrushPair(resources, "AccentSoft", "AccentSoftBrush", palette.AccentSoft);
        SetColorBrushPair(resources, "AccentRing", "AccentRingBrush", palette.AccentRing);

        SetColorBrushPair(resources, "DangerColor", "DangerBrush", state.Danger);
        SetColorBrushPair(resources, "WarningColor", "WarningBrush", state.Warning);
        SetColorBrushPair(resources, "SuccessColor", "SuccessBrush", state.Success);

        SetColorBrushPair(resources, "NeonGreen", "NeonGreenBrush", palette.Accent);
        SetColorBrushPair(resources, "NeonCyan", "NeonCyanBrush", palette.Accent);
        SetColorBrushPair(resources, "NeonPurple", "NeonPurpleBrush", palette.Accent);
        SetColorBrushPair(resources, "NeonRed", "NeonRedBrush", state.Danger);
        SetColorBrushPair(resources, "NeonOrange", "NeonOrangeBrush", state.Warning);
        SetColorBrushPair(resources, "NeonYellow", "NeonYellowBrush", state.Warning);

        SetColorBrushPair(resources, "TextBright", "TextBrightBrush", neutral.Fg);
        SetColorBrushPair(resources, "TextDim", "TextDimBrush", neutral.FgMuted);
        SetColorBrushPair(resources, "TextGhost", "TextGhostBrush", neutral.FgSubtle);
        SetColorBrushPair(resources, "TextMuted", "TextMutedBrush", neutral.FgFaint);
        SetColorBrushPair(resources, "BorderDim", "BorderDimBrush", neutral.Line);
        SetColorBrushPair(resources, "DividerColor", "DividerBrush", neutral.Line);

        SetBrush(resources, "CyberBgPrimary", neutral.Bg);
        SetBrush(resources, "CyberTextPrimary", neutral.Fg);
        SetBrush(resources, "CyberTextDim", neutral.FgMuted);
        SetBrush(resources, "CyberTextGhost", neutral.FgSubtle);
        SetBrush(resources, "CyberNeonCyan", palette.Accent);
        SetBrush(resources, "CyberNeonGreen", palette.Accent);
        SetBrush(resources, "CyberNeonRed", state.Danger);
        SetBrush(resources, "CyberNeonYellow", state.Warning);
        SetColor(resources, "CyberNeonCyanColor", palette.Accent);
        SetColor(resources, "CyberNeonRedColor", state.Danger);
    }

    private static void SetColorBrushPair(ResourceDictionary resources, string tokenPrefix, Color color)
    {
        SetColorBrushPair(resources, $"{tokenPrefix}Color", $"{tokenPrefix}Brush", color);
    }

    private static void SetColorBrushPair(
        ResourceDictionary resources,
        string colorKey,
        string brushKey,
        Color color)
    {
        SetColor(resources, colorKey, color);
        SetBrush(resources, brushKey, color);
    }

    private static void SetColor(ResourceDictionary resources, string key, Color color)
    {
        var target = FindDictionary(resources, key) ?? resources;
        target[key] = color;
    }

    private static void SetBrush(ResourceDictionary resources, string key, Color color)
    {
        var target = FindDictionary(resources, key) ?? resources;
        if (target.Contains(key) && target[key] is SolidColorBrush brush && !brush.IsFrozen)
            brush.Color = color;
        else
            target[key] = new SolidColorBrush(color);
    }

    private static void SetDropShadow(ResourceDictionary resources, string key, ShadowSpec spec)
    {
        var target = FindDictionary(resources, key) ?? resources;
        if (target.Contains(key) && target[key] is DropShadowEffect effect && !effect.IsFrozen)
        {
            effect.Color = spec.Color;
            effect.Opacity = spec.Opacity;
            effect.BlurRadius = spec.BlurRadius;
            effect.ShadowDepth = spec.ShadowDepth;
            effect.Direction = 270;
            return;
        }

        target[key] = new DropShadowEffect
        {
            Color = spec.Color,
            Opacity = spec.Opacity,
            BlurRadius = spec.BlurRadius,
            ShadowDepth = spec.ShadowDepth,
            Direction = 270
        };
    }

    private static Color Transparent(Color color) => Color.FromArgb(0, color.R, color.G, color.B);

    private static Color WithAlpha(Color color, byte alpha) => Color.FromArgb(alpha, color.R, color.G, color.B);

    private static void SetLinearGradient(ResourceDictionary resources, string key, params Color[] colors)
    {
        var target = FindDictionary(resources, key) ?? resources;
        if (target.Contains(key) && target[key] is LinearGradientBrush brush && !brush.IsFrozen)
        {
            while (brush.GradientStops.Count < colors.Length)
                brush.GradientStops.Add(new GradientStop());

            for (var i = 0; i < colors.Length; i++)
            {
                brush.GradientStops[i].Color = colors[i];
                brush.GradientStops[i].Offset = colors.Length == 1 ? 0 : (double)i / (colors.Length - 1);
            }

            while (brush.GradientStops.Count > colors.Length)
                brush.GradientStops.RemoveAt(brush.GradientStops.Count - 1);
            return;
        }

        var replacement = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(1, 1) };
        for (var i = 0; i < colors.Length; i++)
            replacement.GradientStops.Add(new GradientStop(colors[i], colors.Length == 1 ? 0 : (double)i / (colors.Length - 1)));
        target[key] = replacement;
    }

    private static ResourceDictionary? FindDictionary(ResourceDictionary resources, string key)
    {
        if (ContainsDirectKey(resources, key))
            return resources;

        foreach (var merged in resources.MergedDictionaries)
        {
            var found = FindDictionary(merged, key);
            if (found != null)
                return found;
        }

        return null;
    }

    private static bool ContainsDirectKey(ResourceDictionary resources, string key)
    {
        foreach (var existingKey in resources.Keys)
        {
            if (Equals(existingKey, key))
                return true;
        }

        return false;
    }

    private static LoadResult Load(string settingsPath)
    {
        try
        {
            if (!File.Exists(settingsPath))
                return new LoadResult(AppTheme.Light, AppAccent.Sand, false);

            using var doc = JsonDocument.Parse(File.ReadAllText(settingsPath));
            var root = doc.RootElement;

            if (root.TryGetProperty("theme", out var themeValue) &&
                root.TryGetProperty("accent", out var accentValue) &&
                TryParseTheme(themeValue.GetString(), out var theme) &&
                TryParseAccent(accentValue.GetString(), out var accent))
            {
                return new LoadResult(theme, accent, false);
            }

            if (root.TryGetProperty("mode", out var legacyValue) &&
                Enum.TryParse(legacyValue.GetString(), out AppThemeMode mode))
            {
                DebugTrace.Log("ThemeManager", $"Migrated legacy theme mode {mode} to theme/accent shape.");
                return mode == AppThemeMode.SandDark
                    ? new LoadResult(AppTheme.Dark, AppAccent.Sand, true)
                    : new LoadResult(AppTheme.Light, AppAccent.Sand, true);
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("ThemeManager", ex);
        }

        return new LoadResult(AppTheme.Light, AppAccent.Sand, false);
    }

    private static bool TryParseTheme(string? value, out AppTheme theme)
    {
        theme = AppTheme.Light;
        return !string.IsNullOrWhiteSpace(value) &&
               Enum.TryParse(value, true, out theme);
    }

    private static bool TryParseAccent(string? value, out AppAccent accent)
    {
        accent = AppAccent.Sand;
        return !string.IsNullOrWhiteSpace(value) &&
               Enum.TryParse(value, true, out accent);
    }

    private void Save()
    {
        var dir = Path.GetDirectoryName(_settingsPath);
        if (!string.IsNullOrWhiteSpace(dir))
            Directory.CreateDirectory(dir);

        File.WriteAllText(
            _settingsPath,
            JsonSerializer.Serialize(new
            {
                theme = Theme.ToString().ToLowerInvariant(),
                accent = Accent.ToString().ToLowerInvariant()
            }));
    }

    private void OnPropertyChanged(string propertyName)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    private readonly record struct LoadResult(AppTheme Theme, AppAccent Accent, bool MigratedFromLegacy);
}
