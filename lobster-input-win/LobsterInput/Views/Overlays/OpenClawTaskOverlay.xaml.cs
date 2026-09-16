using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Media3D;
using System.Windows.Threading;
using LobsterInput.Helpers;
using LobsterInput.Services;
using Markdig;

namespace LobsterInput.Views.Overlays;

public partial class OpenClawTaskOverlay : Window
{
    private static readonly MarkdownPipeline MarkdownPipeline =
        new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();

    private readonly DispatcherTimer _elapsedTimer;
    private DateTime _startedAt;
    private bool _isRunning;
    private bool _copied;
    private string _currentText = "";

    public OpenClawTaskOverlay()
    {
        InitializeComponent();
        CopyIcon.Text = AppIcons.Copy;
        CloseIcon.Text = AppIcons.Close;
        CloseBtn.ToolTip = L10n.AgreementClose;
        CopyBtn.ToolTip = L10n.BtnCopy;

        _elapsedTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _elapsedTimer.Tick += (_, _) => UpdateElapsed();
    }

    public void ShowConnecting()
    {
        _isRunning = true;
        _startedAt = DateTime.Now;
        _copied = false;
        ResetCopyVisual();
        StatusText.Text = "连接中";
        StopBtn.IsEnabled = true;
        UpdateStatusBrush("AccentBrush");
        UpdateMarkdown("OpenClaw 已启动，正在连接任务...");
        PositionOnScreen();
        Show();
        _elapsedTimer.Start();

        if (TryFindResource("FadeIn") is Storyboard fadeIn)
            fadeIn.Begin();
        else
            RootCard.Opacity = 1;
    }

    public void ShowRunning(string? runId, int? messageSeq)
    {
        _isRunning = true;
        StatusText.Text = "运行中";
        StopBtn.IsEnabled = true;
        UpdateStatusBrush("AccentBrush");
        if (string.IsNullOrWhiteSpace(_currentText)
            || _currentText == "OpenClaw 已启动，正在连接任务...")
            UpdateMarkdown("任务已开始，正在等待 OpenClaw 返回执行过程...");
        Show();
    }

    public void UpdateTranscript(string text)
    {
        _isRunning = true;
        StatusText.Text = "运行中";
        StopBtn.IsEnabled = true;
        UpdateStatusBrush("AccentBrush");
        UpdateMarkdown(text);
        Show();
    }

    public void Finish(string text)
    {
        _isRunning = false;
        StatusText.Text = "已完成";
        StopBtn.IsEnabled = false;
        UpdateStatusBrush("DsSuccessBrush");
        UpdateMarkdown(text);
        _elapsedTimer.Stop();
        Show();
    }

    public void MarkAborted(string text)
    {
        _isRunning = false;
        StatusText.Text = "已中断";
        StopBtn.IsEnabled = false;
        UpdateStatusBrush("DsWarningBrush");
        UpdateMarkdown(text);
        _elapsedTimer.Stop();
        Show();
    }

    public void ShowError(string text)
    {
        _isRunning = false;
        StatusText.Text = "失败";
        StopBtn.IsEnabled = false;
        UpdateStatusBrush("DsDangerBrush");
        UpdateMarkdown(text);
        _elapsedTimer.Stop();
        Show();
    }

    private void UpdateMarkdown(string markdownText)
    {
        _currentText = markdownText;
        if (!_copied) ResetCopyVisual();
        var doc = Markdig.Wpf.Markdown.ToFlowDocument(markdownText, MarkdownPipeline);
        doc.PagePadding = new Thickness(0);
        MarkdownTheme.Apply(doc, this);
        MarkdownContent.Document = doc;
    }

    private void PositionOnScreen()
    {
        WindowInteropTools.PositionCenteredNearBottom(this, 44);
    }

    private void UpdateElapsed()
    {
        ElapsedText.Text = $"{Math.Max(0, (int)(DateTime.Now - _startedAt).TotalSeconds)}s";
    }

    private void UpdateStatusBrush(string resourceName)
    {
        if (TryFindResource(resourceName) is Brush brush)
        {
            StatusText.Foreground = brush;
            HeaderIcon.Foreground = brush;
        }
    }

    private void StopBtn_Click(object sender, RoutedEventArgs e)
    {
        OpenClawManager.Instance.AbortCurrentOpenClawTask();
    }

    private void CopyBtn_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            ClipboardService.SetText(_currentText);
            _copied = true;
            CopyIcon.Text = AppIcons.Success;
            if (TryFindResource("DsSuccessBrush") is Brush brush)
                CopyIcon.Foreground = brush;
            CopyBtn.ToolTip = L10n.BtnCopied;
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
        CopyIcon.Foreground = TryFindResource("TextDimBrush") as Brush ?? SystemColors.GrayTextBrush;
        CopyBtn.ToolTip = L10n.BtnCopy;
    }

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        CloseFromUser();
    }

    public void CloseFromUser()
    {
        if (_isRunning)
            OpenClawManager.Instance.AbortCurrentOpenClawTask();
        Hide();
    }

    private void TitleBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (IsFromButton(e.OriginalSource)) return;

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
        WindowInteropTools.BeginResize(this, direction);
    }
}
