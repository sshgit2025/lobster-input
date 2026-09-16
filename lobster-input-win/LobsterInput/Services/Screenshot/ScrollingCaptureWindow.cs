using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using LobsterInput.Helpers;

namespace LobsterInput.Services.Screenshot;

/// <summary>
/// 长图模式滚动采集控制窗：选区窗口关闭后弹出此小窗（不抢焦点），用全局低级鼠标钩子监听滚轮。
/// 滚动会话期间以 ~15fps 连续定时采帧（旧版"滚动停顿 60ms 才采一帧"在快滚时必然丢失中间内容，
/// 已废弃），并把两次采帧之间累计的滚轮 delta 作为位置先验传给 ScreenshotStitcher（纯色/渐变等
/// 无纹理区域全靠它外推）。实时预览；点「完成」落剪贴板、「取消」/Esc 丢弃。
///
/// 注：本窗不覆盖被截内容（选区窗口已关闭），底层应用可自由滚动；本窗 ShowActivated=false 不抢焦点。
/// </summary>
internal sealed class ScrollingCaptureWindow : Window
{
    private const int WH_MOUSE_LL = 14;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int HC_ACTION = 0;

    private readonly Int32Rect _rect;     // 屏幕像素坐标的固定选区
    private readonly ScreenshotStitcher _stitcher = new();
    private readonly Image _preview = new();
    private readonly TextBlock _hint = new();
    private readonly TaskCompletionSource<ScreenshotCaptureResult> _tcs = new();

    private readonly DispatcherTimer _captureTimer;   // 连续采帧（~15fps）
    private LowLevelMouseProc? _hookProc;     // 必须强引用，防 GC
    private IntPtr _hookHandle = IntPtr.Zero;
    private bool _finished;
    private double _hintAccum;                         // 自上次采帧以来累计的滚轮 delta
    private DateTime _lastWheelAt = DateTime.MinValue; // 最近一次滚轮活动（空闲降频用）
    private bool _capturedBase;                        // 已抓基底帧

    public ScrollingCaptureWindow(Int32Rect rect)
    {
        _rect = rect;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        ShowActivated = false;          // 不抢焦点 → 底层应用保持可滚动
        ShowInTaskbar = false;
        Width = 220;
        Height = 240;
        Background = Brushes.Transparent;
        AllowsTransparency = true;
        BuildContent();
        PositionNearSelection();

        _captureTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(66) };
        _captureTimer.Tick += (_, _) => OnCaptureTick();

        Loaded += OnLoaded;
        Closed += OnClosed;
    }

    /// <summary>非模态显示并等待结果（完成/取消）。</summary>
    public Task<ScreenshotCaptureResult> RunAsync()
    {
        Show();
        return _tcs.Task;
    }

    private void BuildContent()
    {
        _hint.Text = L10n.ScreenshotScrollHint;
        _hint.Foreground = Brushes.White;
        _hint.FontSize = 12;
        _hint.TextAlignment = TextAlignment.Center;
        _hint.TextTrimming = TextTrimming.CharacterEllipsis;
        _hint.Margin = new Thickness(10, 8, 10, 4);

        _preview.Stretch = Stretch.Uniform;
        _preview.StretchDirection = StretchDirection.DownOnly;
        _preview.Margin = new Thickness(10, 0, 10, 4);

        var done = new Button { Content = L10n.ScreenshotScrollDone, Width = 90, Height = 28, Margin = new Thickness(4) };
        done.Click += (_, _) => Finish();
        var cancel = new Button { Content = L10n.ScreenshotScrollCancel, Width = 90, Height = 28, Margin = new Thickness(4) };
        cancel.Click += (_, _) => CancelSession();

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
        buttons.Children.Add(cancel);
        buttons.Children.Add(done);

        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(_hint, 0);
        Grid.SetRow(_preview, 1);
        Grid.SetRow(buttons, 2);
        grid.Children.Add(_hint);
        grid.Children.Add(_preview);
        grid.Children.Add(buttons);

        Content = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(235, 30, 30, 30)),
            CornerRadius = new CornerRadius(10),
            Child = grid
        };
    }

    private void PositionNearSelection()
    {
        // 选区在屏幕像素坐标；本窗用 DIP 定位，按主屏 DPI 近似换算（控制窗位置不要求像素级精确）。
        var source = PresentationSource.FromVisual(Application.Current?.MainWindow ?? this);
        double dpi = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        if (dpi <= 0) dpi = 1.0;
        double selLeftDip = _rect.X / dpi;
        double selBottomDip = (_rect.Y + _rect.Height) / dpi;
        double selRightDip = (_rect.X + _rect.Width) / dpi;
        Left = Math.Max(8, selRightDip - Width);
        Top = selBottomDip + 12;
        // 屏幕下方放不下则放选区上方
        var workArea = SystemParameters.WorkArea;
        if (Top + Height > workArea.Bottom - 8)
            Top = Math.Max(8, _rect.Y / dpi - Height - 12);
        if (Left + Width > workArea.Right - 8) Left = workArea.Right - Width - 8;
        if (Left < workArea.Left + 8) Left = workArea.Left + 8;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        InstallHook();
        // 等屏幕稳定后抓基底帧，随后开启连续采帧
        Dispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() =>
        {
            CaptureAndStitch();
            _capturedBase = true;
            _captureTimer.Start();
        }));
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        RemoveHook();
        _captureTimer.Stop();
        if (!_tcs.Task.IsCompleted)
            _tcs.TrySetResult(ScreenshotCaptureResult.Cancelled);
    }

    // MARK: - 采集与拼接

    private void OnWheel(int delta)
    {
        if (_finished) return;
        _hintAccum += delta;
        _lastWheelAt = DateTime.UtcNow;
    }

    private void OnCaptureTick()
    {
        if (_finished || !_capturedBase) return;
        // 空闲降频：滚轮停止 700ms 后不再采帧（引擎的静止帧短路也会兜底），滚动一来立即恢复
        if ((DateTime.UtcNow - _lastWheelAt).TotalMilliseconds > 700) return;
        CaptureAndStitch();
    }

    private void CaptureAndStitch()
    {
        if (_finished) return;
        try
        {
            double hint = _hintAccum;   // 快照并清零本帧滚轮量（UI 线程独占访问）
            _hintAccum = 0;
            var bmp = ScreenCaptureService.CaptureRect(_rect.X, _rect.Y, _rect.Width, _rect.Height);
            if (bmp == null) return;
            int w = bmp.PixelWidth, h = bmp.PixelHeight;
            int stride = w * 4;
            var buf = new byte[stride * h];
            BitmapSource src = bmp.Format == PixelFormats.Bgra32 || bmp.Format == PixelFormats.Pbgra32
                ? bmp
                : new FormatConvertedBitmap(bmp, PixelFormats.Pbgra32, null, 0);
            src.CopyPixels(buf, stride, 0);

            var result = _stitcher.Add(buf, w, h, hint);
            if (result == ScreenshotStitcher.AddResult.First || result == ScreenshotStitcher.AddResult.Appended)
            {
                UpdatePreview();
                _hint.Text = $"{L10n.ScreenshotScrollHint}  ·  {_stitcher.PixelHeight}px";
            }
            else if (result == ScreenshotStitcher.AddResult.NoMatch)
            {
                _hint.Text = L10n.ScreenshotScrollTooFast;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("Screenshot.ScrollingCapture", ex);
        }
    }

    private void UpdatePreview()
    {
        var thumb = _stitcher.MakeThumbnail(200, 700);
        if (thumb == null) return;
        var (bytes, tw, th) = thumb.Value;
        var img = BitmapSource.Create(tw, th, 96, 96, PixelFormats.Bgra32, null, bytes, tw * 4);
        img.Freeze();
        _preview.Source = img;
    }

    // MARK: - 完成 / 取消

    private void Finish()
    {
        if (_finished) return;
        _finished = true;
        _captureTimer.Stop();
        RemoveHook();
        try
        {
            if (!_stitcher.HasContent)
            {
                _tcs.TrySetResult(ScreenshotCaptureResult.Failed);
                Close();
                return;
            }
            var bytes = _stitcher.GetImageBytes();
            int w = _stitcher.PixelWidth, h = _stitcher.PixelHeight;
            var image = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgr32, null, bytes, w * 4);
            image.Freeze();
            ClipboardService.SetImage(image);
            DebugTrace.Log("Screenshot", $"scrolling capture finish: {w}x{h} frames={_stitcher.FrameCount}");
            _tcs.TrySetResult(ScreenshotCaptureResult.Copied);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("Screenshot.ScrollingCapture.Finish", ex);
            _tcs.TrySetResult(ScreenshotCaptureResult.Failed);
        }
        Close();
    }

    private void CancelSession()
    {
        if (_finished) return;
        _finished = true;
        _captureTimer.Stop();
        RemoveHook();
        _tcs.TrySetResult(ScreenshotCaptureResult.Cancelled);
        Close();
    }

    protected override void OnKeyDown(System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Escape) { CancelSession(); e.Handled = true; return; }
        if (e.Key == System.Windows.Input.Key.Enter) { Finish(); e.Handled = true; return; }
        base.OnKeyDown(e);
    }

    // MARK: - 全局低级鼠标钩子（监听滚轮）

    private void InstallHook()
    {
        _hookProc = HookCallback;
        using var curProcess = Process.GetCurrentProcess();
        using var curModule = curProcess.MainModule;
        _hookHandle = SetWindowsHookEx(WH_MOUSE_LL, _hookProc,
            GetModuleHandle(curModule?.ModuleName), 0);
        if (_hookHandle == IntPtr.Zero)
            DebugTrace.Log("Screenshot", "scrolling capture: install mouse hook failed");
    }

    private void RemoveHook()
    {
        if (_hookHandle != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hookHandle);
            _hookHandle = IntPtr.Zero;
        }
        _hookProc = null;
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= HC_ACTION && (int)wParam == WM_MOUSEWHEEL)
        {
            // MSLLHOOKSTRUCT.mouseData 高 16 位 = 带符号滚轮 delta（±120/格）。
            // 钩子回调在安装它的 UI 线程触发，可直接处理。
            int mouseData = Marshal.ReadInt32(lParam, 8);
            int delta = (short)((mouseData >> 16) & 0xFFFF);
            OnWheel(delta);
        }
        return CallNextHookEx(_hookHandle, nCode, wParam, lParam);
    }

    private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
}
