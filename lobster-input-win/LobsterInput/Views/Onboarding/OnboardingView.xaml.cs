using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.ComponentModel;
using LobsterInput.Helpers;
using LobsterInput.Services;
using LobsterInput.ViewModels;

namespace LobsterInput.Views.Onboarding;

public partial class OnboardingView : UserControl
{
    private OnboardingViewModel VM => (OnboardingViewModel)DataContext;

    private readonly Ellipse[] _dots;
    private readonly UIElement[] _steps;
    private bool _globalSubscriptionsActive;

    public event Action? OnboardingCompleted;

    public OnboardingView()
    {
        InitializeComponent();

        _dots = new[] { Dot0, Dot1, Dot2, Dot3, Dot4, Dot5, Dot6, Dot7, Dot8 };
        _steps = new UIElement[] { Step0, Step1, Step2, Step3, Step4, Step5, Step6, Step7, Step8 };

        VM.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(OnboardingViewModel.CurrentStep))
                UpdateUI();
        };

        VM.OnComplete += () => OnboardingCompleted?.Invoke();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;

        PopulateLocalizedText();
        UpdateUI();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_globalSubscriptionsActive)
            return;

        ThemeManager.Instance.PropertyChanged += OnThemeManagerChanged;
        LanguageManager.Instance.PropertyChanged += OnLanguageManagerChanged;
        _globalSubscriptionsActive = true;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (!_globalSubscriptionsActive)
            return;

        ThemeManager.Instance.PropertyChanged -= OnThemeManagerChanged;
        LanguageManager.Instance.PropertyChanged -= OnLanguageManagerChanged;
        _globalSubscriptionsActive = false;
    }

    private void OnThemeManagerChanged(object? sender, PropertyChangedEventArgs e)
    {
        InvokeOnUi(UpdateUI);
    }

    private void OnLanguageManagerChanged(object? sender, PropertyChangedEventArgs e)
    {
        InvokeOnUi(() =>
        {
            PopulateLocalizedText();
            UpdateUI();
        });
    }

    private void InvokeOnUi(Action action)
    {
        if (Dispatcher.CheckAccess())
            action();
        else
            Dispatcher.Invoke(action);
    }

    private void PopulateLocalizedText()
    {
        var configs = HotKeyService.Instance.Configs;

        WelcomeTitle.Text = L10n.OnboardingWelcomeTitle;
        WelcomeDesc.Text = L10n.OnboardingWelcomeDesc;
        Feature1Title.Text = L10n.OnboardingFeature1Title;
        Feature1Desc.Text = L10n.OnboardingFeature1Desc;
        Feature2Title.Text = L10n.OnboardingFeature2Title;
        Feature2Desc.Text = L10n.OnboardingFeature2Desc;
        Feature3Title.Text = L10n.OnboardingFeature3Title;
        Feature3Desc.Text = L10n.OnboardingFeature3Desc;

        PopulateShortcutStep();

        TriFillTitle.Text = L10n.ObTriFillTitle;
        TriFillSub.Text = L10n.ObTriFillSub;
        TriFillFieldLabel.Text = L10n.ObTriFillFieldLabel;
        TriFillHowLabel.Text = L10n.OnboardingHowToUse;
        TriFillI1.Text = "1. " + L10n.ObTriFillI1;
        TriFillI2.Text = "2. " + L10n.ObTriFillI2;
        TriFillI3.Text = "3. " + L10n.ObTriFillI3;

        RwGenTitle.Text = L10n.ObRwGenTitle;
        RwGenSub.Text = L10n.ObRwGenSub;
        RwGenFieldLabel.Text = L10n.ObRwGenFieldLabel;
        RwGenHowLabel.Text = L10n.OnboardingHowToUse;
        RwGenI1.Text = "1. " + L10n.ObRwGenI1;
        RwGenI2.Text = "2. " + L10n.ObRwGenI2;
        RwGenI3.Text = "3. " + L10n.ObRwGenI3;

        RwRoTitle.Text = L10n.ObRwRoTitle;
        RwRoSub.Text = L10n.ObRwRoSub;
        RwRoSelectHint.Text = L10n.ObRwRoSelectHint;
        RwRoSampleText.Text = L10n.ObRwRoSampleText;
        RwRoHowLabel.Text = L10n.OnboardingHowToUse;
        RwRoI1.Text = "1. " + L10n.ObRwRoI1;
        RwRoI2.Text = "2. " + L10n.ObRwRoI2;
        RwRoI3.Text = "3. " + L10n.ObRwRoI3;

        RwEdTitle.Text = L10n.ObRwEdTitle;
        RwEdSub.Text = L10n.ObRwEdSub;
        RwEdFieldLabel.Text = L10n.ObRwEdFieldLabel;
        RwEdHowLabel.Text = L10n.OnboardingHowToUse;
        RwEdI1.Text = "1. " + L10n.ObRwEdI1;
        RwEdI2.Text = "2. " + L10n.ObRwEdI2;
        RwEdI3.Text = "3. " + L10n.ObRwEdI3;

        ShotOcrTitle.Text = L10n.ObScrTitle;
        ShotOcrSub.Text = L10n.ObScrSub;
        ShotOcrFieldLabel.Text = L10n.ObScrSelectHint;
        ShotOcrSampleText.Text = L10n.ObScrSampleText;
        ShotOcrHowLabel.Text = L10n.OnboardingHowToUse;
        ShotOcrI1.Text = "1. " + L10n.ObScrI1(configs[HotKeyCombo.Screenshot].DisplayString);
        ShotOcrI2.Text = "2. " + L10n.ObScrI2(configs[HotKeyCombo.Rewrite].DisplayString);
        ShotOcrI3.Text = "3. " + L10n.ObScrI3;
        ShotOcrI4.Text = "4. " + L10n.ObScrI4(configs[HotKeyCombo.Rewrite].DisplayString);

        AgSearchTitle.Text = L10n.ObAgSearchTitle;
        AgSearchSub.Text = L10n.ObAgSearchSub;
        AgSearchExLabel.Text = L10n.ObAgSearchExampleLabel;
        AgSearchEx1.Text = L10n.ObAgSearchEx1;
        AgSearchEx2.Text = L10n.ObAgSearchEx2;
        AgSearchEx3.Text = L10n.ObAgSearchEx3;
        AgSearchHowLabel.Text = L10n.OnboardingHowToUse;
        AgSearchI1.Text = "1. " + L10n.ObAgSearchI1;
        AgSearchI2.Text = "2. " + L10n.ObAgSearchI2;
        AgSearchI3.Text = "3. " + L10n.ObAgSearchI3;

        CompleteTitle.Text = L10n.OnboardingCompleteTitle;
        CompleteDesc.Text = L10n.OnboardingCompleteDesc;

        CompleteHk1Label.Text = L10n.HotkeyTranscribe;
        CompleteHk1Key.Text = configs[HotKeyCombo.Transcribe].DisplayString;
        CompleteHk2Label.Text = L10n.HotkeyRewrite;
        CompleteHk2Key.Text = configs[HotKeyCombo.Rewrite].DisplayString;
        CompleteHk3Label.Text = L10n.HotkeyAgent;
        CompleteHk3Key.Text = configs[HotKeyCombo.Agent].DisplayString;
        CompleteHk4Label.Text = L10n.HotkeyScreenshotTitle;
        CompleteHk4Key.Text = configs[HotKeyCombo.Screenshot].DisplayString;
    }

    private void UpdateUI()
    {
        var step = VM.CurrentStep;

        for (var i = 0; i < _steps.Length; i++)
            _steps[i].Visibility = i == step ? Visibility.Visible : Visibility.Collapsed;

        var activeBrush = TryFindResource("NeonCyanBrush") as SolidColorBrush
                          ?? new SolidColorBrush(Color.FromRgb(156, 125, 91));
        var dimBrush = TryFindResource("TextMutedBrush") as SolidColorBrush
                       ?? new SolidColorBrush(Color.FromRgb(216, 207, 190));
        var doneBrush = TryFindResource("NeonGreenBrush") as SolidColorBrush
                        ?? new SolidColorBrush(Color.FromRgb(156, 125, 91));
        var focusBrush = TryFindResource("DsAccentRingBrush") as Brush
                         ?? activeBrush;

        for (var i = 0; i < _dots.Length; i++)
        {
            _dots[i].Stroke = _dots[i].IsKeyboardFocused
                ? focusBrush
                : i == step
                ? activeBrush
                : Brushes.Transparent;
            _dots[i].StrokeThickness = _dots[i].IsKeyboardFocused ? 2 : 0;

            if (i == step)
                _dots[i].Fill = activeBrush;
            else if (i < step)
                _dots[i].Fill = doneBrush;
            else
                _dots[i].Fill = dimBrush;
        }

        StepCounter.Text = $"{step + 1} / {VM.TotalSteps}";

        BackBtn.Visibility = VM.CanGoBack ? Visibility.Visible : Visibility.Hidden;
        BackBtn.Content = L10n.OnboardingBack;

        SkipBtn.Content = L10n.OnboardingSkip;
        SkipBtn.Visibility = VM.IsLastStep ? Visibility.Collapsed : Visibility.Visible;

        if (VM.IsLastStep)
        {
            NextBtn.Content = L10n.OnboardingStart;
        }
        else
        {
            NextBtn.Content = L10n.OnboardingNext;
        }

        NextBtn.IsEnabled = VM.CanGoNext;

        PopulateShortcutStep();
        UpdateStepHotkeyBadge(step);
    }

    private void PopulateShortcutStep()
    {
        var configs = HotKeyService.Instance.Configs;
        ShortcutTitle.Text = L10n.ObShortcutTitle;
        ShortcutDesc.Text = L10n.ObShortcutDesc;

        ShortcutTranscribeKey.Text = configs[HotKeyCombo.Transcribe].DisplayString;
        ShortcutTranscribeTitle.Text = L10n.HotkeyTranscribe;
        ShortcutTranscribeDesc.Text = L10n.ObShortcutTranscribeDesc;

        ShortcutRewriteKey.Text = configs[HotKeyCombo.Rewrite].DisplayString;
        ShortcutRewriteTitle.Text = L10n.HotkeyRewrite;
        ShortcutRewriteDesc.Text = L10n.ObShortcutRewriteDesc;

        ShortcutAgentKey.Text = configs[HotKeyCombo.Agent].DisplayString;
        ShortcutAgentTitle.Text = L10n.HotkeyAgent;
        ShortcutAgentDesc.Text = L10n.ObShortcutAgentDesc;

        ShortcutScreenshotKey.Text = configs[HotKeyCombo.Screenshot].DisplayString;
        ShortcutScreenshotTitle.Text = L10n.HotkeyScreenshotTitle;
        ShortcutScreenshotDesc.Text = L10n.ObShortcutScreenshotDesc;
    }

    private void UpdateStepHotkeyBadge(int step)
    {
        var configs = HotKeyService.Instance.Configs;
        var cyan = TryFindResource("NeonCyanBrush") as Brush ?? Brushes.Cyan;
        var green = TryFindResource("NeonGreenBrush") as Brush ?? Brushes.LimeGreen;
        var orange = TryFindResource("NeonOrangeBrush") as Brush ?? Brushes.Orange;

        Brush brush;
        string label;
        string key;
        string icon;

        switch (step)
        {
            case 0:
                brush = cyan;
                label = L10n.ObBadgeGuideHotkeys;
                key = HotkeySummary(
                    HotKeyCombo.Transcribe,
                    HotKeyCombo.Rewrite,
                    HotKeyCombo.Agent,
                    HotKeyCombo.Screenshot);
                icon = "\uE765";
                break;
            case 1:
                brush = cyan;
                label = L10n.ObBadgeHotkeyOverview;
                key = HotkeySummary(
                    HotKeyCombo.Transcribe,
                    HotKeyCombo.Rewrite,
                    HotKeyCombo.Agent,
                    HotKeyCombo.Screenshot);
                icon = "\uE765";
                break;
            case 2:
                brush = cyan;
                label = L10n.HotkeyTranscribe;
                key = configs[HotKeyCombo.Transcribe].DisplayString;
                icon = "\uE720";
                break;
            case 3:
            case 4:
            case 5:
                brush = green;
                label = L10n.HotkeyRewrite;
                key = configs[HotKeyCombo.Rewrite].DisplayString;
                icon = "\uE104";
                break;
            case 6:
                brush = green;
                label = L10n.ObBadgeScreenshotRewrite;
                key = $"{configs[HotKeyCombo.Screenshot].DisplayString} / {configs[HotKeyCombo.Rewrite].DisplayString}";
                icon = "\uE722";
                break;
            case 7:
                brush = orange;
                label = L10n.HotkeyAgent;
                key = configs[HotKeyCombo.Agent].DisplayString;
                icon = "\uE8B8";
                break;
            default:
                brush = green;
                label = L10n.ObBadgeCommonHotkeys;
                key = HotkeySummary(
                    HotKeyCombo.Transcribe,
                    HotKeyCombo.Rewrite,
                    HotKeyCombo.Screenshot);
                icon = "\uE73E";
                break;
        }

        StepHotkeyLabel.Text = label;
        StepHotkeyKey.Text = key;
        StepHotkeyIcon.Text = icon;
        StepHotkeyBadge.BorderBrush = brush;
        StepHotkeyIcon.Foreground = brush;
        StepHotkeyKey.Foreground = brush;
        StepHotkeyBadge.Effect = new DropShadowEffect
        {
            Color = brush is SolidColorBrush solid ? solid.Color : Colors.Cyan,
            BlurRadius = 8,
            ShadowDepth = 0,
            Opacity = 0.25
        };
    }

    private static string HotkeySummary(params HotKeyCombo[] combos)
    {
        var configs = HotKeyService.Instance.Configs;
        var values = new string[combos.Length];
        for (var i = 0; i < combos.Length; i++)
            values[i] = configs[combos[i]].DisplayString;
        return string.Join(" / ", values);
    }

    private void Dot_Click(object sender, MouseButtonEventArgs e)
    {
        if (sender is not Ellipse dot) return;
        TryNavigateToDot(dot);
    }

    private void Dot_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Enter or Key.Space))
            return;

        if (sender is Ellipse dot)
            TryNavigateToDot(dot);

        e.Handled = true;
    }

    private void Dot_FocusChanged(object sender, KeyboardFocusChangedEventArgs e) => UpdateUI();

    private void TryNavigateToDot(Ellipse dot)
    {
        if (dot.Tag is not string tagStr || !int.TryParse(tagStr, out var idx))
            return;

        if (idx <= VM.CurrentStep || idx == VM.CurrentStep + 1)
            VM.CurrentStep = idx;
    }

    private void Back_Click(object sender, RoutedEventArgs e)
    {
        VM.BackCommand.Execute(null);
    }

    private void Next_Click(object sender, RoutedEventArgs e)
    {
        VM.NextCommand.Execute(null);
    }

    private void Skip_Click(object sender, RoutedEventArgs e)
    {
        VM.SkipToEndCommand.Execute(null);
    }

}
