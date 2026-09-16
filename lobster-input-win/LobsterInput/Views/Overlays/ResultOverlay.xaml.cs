using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Media3D;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using LobsterInput.Helpers;
using LobsterInput.Services;
using Markdig;

namespace LobsterInput.Views.Overlays;

public partial class ResultOverlay : Window
{
    private const int DefaultCountdownSeconds = 30;
    private const double SearchOverlayMinHeight = 260;
    private const double SearchOverlayMaxHeight = 620;
    private const double PlainOverlayMinHeight = 180;
    private const double PlainOverlayMaxHeight = 520;

    public event EventHandler? Dismissed;

    private Action? _onDismiss;
    private DispatcherTimer? _countdownTimer;
    private int _remainingSeconds;
    private bool _isPinned;
    private bool _isMarkdownMode;
    private bool _wasManuallyResized;
    private string _currentText = string.Empty;
    private int _dismissGeneration;
    private Guid? _activeMarkdownStreamId;
    private static readonly MarkdownPipeline MarkdownPipeline =
        new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();

    public ResultOverlay()
    {
        InitializeComponent();
        ApplyLocalization();
        LanguageManager.Instance.PropertyChanged += (_, _) => Dispatcher.Invoke(ApplyLocalization);
    }

    private void ApplyLocalization()
    {
        if (CopyIcon.Text != AppIcons.Success)
            ResetCopyVisual();
        CloseBtn.ToolTip = L10n.AgreementClose;
        CloseIcon.Text = AppIcons.Close;
        if (IsVisible)
        {
            TitleText.Text = _isMarkdownMode ? L10n.OverlaySearchTitle : L10n.OverlayResultTitle;
            UpdatePinVisual();
        }
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        if (!_isMarkdownMode)
        {
            ApplyNoActivateStyle();
        }
    }

    private void ApplyNoActivateStyle()
    {
        WindowInteropTools.ApplyNoActivate(this);
    }

    public void ShowResult(string text, Action? onDismiss = null)
    {
        PrepareForNewPresentation();
        _isMarkdownMode = false;
        _isPinned = false;
        _wasManuallyResized = false;
        _currentText = text;
        _onDismiss = onDismiss;

        PlainTextContent.Text = text;
        TitleText.Text = L10n.OverlayResultTitle;
        HeaderIcon.Text = AppIcons.Result;
        PlainTextContent.Visibility = Visibility.Visible;
        MarkdownScroll.Visibility = Visibility.Collapsed;
        RootCard.BorderBrush = (Brush)FindResource("BorderDimBrush");
        ResetCopyVisual();

        ShowActivated = false;
        ApplyPreferredSize(text, false);
        UpdatePinVisual();
        PositionOnScreen();
        Show();
        DebugTrace.Log("ResultOverlay", $"show result text={text.Length}, generation={_dismissGeneration}");

        StartCountdown(DefaultCountdownSeconds);

        if (TryFindResource("FadeIn") is Storyboard fadeIn)
            fadeIn.Begin();
        else
            RootCard.Opacity = 1;
    }

    public void ShowMarkdown(string markdownText, bool pinned = false, Action? onDismiss = null)
    {
        _activeMarkdownStreamId = null;
        PrepareForNewPresentation();
        _isMarkdownMode = true;
        _isPinned = pinned;
        _wasManuallyResized = false;
        _currentText = markdownText;
        _onDismiss = onDismiss;

        PlainTextContent.Visibility = Visibility.Collapsed;
        TitleText.Text = L10n.OverlaySearchTitle;
        HeaderIcon.Text = AppIcons.Search;
        MarkdownScroll.Visibility = Visibility.Visible;
        RootCard.BorderBrush = (Brush)FindResource("NeonCyanBrush");
        ResetCopyVisual();

        var doc = Markdig.Wpf.Markdown.ToFlowDocument(markdownText, MarkdownPipeline);
        doc.PagePadding = new Thickness(0);
        MarkdownTheme.Apply(doc, this);
        MarkdownContent.Document = doc;

        ShowActivated = true;
        ApplyPreferredSize(markdownText, true);
        UpdatePinVisual();
        PositionOnScreen();
        Show();
        DebugTrace.Log("ResultOverlay", $"show markdown text={markdownText.Length}, generation={_dismissGeneration}");

        if (pinned)
        {
            StopCountdown();
        }
        else
        {
            StartCountdown(DefaultCountdownSeconds);
        }

        if (TryFindResource("FadeIn") is Storyboard fadeIn)
            fadeIn.Begin();
        else
            RootCard.Opacity = 1;
    }

    public void UpdateMarkdown(string markdownText)
    {
        if (!IsVisible || !_isMarkdownMode)
        {
            ShowMarkdown(markdownText);
            return;
        }

        _currentText = markdownText;
        ResetCopyVisual();
        var doc = Markdig.Wpf.Markdown.ToFlowDocument(markdownText, MarkdownPipeline);
        doc.PagePadding = new Thickness(0);
        MarkdownTheme.Apply(doc, this);
        MarkdownContent.Document = doc;
        GrowMarkdownOverlayIfNeeded(markdownText);
    }

    public void UpdateMarkdown(string markdownText, Guid streamId)
    {
        if (markdownText.Length == 0)
        {
            _activeMarkdownStreamId = streamId;
            return;
        }

        if (_activeMarkdownStreamId.HasValue && _activeMarkdownStreamId.Value != streamId)
        {
            DebugTrace.Log("ResultOverlay", $"Ignored stale markdown stream update: streamId={streamId}");
            return;
        }

        _activeMarkdownStreamId ??= streamId;
        UpdateMarkdown(markdownText);
        _activeMarkdownStreamId = streamId;
    }

    private void PositionOnScreen()
    {
        WindowInteropTools.PositionCenteredNearBottom(this, 44);
    }

    private void ApplyPreferredSize(string text, bool isMarkdown)
    {
        var screen = WindowInteropTools.CursorWorkAreaDip();
        var maxWidth = Math.Min(isMarkdown ? 860 : 760, screen.Width * 0.86);
        var minWidth = isMarkdown ? 560 : 420;
        var longest = text.Split('\n').Select(s => s.Length).DefaultIfEmpty(text.Length).Max();
        var targetWidth = longest * 7.2 + 96;
        Width = Math.Clamp(targetWidth, minWidth, maxWidth);

        var columns = Math.Max(28, (int)((Width - 64) / 7.2));
        var lines = text.Split('\n').Sum(line => Math.Max(1, (int)Math.Ceiling((double)line.Length / columns)));
        var contentHeight = lines * (isMarkdown ? 20 : 19);
        var maxHeight = Math.Min(isMarkdown ? SearchOverlayMaxHeight : PlainOverlayMaxHeight, screen.Height * 0.72);
        var minHeight = isMarkdown ? SearchOverlayMinHeight : PlainOverlayMinHeight;
        Height = Math.Clamp(contentHeight + 92, minHeight, maxHeight);
        MaxWidth = screen.Width - 32;
        MaxHeight = isMarkdown
            ? Math.Min(SearchOverlayMaxHeight, screen.Height - 32)
            : screen.Height - 32;
    }

    private void GrowMarkdownOverlayIfNeeded(string markdownText)
    {
        if (!_isMarkdownMode || !IsVisible || _wasManuallyResized)
            return;

        var screen = WindowInteropTools.CursorWorkAreaDip();
        MaxHeight = Math.Min(SearchOverlayMaxHeight, screen.Height - 32);

        var columns = Math.Max(28, (int)((Width - 64) / 7.2));
        var lines = markdownText.Split('\n').Sum(line => Math.Max(1, (int)Math.Ceiling((double)line.Length / columns)));
        var contentHeight = lines * 20;
        var preferredHeight = Math.Clamp(contentHeight + 92, SearchOverlayMinHeight, Math.Min(SearchOverlayMaxHeight, screen.Height * 0.72));
        var targetHeight = Math.Min(MaxHeight, Math.Max(Height, preferredHeight));
        if (targetHeight <= Height + 1)
            return;

        var bottom = Top + Height;
        Height = targetHeight;
        Top = Math.Clamp(bottom - targetHeight, screen.Top + 16, screen.Bottom - targetHeight - 16);
        WindowInteropTools.ClampToCursorWorkArea(this);
    }

    private void StartCountdown(int seconds)
    {
        StopCountdown();
        _remainingSeconds = seconds;
        UpdateCountdownText();

        _countdownTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _countdownTimer.Tick += OnCountdownTick;
        _countdownTimer.Start();
    }

    private void StopCountdown()
    {
        _countdownTimer?.Stop();
        _countdownTimer = null;
        CountdownText.Text = "";
    }

    private void OnCountdownTick(object? sender, EventArgs e)
    {
        _remainingSeconds--;
        if (_remainingSeconds <= 0)
        {
            DismissOverlay();
            return;
        }
        UpdateCountdownText();
    }

    private void UpdateCountdownText()
    {
        CountdownText.Text = $"{_remainingSeconds}s";
    }

    private void UpdatePinVisual()
    {
        if (_isPinned)
        {
            PinIcon.Text = AppIcons.Pinned;
            PinIcon.Foreground = (System.Windows.Media.Brush)FindResource("NeonCyanBrush");
            FooterStatus.Text = L10n.OverlayResultPinned;
            PinBtn.ToolTip = L10n.BtnUnpin;
        }
        else
        {
            PinIcon.Text = AppIcons.Pin;
            PinIcon.Foreground = (System.Windows.Media.Brush)FindResource("TextDimBrush");
            FooterStatus.Text = "";
            PinBtn.ToolTip = L10n.BtnPin;
        }
    }

    public void DismissOverlay()
    {
        var generation = ++_dismissGeneration;
        DebugTrace.Log("ResultOverlay", $"dismiss requested generation={generation}, visible={IsVisible}");
        StopCountdown();

        if (TryFindResource("FadeOut") is not Storyboard fadeOut)
        {
            Hide();
            ClearPresentationState();
            _onDismiss?.Invoke();
            Dismissed?.Invoke(this, EventArgs.Empty);
            DebugTrace.Log("ResultOverlay", $"dismiss immediate generation={generation}");
            return;
        }

        EventHandler? completed = null;
        completed = (_, _) =>
        {
            fadeOut.Completed -= completed;
            if (generation == _dismissGeneration)
            {
                Hide();
                ClearPresentationState();
                _onDismiss?.Invoke();
                Dismissed?.Invoke(this, EventArgs.Empty);
                DebugTrace.Log("ResultOverlay", $"dismiss completed generation={generation}");
            }
        };
        fadeOut.Completed += completed;
        fadeOut.Begin();
    }

    private void PrepareForNewPresentation()
    {
        _dismissGeneration++;
        StopCountdown();
        RootCard.BeginAnimation(UIElement.OpacityProperty, null);
        RootCard.Opacity = 0;
    }

    private void ClearPresentationState()
    {
        RootCard.BeginAnimation(UIElement.OpacityProperty, null);
        RootCard.Opacity = 0;
        _currentText = string.Empty;
        _activeMarkdownStreamId = null;
    }

    private void PinBtn_Click(object sender, RoutedEventArgs e)
    {
        _isPinned = !_isPinned;
        UpdatePinVisual();

        if (_isPinned)
        {
            StopCountdown();
        }
        else
        {
            StartCountdown(DefaultCountdownSeconds);
        }
    }

    private void CopyBtn_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            ClipboardService.SetText(_currentText);
            ShowCopySuccess();
            e.Handled = true;
        }
        catch
        {
            // Clipboard may be locked by another process
        }
    }

    private void ResetCopyVisual()
    {
        CopyIcon.Text = AppIcons.Copy;
        CopyIcon.Foreground = FindResource("TextDimBrush") as Brush
            ?? SystemColors.GrayTextBrush;
        CopyBtn.ToolTip = L10n.BtnCopy;
    }

    private void ShowCopySuccess()
    {
        CopyIcon.Text = AppIcons.Success;
        CopyIcon.Foreground = FindResource("DsSuccessBrush") as Brush
            ?? new SolidColorBrush(Color.FromRgb(0x16, 0xA3, 0x4A));
        CopyBtn.ToolTip = L10n.BtnCopied;
    }

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        DismissOverlay();
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (IsFromButton(e.OriginalSource))
            return;

        e.Handled = true;
        WindowInteropTools.BeginDragMove(this);
    }

    private static bool IsFromButton(object? source)
    {
        var current = source as DependencyObject;
        while (current is not null)
        {
            if (current is ButtonBase)
                return true;

            current = current is Visual or Visual3D
                ? VisualTreeHelper.GetParent(current)
                : LogicalTreeHelper.GetParent(current) as DependencyObject;
        }

        return false;
    }

    private void ResizeRight_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        BeginResize(WindowResizeDirection.Right, e);
    }

    private void ResizeBottom_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        BeginResize(WindowResizeDirection.Bottom, e);
    }

    private void ResizeCorner_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        BeginResize(WindowResizeDirection.BottomRight, e);
    }

    private void BeginResize(WindowResizeDirection direction, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        e.Handled = true;
        _wasManuallyResized = true;
        WindowInteropTools.BeginResize(this, direction);
    }
}
