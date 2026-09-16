using System.Reflection;
using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Helpers;
using LobsterInput.Services;
using LobsterInput.Services.HotKeys;

namespace LobsterInput.ViewModels;

public sealed partial class SettingsViewModel : ObservableObject, IDisposable
{
    private readonly HotKeyService _hotKeyService = HotKeyService.Instance;
    private readonly HotKeyCaptureService _hotKeyCapture = HotKeyCaptureService.Instance;

    [ObservableProperty]
    private bool _isRecordingHotkey;

    [ObservableProperty]
    private HotKeyCombo _recordingCombo;

    [ObservableProperty]
    private AppLanguage _selectedLanguage;

    [ObservableProperty]
    private bool _clipboardAccessEnabled;

    [ObservableProperty]
    private bool _transcribeFastModeEnabled;

    [ObservableProperty]
    private bool _realtimeRecognitionEnabled;

    [ObservableProperty]
    private bool _screenshotConfirmationEnabled;

    [ObservableProperty]
    private bool _longImageModeEnabled;

    [ObservableProperty]
    private bool _startupLaunchEnabled;

    [ObservableProperty]
    private AppThemeMode _selectedThemeMode;

    [ObservableProperty]
    private AppAccent _selectedAccent;

    public string VersionString
    {
        get
        {
            var ver = Assembly.GetExecutingAssembly().GetName().Version;
            return $"v{ver?.Major}.{ver?.Minor}.{ver?.Build}";
        }
    }

    public SettingsViewModel()
    {
        _selectedLanguage = LanguageManager.Instance.Current;
        _clipboardAccessEnabled = ClipboardService.ClipboardAccessEnabled;
        _transcribeFastModeEnabled = TranscribeFastModeStore.IsEnabled;
        _realtimeRecognitionEnabled = RealtimeRecognitionStore.IsEnabled;
        _screenshotConfirmationEnabled = ScreenshotService.ConfirmationEnabled;
        _longImageModeEnabled = ScreenshotService.LongImageModeEnabled;
        _startupLaunchEnabled = StartupLaunchService.IsEnabled;
        _selectedThemeMode = ThemeManager.Instance.Mode;
        _selectedAccent = ThemeManager.Instance.Accent;
        ThemeManager.Instance.PropertyChanged += OnThemeManagerChanged;
    }

    public void StartRecordingHotkey(HotKeyCombo combo)
    {
        if (IsRecordingHotkey)
            CancelRecording();

        _hotKeyService.StopListening();
        RecordingCombo = combo;
        IsRecordingHotkey = true;

        if (!_hotKeyCapture.Start(ApplyCapturedHotkey))
        {
            IsRecordingHotkey = false;
            _hotKeyService.StartListening();
        }
    }

    public void CancelRecording()
    {
        if (!IsRecordingHotkey) return;

        _hotKeyCapture.Cancel();
        IsRecordingHotkey = false;
        _hotKeyService.StartListening();
    }

    private void ApplyCapturedHotkey(HotKeyConfig? config)
    {
        if (!IsRecordingHotkey) return;

        if (config != null)
        {
            _hotKeyService.Configs[RecordingCombo] = config;
            _hotKeyService.SaveConfigs();
        }

        IsRecordingHotkey = false;
        _hotKeyService.StartListening();
    }

    public void ClearHotkey(HotKeyCombo combo)
    {
        if (IsRecordingHotkey)
            CancelRecording();

        _hotKeyService.ClearConfig(combo);
        OnPropertyChanged(nameof(IsRecordingHotkey));
    }

    partial void OnSelectedLanguageChanged(AppLanguage value)
    {
        LanguageManager.Instance.Current = value;
    }

    partial void OnClipboardAccessEnabledChanged(bool value)
    {
        ClipboardService.ClipboardAccessEnabled = value;
    }

    partial void OnTranscribeFastModeEnabledChanged(bool value)
    {
        TranscribeFastModeStore.IsEnabled = value;
    }

    partial void OnRealtimeRecognitionEnabledChanged(bool value)
    {
        RealtimeRecognitionStore.IsEnabled = value;
        if (value)
            AudioRecorderService.Instance.ReleasePreparedCaptureForRealtimeStart();
        else
            _ = AudioRecorderService.Instance.PrepareAsync(forceRebuild: true);
    }

    partial void OnScreenshotConfirmationEnabledChanged(bool value)
    {
        ScreenshotService.ConfirmationEnabled = value;
    }

    partial void OnLongImageModeEnabledChanged(bool value)
    {
        ScreenshotService.LongImageModeEnabled = value;
    }

    partial void OnStartupLaunchEnabledChanged(bool value)
    {
        StartupLaunchService.IsEnabled = value;
    }

    partial void OnSelectedThemeModeChanged(AppThemeMode value)
    {
        ThemeManager.Instance.Mode = value;
    }

    partial void OnSelectedAccentChanged(AppAccent value)
    {
        ThemeManager.Instance.Accent = value;
    }

    private void OnThemeManagerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ThemeManager.Mode) ||
            e.PropertyName == nameof(ThemeManager.Theme))
        {
            SelectedThemeMode = ThemeManager.Instance.Mode;
        }

        if (e.PropertyName == nameof(ThemeManager.Accent))
        {
            SelectedAccent = ThemeManager.Instance.Accent;
        }
    }

    public void Dispose()
    {
        ThemeManager.Instance.PropertyChanged -= OnThemeManagerChanged;
    }

}
