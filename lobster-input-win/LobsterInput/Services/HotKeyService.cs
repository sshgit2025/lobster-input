using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Helpers;
using LobsterInput.Services.HotKeys;
using LobsterInput.Stores;

namespace LobsterInput.Services;

public enum HotKeyCombo
{
    Transcribe,
    Rewrite,
    Agent,
    Screenshot
}

[Flags]
public enum ModifierKeys
{
    None = 0,
    Alt = 1,
    Control = 2,
    Shift = 4,
    Win = 8
}

public class HotKeyConfig
{
    [JsonPropertyName("modifiers")]
    public ModifierKeys Modifiers { get; set; }

    [JsonPropertyName("keyCode")]
    public int KeyCode { get; set; }

    [JsonIgnore]
    public string DisplayString
    {
        get
        {
            if (IsDisabled) return L10n.HotkeyNotSet;
            var parts = new List<string>();
            if (Modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
            if (Modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
            if (Modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
            if (Modifiers.HasFlag(ModifierKeys.Win)) parts.Add("Win");
            parts.Add(VirtualKeyName(KeyCode));
            return string.Join("+", parts);
        }
    }

    public static HotKeyConfig DefaultTranscribe => new() { Modifiers = ModifierKeys.Alt, KeyCode = 0x51 };
    public static HotKeyConfig DefaultRewrite => new() { Modifiers = ModifierKeys.Alt, KeyCode = 0x57 };
    public static HotKeyConfig DefaultAgent => new() { Modifiers = ModifierKeys.Alt, KeyCode = 0x45 };
    public static HotKeyConfig DefaultScreenshot => new() { Modifiers = ModifierKeys.Alt, KeyCode = 0x52 };
    public static HotKeyConfig Disabled => new() { Modifiers = ModifierKeys.None, KeyCode = 0 };

    [JsonIgnore]
    public bool IsDisabled => Modifiers == ModifierKeys.None && KeyCode == 0;

    private static string VirtualKeyName(int vk) => vk switch
    {
        >= 0x30 and <= 0x39 => ((char)vk).ToString(),
        >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        0x20 => "Space",
        0x0D => "Enter",
        0x1B => "Escape",
        0x09 => "Tab",
        _ => $"0x{vk:X2}"
    };
}

public sealed partial class HotKeyService : ObservableObject, IDisposable
{
    public static HotKeyService Instance { get; } = new();

    private readonly IHotKeyBackend _backend;
    private bool _disposed;

    [ObservableProperty]
    private bool _isListening;

    public Dictionary<HotKeyCombo, HotKeyConfig> Configs { get; set; } = new()
    {
        [HotKeyCombo.Transcribe] = HotKeyConfig.DefaultTranscribe,
        [HotKeyCombo.Rewrite] = HotKeyConfig.DefaultRewrite,
        [HotKeyCombo.Agent] = HotKeyConfig.DefaultAgent,
        [HotKeyCombo.Screenshot] = HotKeyConfig.DefaultScreenshot
    };

    public Action<HotKeyCombo>? OnHotKeyPressed { get; set; }

    public event Action<string>? HookError;

    private HotKeyService()
        : this(new LowLevelKeyboardHookBackend())
    {
    }

    internal HotKeyService(IHotKeyBackend backend)
    {
        _backend = backend;
        _backend.HotKeyPressed += OnBackendHotKeyPressed;
        _backend.Error += OnBackendError;
        LoadConfigs();
    }

    public void StartListening()
    {
        if (IsListening) return;

        _backend.Start(Configs);
        IsListening = _backend.IsListening;

        if (IsListening)
        {
            Debug.WriteLine("[HotKeyService] Hotkey backend started");
            DebugTrace.Log("HotKeyService", "Hotkey backend started");
        }
    }

    public void StopListening()
    {
        if (!_backend.IsListening && !IsListening) return;

        _backend.Stop();
        IsListening = false;
        Debug.WriteLine("[HotKeyService] Hotkey backend stopped");
        DebugTrace.Log("HotKeyService", "Hotkey backend stopped");
    }

    private void OnBackendHotKeyPressed(HotKeyCombo combo)
    {
        System.Windows.Application.Current?.Dispatcher.BeginInvoke(
            DispatcherPriority.Send,
            () => OnHotKeyPressed?.Invoke(combo));
    }

    private void OnBackendError(string message)
    {
        HookError?.Invoke(message);
    }

    private void RestartListeningIfNeeded()
    {
        if (!IsListening) return;
        StopListening();
        StartListening();
    }

    #region Persistence

    private const int DefaultsVersion = 3;

    private static string UserConfigId
    {
        get
        {
            var email = AuthStore.Instance.Email;
            if (string.IsNullOrWhiteSpace(email))
                return "anonymous";

            const ulong offset = 14695981039346656037;
            const ulong prime = 1099511628211;
            var hash = offset;
            foreach (var b in System.Text.Encoding.UTF8.GetBytes(email.Trim().ToLowerInvariant()))
            {
                hash ^= b;
                hash *= prime;
            }

            return $"{hash:x16}";
        }
    }

    private static string ConfigPath => Path.Combine(
        AppPaths.LocalAppDataDir, "hotkeys", $"{UserConfigId}.json");

    public void SaveConfigs()
    {
        try
        {
            var dir = Path.GetDirectoryName(ConfigPath)!;
            Directory.CreateDirectory(dir);

            var dict = Configs.ToDictionary(
                kv => kv.Key.ToString(),
                kv => kv.Value);

            var json = JsonSerializer.Serialize(dict, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(ConfigPath, json);
            Debug.WriteLine($"[HotKeyService] Configs saved to {ConfigPath}");
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HotKeyService] Save failed: {ex.Message}");
        }
    }

    public void ClearConfig(HotKeyCombo combo)
    {
        Configs[combo] = HotKeyConfig.Disabled;
        SaveConfigs();
        RestartListeningIfNeeded();
        OnPropertyChanged(nameof(Configs));
    }

    private void LoadConfigs()
    {
        try
        {
            if (!File.Exists(ConfigPath))
            {
                SaveConfigs();
                return;
            }

            var json = File.ReadAllText(ConfigPath);
            var dict = JsonSerializer.Deserialize<Dictionary<string, HotKeyConfig>>(json);
            if (dict == null) return;

            foreach (var (key, value) in dict)
            {
                if (Enum.TryParse<HotKeyCombo>(key, out var combo))
                    Configs[combo] = value;
            }

            EnsureDefaultConfigs();
            UpgradeDefaultConfigsIfNeeded();

            Debug.WriteLine("[HotKeyService] Configs loaded from file");
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[HotKeyService] Load failed: {ex.Message}");
        }
    }

    public void ReloadForCurrentUser()
    {
        var wasListening = IsListening;
        if (wasListening)
            StopListening();

        Configs = new Dictionary<HotKeyCombo, HotKeyConfig>
        {
            [HotKeyCombo.Transcribe] = HotKeyConfig.DefaultTranscribe,
            [HotKeyCombo.Rewrite] = HotKeyConfig.DefaultRewrite,
            [HotKeyCombo.Agent] = HotKeyConfig.DefaultAgent,
            [HotKeyCombo.Screenshot] = HotKeyConfig.DefaultScreenshot
        };
        LoadConfigs();
        OnPropertyChanged(nameof(Configs));

        if (wasListening)
            StartListening();
    }

    private void EnsureDefaultConfigs()
    {
        if (!Configs.ContainsKey(HotKeyCombo.Transcribe))
            Configs[HotKeyCombo.Transcribe] = HotKeyConfig.DefaultTranscribe;
        if (!Configs.ContainsKey(HotKeyCombo.Rewrite))
            Configs[HotKeyCombo.Rewrite] = HotKeyConfig.DefaultRewrite;
        if (!Configs.ContainsKey(HotKeyCombo.Agent))
            Configs[HotKeyCombo.Agent] = HotKeyConfig.DefaultAgent;
        if (!Configs.ContainsKey(HotKeyCombo.Screenshot))
            Configs[HotKeyCombo.Screenshot] = HotKeyConfig.DefaultScreenshot;
    }

    private void UpgradeDefaultConfigsIfNeeded()
    {
        var versionPath = Path.Combine(Path.GetDirectoryName(ConfigPath)!, $"{Path.GetFileNameWithoutExtension(ConfigPath)}.version");
        var savedVersion = 0;
        if (File.Exists(versionPath))
            _ = int.TryParse(File.ReadAllText(versionPath), out savedVersion);
        if (savedVersion >= DefaultsVersion) return;

        ReplaceIfOldDefault(HotKeyCombo.Transcribe, new HotKeyConfig { Modifiers = ModifierKeys.Control | ModifierKeys.Alt, KeyCode = 0x51 }, HotKeyConfig.DefaultTranscribe);
        ReplaceIfOldDefault(HotKeyCombo.Rewrite, new HotKeyConfig { Modifiers = ModifierKeys.Control | ModifierKeys.Alt, KeyCode = 0x45 }, HotKeyConfig.DefaultRewrite);
        ReplaceIfOldDefault(HotKeyCombo.Agent, new HotKeyConfig { Modifiers = ModifierKeys.Control | ModifierKeys.Alt, KeyCode = 0x57 }, HotKeyConfig.DefaultAgent);
        ReplaceIfOldDefault(HotKeyCombo.Screenshot, new HotKeyConfig { Modifiers = ModifierKeys.Control | ModifierKeys.Alt, KeyCode = 0x41 }, HotKeyConfig.DefaultScreenshot);
        ReplaceIfOldDefault(HotKeyCombo.Rewrite, new HotKeyConfig { Modifiers = ModifierKeys.Control | ModifierKeys.Alt, KeyCode = 0x57 }, HotKeyConfig.DefaultRewrite);
        ReplaceIfOldDefault(HotKeyCombo.Agent, new HotKeyConfig { Modifiers = ModifierKeys.Control | ModifierKeys.Alt, KeyCode = 0x45 }, HotKeyConfig.DefaultAgent);
        ReplaceIfOldDefault(HotKeyCombo.Screenshot, new HotKeyConfig { Modifiers = ModifierKeys.Control | ModifierKeys.Alt, KeyCode = 0x52 }, HotKeyConfig.DefaultScreenshot);

        Directory.CreateDirectory(Path.GetDirectoryName(versionPath)!);
        File.WriteAllText(versionPath, DefaultsVersion.ToString());
        SaveConfigs();
    }

    private void ReplaceIfOldDefault(HotKeyCombo combo, HotKeyConfig oldDefault, HotKeyConfig newDefault)
    {
        if (!Configs.TryGetValue(combo, out var current)) return;
        if (current.Modifiers == oldDefault.Modifiers && current.KeyCode == oldDefault.KeyCode)
            Configs[combo] = newDefault;
    }

    #endregion

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        StopListening();
        _backend.HotKeyPressed -= OnBackendHotKeyPressed;
        _backend.Error -= OnBackendError;
        _backend.Dispose();
    }
}
