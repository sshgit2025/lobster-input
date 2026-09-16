using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;
using Markdig;

namespace LobsterInput.Views;

public partial class HomeView : UserControl
{
    private readonly HotKeyService _hotKey = HotKeyService.Instance;
    private readonly RecordingResultStore _result = RecordingResultStore.Instance;
    private readonly HistoryStore _history = HistoryStore.Instance;
    private readonly OpenClawManager _openClaw = OpenClawManager.Instance;
    private string? _latestTranscriptCopyText;
    private string? _latestResultCopyText;
    private string? _latestSummaryCopyText;
    private string? _latestRecordId;
    private bool _latestDetailsExpanded;
    private static readonly MarkdownPipeline MarkdownPipeline =
        new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();

    public HomeView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _result.PropertyChanged += OnStoreChanged;
        _history.PropertyChanged += OnStoreChanged;
        _openClaw.PropertyChanged += OnStoreChanged;
        _hotKey.PropertyChanged += OnStoreChanged;
        LanguageManager.Instance.PropertyChanged += OnStoreChanged;
        ThemeManager.Instance.PropertyChanged += OnStoreChanged;
        Refresh();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _result.PropertyChanged -= OnStoreChanged;
        _history.PropertyChanged -= OnStoreChanged;
        _openClaw.PropertyChanged -= OnStoreChanged;
        _hotKey.PropertyChanged -= OnStoreChanged;
        LanguageManager.Instance.PropertyChanged -= OnStoreChanged;
        ThemeManager.Instance.PropertyChanged -= OnStoreChanged;
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e) => Refresh();

    private void Refresh()
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(Refresh);
            return;
        }

        RefreshOpenClaw();
        RefreshHotkeys();
        RefreshLatest();
        HomePageTitle.Text = L10n.PageHome;
    }

    private void RefreshOpenClaw()
    {
        OpenClawCard.Visibility = _openClaw.Status == OpenClawStatus.Unknown
            ? Visibility.Collapsed
            : Visibility.Visible;
        OpenClawUninstallBtn.ToolTip = L10n.OpenclawUninstallBtn;
        OpenClawHint.Text = L10n.OpenclawMinVersion;
        OpenClawPrimaryBtn.IsEnabled = !_openClaw.IsStartingGateway;

        switch (_openClaw.Status)
        {
            case OpenClawStatus.NotInstalled:
                OpenClawTitle.Text = L10n.OpenclawPromoTitle;
                OpenClawDesc.Text = L10n.OpenclawPromoDesc;
                OpenClawPrimaryBtn.Content = L10n.OpenclawInstallBtn;
                OpenClawUninstallBtn.Visibility = Visibility.Collapsed;
                break;
            case OpenClawStatus.InstalledServiceDown:
                OpenClawTitle.Text = L10n.OpenclawServiceDownTitle;
                OpenClawDesc.Text = L10n.OpenclawServiceDownDesc;
                OpenClawPrimaryBtn.Content = _openClaw.IsStartingGateway
                    ? L10n.OpenclawStartingGateway
                    : L10n.OpenclawStartBtn;
                OpenClawUninstallBtn.Visibility = Visibility.Visible;
                break;
            case OpenClawStatus.Ready:
                OpenClawTitle.Text = L10n.OpenclawInstalledTitle;
                OpenClawDesc.Text = L10n.OpenclawInstalledDesc;
                OpenClawPrimaryBtn.Content = L10n.OpenclawStopBtn;
                OpenClawUninstallBtn.Visibility = Visibility.Visible;
                break;
        }
    }

    private void RefreshHotkeys()
    {
        HotkeySectionLabel.Text = L10n.SectionHotkeys;

        HotkeyTranscribeLabel.Text = L10n.HotkeyTranscribe;
        HotkeyTranscribeValue.Content = BuildHotkeyContent(_hotKey.Configs[HotKeyCombo.Transcribe]);

        HotkeyRewriteLabel.Text = L10n.HotkeyRewrite;
        HotkeyRewriteValue.Content = BuildHotkeyContent(_hotKey.Configs[HotKeyCombo.Rewrite]);

        HotkeyAgentLabel.Text = L10n.HotkeyAgent;
        HotkeyAgentValue.Content = BuildHotkeyContent(_hotKey.Configs[HotKeyCombo.Agent]);

        HotkeyScreenshotLabel.Text = L10n.HotkeyScreenshotTitle;
        HotkeyScreenshotValue.Content = BuildHotkeyContent(_hotKey.Configs[HotKeyCombo.Screenshot]);
    }

    private void RefreshLatest()
    {
        LatestSectionLabel.Text = L10n.SectionLatest;
        LatestMetaText.Text = "";
        TranscriptLabel.Text = L10n.LabelTranscript;
        ResultLabel.Text = L10n.LabelResult;
        ResetCopyButton(LatestSummaryCopyBtn, L10n.BtnCopy);
        ResetCopyButton(TranscriptCopyBtn, $"{L10n.BtnCopy} {L10n.LabelTranscript}");
        ResetCopyButton(ResultCopyBtn, $"{L10n.BtnCopy} {L10n.LabelResult}");
        LatestRetryBtn.Content = "\uE72C";
        LatestRetryBtn.ToolTip = L10n.Retry;
        LatestDetailsToggleBtn.Content = _latestDetailsExpanded ? "\uE70E" : "\uE70D";
        LatestDetailsToggleBtn.ToolTip = _latestDetailsExpanded ? L10n.AccountCreditsDetailsHide : L10n.AccountCreditsDetailsShow;

        var latest = _history.Records.FirstOrDefault();
        if (latest == null)
        {
            _latestRecordId = null;
            _latestDetailsExpanded = false;
            LatestDetailsToggleBtn.Content = "\uE70D";
            LatestDetailsToggleBtn.ToolTip = L10n.AccountCreditsDetailsShow;
            _latestTranscriptCopyText = string.IsNullOrWhiteSpace(_result.Transcript) ? null : _result.Transcript;
            _latestResultCopyText = string.IsNullOrWhiteSpace(_result.Result) ? null : _result.Result;
            _latestSummaryCopyText = _latestResultCopyText ?? _latestTranscriptCopyText;
            TranscriptText.Text = _latestTranscriptCopyText ?? "--";
            ResultText.Text = _latestResultCopyText ?? L10n.NoResult;
            TranscriptDetailText.Text = TranscriptText.Text;
            ResultDetailText.Text = ResultText.Text;
            LatestMarkdownScroll.Visibility = Visibility.Collapsed;
            LatestDetailsPanel.Visibility = Visibility.Collapsed;
            LatestRetryBtn.Visibility = Visibility.Collapsed;
            LatestDetailsToggleBtn.Visibility = HasLatestDetails()
                ? Visibility.Visible
                : Visibility.Collapsed;
            RefreshLatestCopyButtons();
            return;
        }

        if (_latestRecordId != latest.Id)
        {
            _latestRecordId = latest.Id;
            _latestDetailsExpanded = false;
        }

        LatestMetaText.Text = LatestMeta(latest);
        TranscriptText.Text = LatestTranscriptText(latest);
        _latestTranscriptCopyText = latest.Status == RecordingStatus.Success && !string.IsNullOrWhiteSpace(latest.Transcript)
            ? latest.Transcript
            : null;
        _latestResultCopyText = latest.Status == RecordingStatus.Success && !string.IsNullOrWhiteSpace(latest.Result)
            ? latest.Result
            : null;
        _latestSummaryCopyText = _latestResultCopyText ?? _latestTranscriptCopyText;
        RefreshLatestResult(latest);
        LatestRetryBtn.Tag = latest.Id;
        LatestRetryBtn.Visibility = CanRetry(latest)
                ? Visibility.Visible
                : Visibility.Collapsed;
        LatestDetailsToggleBtn.Visibility = HasLatestDetails()
            ? Visibility.Visible
            : Visibility.Collapsed;
        LatestDetailsPanel.Visibility = _latestDetailsExpanded
            ? Visibility.Visible
            : Visibility.Collapsed;
        LatestDetailsToggleBtn.Content = _latestDetailsExpanded ? "\uE70E" : "\uE70D";
        RefreshLatestCopyButtons();
    }

    private static string LatestMeta(RecordingHistory latest)
    {
        var time = latest.CreatedAt.ToLocalTime().ToString("HH:mm:ss");
        return latest.ProcessingDuration.HasValue
            ? $"{time} · {latest.ProcessingDuration.Value:0.0}s"
            : time;
    }

    private static string LatestTranscriptText(RecordingHistory latest)
    {
        if (latest.Status is RecordingStatus.Pending or RecordingStatus.Processing)
            return L10n.Recognizing;
        return string.IsNullOrWhiteSpace(latest.Transcript) ? "--" : latest.Transcript;
    }

    private static string LatestResultText(RecordingHistory latest)
    {
        if (latest.Status == RecordingStatus.Failed)
            return string.IsNullOrWhiteSpace(latest.ErrorMessage)
                ? L10n.RecognizeFailed
                : latest.ErrorMessage;
        return string.IsNullOrWhiteSpace(latest.Result) ? L10n.NoResult : latest.Result;
    }

    private void RefreshLatestResult(RecordingHistory latest)
    {
        var result = LatestResultText(latest);
        ResultText.Visibility = Visibility.Visible;
        ResultText.Text = result;
        TranscriptDetailText.Text = LatestTranscriptText(latest);
        ResultDetailText.Text = result;

        if (latest.ResultIsMarkdown && !string.IsNullOrWhiteSpace(latest.Result))
        {
            var doc = Markdig.Wpf.Markdown.ToFlowDocument(latest.Result, MarkdownPipeline);
            doc.PagePadding = new Thickness(0);
            MarkdownTheme.Apply(doc, this);
            LatestMarkdownContent.Document = doc;
            LatestMarkdownScroll.Visibility = Visibility.Visible;
            ResultDetailText.Visibility = Visibility.Collapsed;
            return;
        }

        ResultDetailText.Visibility = Visibility.Visible;
        LatestMarkdownScroll.Visibility = Visibility.Collapsed;
    }

    private void RefreshLatestCopyButtons()
    {
        LatestSummaryCopyBtn.Visibility = string.IsNullOrWhiteSpace(_latestSummaryCopyText)
            ? Visibility.Collapsed
            : Visibility.Visible;
        TranscriptCopyBtn.Visibility = string.IsNullOrWhiteSpace(_latestTranscriptCopyText)
            ? Visibility.Collapsed
            : Visibility.Visible;
        ResultCopyBtn.Visibility = string.IsNullOrWhiteSpace(_latestResultCopyText)
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private bool HasLatestDetails() =>
        !string.IsNullOrWhiteSpace(_latestTranscriptCopyText)
        || !string.IsNullOrWhiteSpace(_latestResultCopyText);

    private static bool CanRetry(RecordingHistory rec) =>
        (rec.Status is RecordingStatus.Success or RecordingStatus.Failed) &&
        rec.Retryable &&
        rec.AudioFileExists;

    private async void OnOpenClawPrimaryClick(object sender, RoutedEventArgs e)
    {
        if (_openClaw.Status == OpenClawStatus.NotInstalled)
            await _openClaw.InstallAsync();
        else if (_openClaw.Status == OpenClawStatus.InstalledServiceDown)
            await _openClaw.StartGatewayAsync();
        else if (_openClaw.Status == OpenClawStatus.Ready)
            await _openClaw.StopGatewayAsync();
    }

    private async void OnOpenClawUninstallClick(object sender, RoutedEventArgs e)
    {
        var result = AppConfirmDialog.Show(
            Window.GetWindow(this),
            L10n.OpenclawUninstallConfirmTitle,
            L10n.OpenclawUninstallConfirmMessage,
            L10n.OpenclawUninstallBtn);
        if (result != AppConfirmDialogResult.Primary)
            return;

        await _openClaw.UninstallAsync();
    }

    private void OnLatestRetryClick(object sender, RoutedEventArgs e)
    {
        if (LatestRetryBtn.Tag is not string id) return;
        var rec = _history.Records.FirstOrDefault(r => r.Id == id);
        if (rec?.AudioFileExists != true) return;

        _history.Update(id, RecordingStatus.Processing, error: null);
        _ = HotKeyHandler.Instance.ProcessRecordAsync(
            rec.Id, rec.Operation, rec.AudioFilePath, rec.SelectedText);
    }

    private void OnLatestCopyTranscriptClick(object sender, RoutedEventArgs e)
    {
        CopyLatestText(_latestTranscriptCopyText, TranscriptCopyBtn);
    }

    private void OnLatestCopySummaryClick(object sender, RoutedEventArgs e)
    {
        CopyLatestText(_latestSummaryCopyText, LatestSummaryCopyBtn);
    }

    private void OnLatestCopyResultClick(object sender, RoutedEventArgs e)
    {
        CopyLatestText(_latestResultCopyText, ResultCopyBtn);
    }

    private void OnLatestDetailsToggleClick(object sender, RoutedEventArgs e)
    {
        _latestDetailsExpanded = !_latestDetailsExpanded;
        RefreshLatest();
    }

    private static void CopyLatestText(string? text, Button button)
    {
        if (string.IsNullOrWhiteSpace(text))
            return;

        try
        {
            ClipboardService.SetText(text);
            button.Content = "\uE73E";
            button.ToolTip = L10n.BtnCopied;
            button.Foreground = Application.Current.TryFindResource("DsSuccessBrush") as Brush
                ?? new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A));
        }
        catch
        {
            // Clipboard can be locked by another process.
        }
    }

    private static void ResetCopyButton(Button button, string tooltip)
    {
        button.Content = "\uE8C8";
        button.ToolTip = tooltip;
        button.Foreground = Application.Current.TryFindResource("DsFgSubtleBrush") as Brush
            ?? SystemColors.GrayTextBrush;
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
            HorizontalAlignment = HorizontalAlignment.Right
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
}
