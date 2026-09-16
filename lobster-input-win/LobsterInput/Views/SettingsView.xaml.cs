using System.ComponentModel;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;
using LobsterInput.ViewModels;

namespace LobsterInput.Views;

public partial class SettingsView : UserControl
{
    private readonly SettingsViewModel _vm = new();
    private bool _suppressLanguageEvent;
    private bool _suppressMicrophoneEvent;
    private bool _suppressStartupLaunchEvent;
    private bool _suppressThemeEvent;
    private bool _suppressScreenshotToggleEvent;   // 截图二次确认 / 长图模式 互斥时抑制递归
    private bool _creditDetailsExpanded;
    private OnboardingWindow? _tutorialWindow;

    public event Action? NavigateToInviteCodes;

    public SettingsView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _vm.PropertyChanged += OnVmChanged;
        LanguageManager.Instance.PropertyChanged += OnVmChanged;
        AuthStore.Instance.PropertyChanged += OnVmChanged;
        ThemeManager.Instance.PropertyChanged += OnVmChanged;
        RefreshAll();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _vm.PropertyChanged -= OnVmChanged;
        LanguageManager.Instance.PropertyChanged -= OnVmChanged;
        AuthStore.Instance.PropertyChanged -= OnVmChanged;
        ThemeManager.Instance.PropertyChanged -= OnVmChanged;
        _vm.Dispose();
        _vm.CancelRecording();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(RefreshAll);
    }

    private void RefreshAll()
    {
        RefreshLabels();
        RefreshCredits();
        RefreshHotkeyButtons();
        RefreshLanguageCombo();
        RefreshClipboard();
        RefreshFastMode();
        RefreshRealtimeRecognition();
        RefreshScreenshotConfirmation();
        RefreshStartupLaunch();
        RefreshTheme();
        RefreshAccent();
        RefreshMicrophones();
        RefreshAbout();
        RefreshInviteCodesBtn();
        RefreshSubscriptionEntry();
    }

    private void RefreshLabels()
    {
        SettingsPageTitle.Text = L10n.PageSettings;
        HotkeySectionLabel.Text = L10n.SectionHotkeys;
        CreditsSectionLabel.Text = L10n.AccountCredits;
        HkTranscribeTitle.Text = L10n.HotkeyVoiceInput;
        HkTranscribeDesc.Text = L10n.HotkeyVoiceInputDesc;
        HkRewriteTitle.Text = L10n.HotkeyRewriteTitle;
        HkRewriteDesc.Text = L10n.HotkeyRewriteDesc;
        HkAgentTitle.Text = L10n.HotkeyAgentTitle;
        HkAgentDesc.Text = L10n.HotkeyAgentDesc;
        HkScreenshotTitle.Text = L10n.HotkeyScreenshotTitle;
        HkScreenshotDesc.Text = L10n.HotkeyScreenshotDesc;
        ScreenshotSectionLabel.Text = L10n.HotkeyScreenshotTitle;
        ScreenshotConfirmTitle.Text = L10n.ScreenshotConfirmationTitle;
        ScreenshotConfirmDesc.Text = L10n.ScreenshotConfirmationDesc;
        LongImageModeTitle.Text = L10n.LongImageModeTitle;
        LongImageModeDesc.Text = L10n.LongImageModeDesc;
        StartupLaunchTitle.Text = L10n.StartupLaunchTitle;
        StartupLaunchDesc.Text = L10n.StartupLaunchDesc;
        MicrophoneSectionLabel.Text = L10n.SettingsMicrophoneSection;
        MicrophoneTitle.Text = L10n.MicrophoneInputTitle;
        MicrophoneDesc.Text = L10n.MicrophoneInputDesc;
        HkTranscribeClearBtn.Content = "\uE711";
        HkRewriteClearBtn.Content = "\uE711";
        HkAgentClearBtn.Content = "\uE711";
        HkScreenshotClearBtn.Content = "\uE711";
        HkTranscribeClearBtn.ToolTip = L10n.ClearHotkey;
        HkRewriteClearBtn.ToolTip = L10n.ClearHotkey;
        HkAgentClearBtn.ToolTip = L10n.ClearHotkey;
        HkScreenshotClearBtn.ToolTip = L10n.ClearHotkey;
        LanguageLabel.Text = L10n.LanguageLabel;
        LanguageTitle.Text = L10n.LanguageLabel;
        PrivacySectionLabel.Text = L10n.SectionPrivacy;
        ClipboardTitle.Text = L10n.ClipboardAccessTitle;
        ClipboardDesc.Text = L10n.ClipboardAccessDesc;
        FastModeTitle.Text = L10n.TranscribeFastModeTitle;
        FastModeDesc.Text = L10n.TranscribeFastModeDesc;
        RealtimeRecognitionTitle.Text = L10n.RealtimeRecognitionTitle;
        RealtimeRecognitionDesc.Text = L10n.RealtimeRecognitionDesc;
        ThemeSectionLabel.Text = L10n.SettingsAppearance;
        ThemeTitle.Text = L10n.SettingsTheme;
        ThemeDesc.Text = L10n.SettingsThemeDescription;
        AccentTitle.Text = L10n.SettingsAccent;
        AccentDesc.Text = L10n.SettingsAccentDescription;
        AccentSandBtn.ToolTip = L10n.AccentSand;
        AccentMonoBtn.ToolTip = L10n.AccentMono;
        AccentBlueBtn.ToolTip = L10n.AccentBlue;
        AccentOrangeBtn.ToolTip = L10n.AccentOrange;
        AccentRedBtn.ToolTip = L10n.AccentRed;
        AccentGreenBtn.ToolTip = L10n.AccentGreen;
        AccentPurpleBtn.ToolTip = L10n.AccentPurple;
        TutorialSectionLabel.Text = L10n.SettingsTutorialSection;
        TutorialReplayTitle.Text = L10n.TutorialReplayTitle;
        TutorialReplayDesc.Text = L10n.TutorialReplayDesc;
        FeedbackSectionLabel.Text = L10n.SettingsFeedbackSection;
        FeedbackTitle.Text = L10n.FeedbackTitle;
        FeedbackDesc.Text = L10n.FeedbackSettingsDesc;
        SubscriptionSectionLabel.Text = L10n.SubscriptionSettingsSection;
        SubscriptionEntryTitle.Text = L10n.SubscriptionEntryTitle;
        SubscriptionEntryDesc.Text = L10n.SubscriptionEntryDesc;
        InviteCodesBtn.Content = L10n.MyInviteCodesBtn;
        SoftwareUpdateSectionLabel.Text = L10n.SettingsSoftwareUpdateSection;
        SoftwareUpdateTitle.Text = L10n.SettingsSoftwareUpdateSection;
        CheckUpdateBtn.Content = L10n.MenuCheckUpdate;
        WindowsOptionsSectionLabel.Text = L10n.SettingsWindowsOptionsSection;
    }

    private void RefreshHotkeyButtons()
    {
        var hotKey = HotKeyService.Instance;
        SetHotkeyRow(HkTranscribeBtn, HkTranscribeClearBtn, hotKey.Configs[HotKeyCombo.Transcribe], _vm.IsRecordingHotkey && _vm.RecordingCombo == HotKeyCombo.Transcribe);
        SetHotkeyRow(HkRewriteBtn, HkRewriteClearBtn, hotKey.Configs[HotKeyCombo.Rewrite], _vm.IsRecordingHotkey && _vm.RecordingCombo == HotKeyCombo.Rewrite);
        SetHotkeyRow(HkAgentBtn, HkAgentClearBtn, hotKey.Configs[HotKeyCombo.Agent], _vm.IsRecordingHotkey && _vm.RecordingCombo == HotKeyCombo.Agent);
        SetHotkeyRow(HkScreenshotBtn, HkScreenshotClearBtn, hotKey.Configs[HotKeyCombo.Screenshot], _vm.IsRecordingHotkey && _vm.RecordingCombo == HotKeyCombo.Screenshot);

        RecordingHint.Text = CleanHotkeyRecordingHint(L10n.PressNewHotkey);
        RecordingHint.Visibility = _vm.IsRecordingHotkey ? Visibility.Visible : Visibility.Hidden;
    }

    private void RefreshCredits()
    {
        var auth = AuthStore.Instance;
        var total = Math.Max(auth.CreditsTotal, 0);
        var remaining = Math.Max(auth.CreditsRemaining, 0);
        var used = Math.Max(auth.CreditsUsed, 0);

        PlanNameText.Text = LocalizedPlanName(auth.Tier);
        CreditsUsedText.Text = $"{L10n.AccountCreditsUsed} {used}";
        CreditsRemainingText.Text = total > 0
            ? $"{remaining} / {total}"
            : remaining.ToString();
        CreditsProgressScale.ScaleX = auth.CreditsTotal > 0
            ? Math.Clamp((double)auth.CreditsRemaining / auth.CreditsTotal, 0, 1)
            : 0;
        CreditsResetText.Text = $"{L10n.AccountCreditsReset}: {auth.FormattedResetDate() ?? "-"}";
        CreditDetailsToggleBtn.Content = _creditDetailsExpanded
            ? L10n.AccountCreditsDetailsHide
            : L10n.AccountCreditsDetailsShow;
        CreditDetailsPanel.Visibility = _creditDetailsExpanded ? Visibility.Visible : Visibility.Collapsed;
        CreditItemsList.ItemsSource = BuildCreditRows(auth);
    }

    private void RefreshLanguageCombo()
    {
        _suppressLanguageEvent = true;

        if (LanguageCombo.Items.Count == 0)
        {
            foreach (AppLanguage lang in Enum.GetValues<AppLanguage>())
            {
                LanguageCombo.Items.Add(new ComboBoxItem
                {
                    Content = LanguageManager.GetDisplayName(lang),
                    Tag = lang
                });
            }
        }

        var current = LanguageManager.Instance.Current;
        LanguageCurrentText.Text = LanguageManager.GetDisplayName(current);
        for (int i = 0; i < LanguageCombo.Items.Count; i++)
        {
            if (LanguageCombo.Items[i] is ComboBoxItem item &&
                item.Tag is AppLanguage al && al == current)
            {
                LanguageCombo.SelectedIndex = i;
                break;
            }
        }

        _suppressLanguageEvent = false;
    }

    private void RefreshClipboard()
    {
        ClipboardToggle.IsChecked = ClipboardService.ClipboardAccessEnabled;
    }

    private void RefreshFastMode()
    {
        FastModeToggle.IsChecked = _vm.TranscribeFastModeEnabled;
    }

    private void RefreshRealtimeRecognition()
    {
        RealtimeRecognitionToggle.IsChecked = _vm.RealtimeRecognitionEnabled;
    }

    private void RefreshScreenshotConfirmation()
    {
        _suppressScreenshotToggleEvent = true;
        ScreenshotConfirmToggle.IsChecked = _vm.ScreenshotConfirmationEnabled;
        LongImageModeToggle.IsChecked = _vm.LongImageModeEnabled;
        _suppressScreenshotToggleEvent = false;
    }

    private void RefreshStartupLaunch()
    {
        _suppressStartupLaunchEvent = true;
        StartupLaunchToggle.IsChecked = StartupLaunchService.IsEnabled;
        _suppressStartupLaunchEvent = false;
    }

    private void RefreshTheme()
    {
        _suppressThemeEvent = true;
        _vm.SelectedThemeMode = ThemeManager.Instance.Mode;
        ThemeToggle.IsChecked = ThemeManager.Instance.Theme == AppTheme.Dark;
        _suppressThemeEvent = false;
    }

    private void RefreshAccent()
    {
        _vm.SelectedAccent = ThemeManager.Instance.Accent;
        PaintAccentButton(AccentSandBtn, AppAccent.Sand);
        PaintAccentButton(AccentMonoBtn, AppAccent.Mono);
        PaintAccentButton(AccentBlueBtn, AppAccent.Blue);
        PaintAccentButton(AccentOrangeBtn, AppAccent.Orange);
        PaintAccentButton(AccentRedBtn, AppAccent.Red);
        PaintAccentButton(AccentGreenBtn, AppAccent.Green);
        PaintAccentButton(AccentPurpleBtn, AppAccent.Purple);
    }

    private static void PaintAccentButton(Button button, AppAccent accent)
    {
        var selected = ThemeManager.Instance.Accent == accent;
        var palette = AccentPalette.For(ThemeManager.Instance.Theme, accent);
        button.Content = selected ? "\uE73E" : "";
        button.FontFamily = Application.Current.TryFindResource("IconFont") as FontFamily
            ?? new FontFamily("Segoe MDL2 Assets");
        button.Foreground = new SolidColorBrush(palette.AccentFg);
        button.FontWeight = FontWeights.SemiBold;
        button.Background = new SolidColorBrush(palette.Accent);
        button.BorderBrush = selected
            ? new SolidColorBrush(palette.AccentRing)
            : (Application.Current.TryFindResource("DsLineBrush") as Brush ?? Brushes.Transparent);
        button.BorderThickness = selected ? new Thickness(3) : new Thickness(1);
        button.Padding = new Thickness(0);
    }

    private void RefreshMicrophones()
    {
        _suppressMicrophoneEvent = true;
        MicrophoneCombo.Items.Clear();

        MicrophoneCombo.Items.Add(new ComboBoxItem
        {
            Content = L10n.MicrophoneAutoDetect(L10n.MenuDefaultMicrophone),
            Tag = null
        });

        foreach (var device in AudioRecorderService.Instance.InputDevices())
        {
            MicrophoneCombo.Items.Add(new ComboBoxItem
            {
                Content = device.Name,
                Tag = device.Id,
                IsSelected = device.IsSelected
            });
        }

        if (MicrophoneCombo.SelectedIndex < 0)
            MicrophoneCombo.SelectedIndex = 0;

        _suppressMicrophoneEvent = false;
    }

    private void RefreshAbout()
    {
        var ver = Assembly.GetExecutingAssembly().GetName().Version;
        var versionText = $"v{ver?.Major}.{ver?.Minor}.{ver?.Build}";
        var envBadge = L10n.EnvBadge;
        VersionText.Text = string.IsNullOrEmpty(envBadge)
            ? versionText
            : $"{versionText} · {envBadge}";
    }

    private void RefreshInviteCodesBtn()
    {
        InviteCodesBtn.Visibility = AuthStore.Instance.ShowInviteCodesEnabled
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RefreshSubscriptionEntry()
    {
        var visibility = AuthStore.Instance.ShowSubscriptionModuleEnabled
            ? Visibility.Visible
            : Visibility.Collapsed;
        SubscriptionSectionHeader.Visibility = visibility;
        SubscriptionEntryCard.Visibility = visibility;
    }

    private static string LocalizedPlanName(string tier) => tier switch
    {
        "trial" => L10n.PlanTrial,
        "free" => L10n.PlanFree,
        "weekly" => L10n.PlanWeekly,
        "monthly" => L10n.PlanMonthly,
        "yearly" => L10n.PlanYearly,
        "none" => L10n.TierNone,
        _ => string.IsNullOrWhiteSpace(tier) ? L10n.TierNone : tier
    };

    private void SetHotkeyRow(Button button, Button clearButton, HotKeyConfig config, bool isRecording)
    {
        button.Content = isRecording
            ? new TextBlock
            {
                Text = L10n.PressHotkeyHint,
                FontFamily = TryFindResource("AppFont") as FontFamily ?? SystemFonts.MessageFontFamily,
                FontSize = 12,
                FontWeight = FontWeights.Medium,
                Foreground = TryFindResource("DsAccentBrush") as Brush ?? SystemColors.ControlTextBrush
            }
            : BuildHotkeyContent(config);

        clearButton.IsEnabled = !config.IsDisabled && !isRecording;
        clearButton.Opacity = clearButton.IsEnabled ? 1 : 0.35;
    }

    private static string CleanHotkeyRecordingHint(string hint)
    {
        return (hint ?? string.Empty).Trim().TrimStart('▶', '▷', '>', ' ').TrimStart();
    }

    private UIElement BuildHotkeyContent(HotKeyConfig config)
    {
        if (config.IsDisabled)
        {
            return new TextBlock
            {
                Text = L10n.HotkeyNotSet,
                FontFamily = TryFindResource("AppFont") as FontFamily ?? SystemFonts.MessageFontFamily,
                FontSize = 12,
                Foreground = TryFindResource("DsFgSubtleBrush") as Brush ?? SystemColors.GrayTextBrush
            };
        }

        var panel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center
        };

        foreach (var part in config.DisplayString.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            panel.Children.Add(new Border
            {
                Style = TryFindResource("DsKbdStyle") as Style,
                Margin = new Thickness(panel.Children.Count == 0 ? 0 : 3, 0, 0, 0),
                Child = new TextBlock
                {
                    Text = part,
                    FontFamily = TryFindResource("AppFont") as FontFamily ?? SystemFonts.MessageFontFamily,
                    FontSize = 11,
                    Foreground = TryFindResource("DsFgBrush") as Brush ?? SystemColors.ControlTextBrush,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                }
            });
        }

        return panel;
    }

    private static IReadOnlyList<CreditRow> BuildCreditRows(AuthStore auth)
    {
        if (auth.CreditItems.Count == 0)
        {
            return new[]
            {
                new CreditRow(
                    LocalizedPlanName(auth.Tier),
                    Math.Max(auth.CreditsRemaining, 0),
                    Math.Max(auth.CreditsTotal, 0),
                    Math.Max(auth.CreditsUsed, 0),
                    auth.FormattedResetDate() is { } reset
                        ? $"{L10n.AccountCreditsReset}: {reset}"
                        : L10n.CreditItemNoExpiry)
            };
        }

        return auth.CreditItems
            .Select(item => new CreditRow(
                CreditItemName(item),
                Math.Max(item.CreditsRemaining, 0),
                Math.Max(item.CreditsTotal, 0),
                Math.Max(item.CreditsUsed, 0),
                CreditExpiryText(item.ExpiresAt)))
            .ToList();
    }

    private static string CreditExpiryText(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return L10n.CreditItemNoExpiry;
        if (DateTimeOffset.TryParse(raw, out var date))
            return L10n.CreditItemExpires(date.LocalDateTime.ToShortDateString());
        return L10n.CreditItemNoExpiry;
    }

    private static string CreditItemName(CreditBalanceItem item)
    {
        return item.Type switch
        {
            "plan" => LocalizedPlanName(item.Source),
            "bonus" => L10n.CreditItemBonus,
            "paid_topup" => L10n.CreditItemPaidTopup,
            _ => string.IsNullOrWhiteSpace(item.Label) ? item.Source : item.Label
        };
    }

    private sealed class CreditRow
    {
        public CreditRow(string name, int remaining, int total, int used, string expiryText)
        {
            Name = name;
            Remaining = remaining;
            Total = total;
            Used = used;
            ExpiryText = expiryText;
        }

        public string Name { get; }
        public int Remaining { get; }
        public int Total { get; }
        public int Used { get; }
        public string ExpiryText { get; }
        public string BalanceText => Total > 0
            ? $"{Remaining}/{Total}"
            : Remaining.ToString();
        public double ProgressScale => Total > 0
            ? Math.Clamp((double)Remaining / Total, 0, 1)
            : 0;
    }

    private void OnTranscribeHotkeyClick(object sender, RoutedEventArgs e)
    {
        _vm.StartRecordingHotkey(HotKeyCombo.Transcribe);
    }

    private void OnRewriteHotkeyClick(object sender, RoutedEventArgs e)
    {
        _vm.StartRecordingHotkey(HotKeyCombo.Rewrite);
    }

    private void OnAgentHotkeyClick(object sender, RoutedEventArgs e)
    {
        _vm.StartRecordingHotkey(HotKeyCombo.Agent);
    }

    private void OnScreenshotHotkeyClick(object sender, RoutedEventArgs e)
    {
        _vm.StartRecordingHotkey(HotKeyCombo.Screenshot);
    }

    private void OnCreditDetailsToggleClick(object sender, RoutedEventArgs e)
    {
        ToggleCreditDetails();
    }

    private void ToggleCreditDetails()
    {
        _creditDetailsExpanded = !_creditDetailsExpanded;
        RefreshCredits();
    }

    private void OnTranscribeHotkeyClearClick(object sender, RoutedEventArgs e) => ClearHotkey(HotKeyCombo.Transcribe);
    private void OnRewriteHotkeyClearClick(object sender, RoutedEventArgs e) => ClearHotkey(HotKeyCombo.Rewrite);
    private void OnAgentHotkeyClearClick(object sender, RoutedEventArgs e) => ClearHotkey(HotKeyCombo.Agent);
    private void OnScreenshotHotkeyClearClick(object sender, RoutedEventArgs e) => ClearHotkey(HotKeyCombo.Screenshot);

    private void ClearHotkey(HotKeyCombo combo)
    {
        _vm.ClearHotkey(combo);
        RefreshHotkeyButtons();
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressLanguageEvent) return;
        if (LanguageCombo.SelectedItem is ComboBoxItem item &&
            item.Tag is AppLanguage lang)
        {
            LanguageManager.Instance.Current = lang;
        }
    }

    private void OnClipboardToggleChanged(object sender, RoutedEventArgs e)
    {
        ClipboardService.ClipboardAccessEnabled = ClipboardToggle.IsChecked == true;
    }

    private void OnFastModeToggleChanged(object sender, RoutedEventArgs e)
    {
        _vm.TranscribeFastModeEnabled = FastModeToggle.IsChecked == true;
    }

    private void OnRealtimeRecognitionToggleChanged(object sender, RoutedEventArgs e)
    {
        _vm.RealtimeRecognitionEnabled = RealtimeRecognitionToggle.IsChecked == true;
    }

    private void OnScreenshotConfirmToggleChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressScreenshotToggleEvent) return;
        var on = ScreenshotConfirmToggle.IsChecked == true;
        _vm.ScreenshotConfirmationEnabled = on;
        // 与长图模式互斥：开启二次确认即关闭长图模式
        if (on && LongImageModeToggle.IsChecked == true)
        {
            _suppressScreenshotToggleEvent = true;
            LongImageModeToggle.IsChecked = false;
            _vm.LongImageModeEnabled = false;
            _suppressScreenshotToggleEvent = false;
        }
    }

    private void OnLongImageModeToggleChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressScreenshotToggleEvent) return;
        var on = LongImageModeToggle.IsChecked == true;
        _vm.LongImageModeEnabled = on;
        // 与二次确认互斥：开启长图模式即关闭二次确认
        if (on && ScreenshotConfirmToggle.IsChecked == true)
        {
            _suppressScreenshotToggleEvent = true;
            ScreenshotConfirmToggle.IsChecked = false;
            _vm.ScreenshotConfirmationEnabled = false;
            _suppressScreenshotToggleEvent = false;
        }
    }

    private void OnStartupLaunchToggleChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressStartupLaunchEvent) return;
        _vm.StartupLaunchEnabled = StartupLaunchToggle.IsChecked == true;
    }

    private void OnThemeToggleChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressThemeEvent) return;
        _vm.SelectedThemeMode = ThemeToggle.IsChecked == true
            ? AppThemeMode.SandDark
            : AppThemeMode.SandLight;
    }

    private void OnAccentClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string raw } &&
            Enum.TryParse(raw, out AppAccent accent))
        {
            _vm.SelectedAccent = accent;
            RefreshAccent();
        }
    }

    private void OnMicrophoneChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressMicrophoneEvent) return;
        if (MicrophoneCombo.SelectedItem is not ComboBoxItem item) return;
        AudioRecorderService.Instance.SelectInputDevice(item.Tag as string);
    }

    private void OnInviteCodesClick(object sender, RoutedEventArgs e)
    {
        NavigateToInviteCodes?.Invoke();
    }

    private void OnTutorialRowClick(object sender, RoutedEventArgs e)
    {
        // 独立弹出教程窗口重温引导，复用单实例（AppStageWindow 点 X 只隐藏不销毁）。
        // 不重置持久化的完成标记：中途关闭窗口不影响主窗口正常使用，重启后也不会强制重走教程。
        if (_tutorialWindow == null)
        {
            _tutorialWindow = new OnboardingWindow { Owner = Window.GetWindow(this) };
            _tutorialWindow.OnboardingView.OnboardingCompleted += OnTutorialReplayCompleted;
        }

        _tutorialWindow.BringStageToFront();
    }

    private void OnTutorialReplayCompleted()
    {
        if (_tutorialWindow == null)
            return;

        _tutorialWindow.OnboardingView.OnboardingCompleted -= OnTutorialReplayCompleted;
        _tutorialWindow.CloseForTransition();
        _tutorialWindow = null;
    }

    private void OnTutorialRowKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key is not (System.Windows.Input.Key.Enter or System.Windows.Input.Key.Space))
            return;

        OnTutorialRowClick(sender, e);
        e.Handled = true;
    }

    private void OnFeedbackRowClick(object sender, RoutedEventArgs e)
    {
        var window = new FeedbackWindow { Owner = Window.GetWindow(this) };
        window.Show();
    }

    private void OnFeedbackRowKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key is not (System.Windows.Input.Key.Enter or System.Windows.Input.Key.Space))
            return;

        OnFeedbackRowClick(sender, e);
        e.Handled = true;
    }

    private void OnSubscriptionRowClick(object sender, RoutedEventArgs e)
    {
        var window = new PaymentSubscriptionWindow { Owner = Window.GetWindow(this) };
        window.ShowDialog();
        _ = RefreshPlanAfterPaymentWindowAsync();
    }

    private void OnSubscriptionRowKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key is not (System.Windows.Input.Key.Enter or System.Windows.Input.Key.Space))
            return;

        OnSubscriptionRowClick(sender, e);
        e.Handled = true;
    }

    private static async Task RefreshPlanAfterPaymentWindowAsync()
    {
        try
        {
            var info = await ApiClient.Instance.FetchUserPlanInfoAsync();
            AuthStore.Instance.UpdatePlanInfo(info);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("Settings.SubscriptionPlanRefresh", ex);
        }
    }

    private async void OnCheckUpdateClick(object sender, RoutedEventArgs e)
    {
        CheckUpdateBtn.IsEnabled = false;
        CheckUpdateBtn.Content = L10n.MenuChecking;

        try
        {
            await UpdateInteractionService.CheckDownloadAndInstallAsync(
                text => CheckUpdateBtn.Content = text,
                Window.GetWindow(this));
        }
        finally
        {
            CheckUpdateBtn.Content = L10n.MenuCheckUpdate;
            CheckUpdateBtn.IsEnabled = true;
        }
    }

    private static string? TrimmedNullIfEmpty(string? value)
    {
        var trimmed = value?.Trim();
        return string.IsNullOrEmpty(trimmed) ? null : trimmed;
    }
}
