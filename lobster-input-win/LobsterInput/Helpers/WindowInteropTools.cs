using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace LobsterInput.Helpers;

public enum WindowResizeDirection
{
    Right = 2,
    Bottom = 6,
    BottomRight = 8
}

public static class WindowInteropTools
{
    private const int WS_EX_NOACTIVATE = 0x08000000;
    private const int WS_EX_TRANSPARENT = 0x00000020;
    private const int GWL_EXSTYLE = -20;
    private const int WM_NCLBUTTONDOWN = 0x00A1;
    private const int WM_SYSCOMMAND = 0x0112;
    private const int HTCAPTION = 2;
    private const int SC_SIZE = 0xF000;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWA_BORDER_COLOR = 34;
    private const int DWMWCP_ROUND = 2;
    private const uint DWMWA_COLOR_NONE = 0xFFFFFFFE;
    private const int MONITOR_DEFAULTTONEAREST = 2;

    private enum MonitorDpiType
    {
        Effective = 0
    }

    public static void AttachWindowFramePreferences(Window window)
    {
        void Apply() => ApplyDwmFramePreferences(window);
        void OnSourceInitialized(object? sender, EventArgs e) => Apply();
        void OnStateChanged(object? sender, EventArgs e) => Apply();
        void OnClosed(object? sender, EventArgs e)
        {
            window.SourceInitialized -= OnSourceInitialized;
            window.StateChanged -= OnStateChanged;
            window.Closed -= OnClosed;
        }

        window.SourceInitialized += OnSourceInitialized;
        window.StateChanged += OnStateChanged;
        window.Closed += OnClosed;

        if (new WindowInteropHelper(window).Handle != IntPtr.Zero)
            Apply();
    }

    public static void ApplyNoActivate(Window window, bool clickThrough = false)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;

        var exStyle = GetWindowLong(hwnd, GWL_EXSTYLE) | WS_EX_NOACTIVATE;
        if (clickThrough)
            exStyle |= WS_EX_TRANSPARENT;

        SetWindowLong(hwnd, GWL_EXSTYLE, exStyle);
    }

    public static bool BeginDragMove(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return false;

        ReleaseCapture();
        SendMessage(hwnd, WM_NCLBUTTONDOWN, new IntPtr(HTCAPTION), IntPtr.Zero);
        return true;
    }

    public static bool BeginResize(Window window, WindowResizeDirection direction)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return false;

        SendMessage(hwnd, WM_SYSCOMMAND, new IntPtr(SC_SIZE + (int)direction), IntPtr.Zero);
        return true;
    }

    public static Rect CursorWorkAreaDip()
    {
        var cursor = Forms.Cursor.Position;
        var screen = Forms.Screen.FromPoint(cursor);
        var scale = DpiScaleForPoint(cursor.X, cursor.Y);
        var work = screen.WorkingArea;

        return new Rect(
            work.Left / scale.X,
            work.Top / scale.Y,
            work.Width / scale.X,
            work.Height / scale.Y);
    }

    public static void PositionCenteredNearBottom(Window window, double bottomOffset)
    {
        var work = CursorWorkAreaDip();
        window.Left = work.Left + (work.Width - window.Width) / 2;
        window.Top = work.Top + work.Height - window.Height - bottomOffset;
        ClampToWorkArea(window, work, 16);
    }

    public static void PositionCenteredNearTop(Window window, double topOffset)
    {
        var work = CursorWorkAreaDip();
        window.Left = work.Left + (work.Width - window.Width) / 2;
        window.Top = work.Top + topOffset;
        ClampToWorkArea(window, work, 16);
    }

    public static void ClampToCursorWorkArea(Window window, double margin = 16)
    {
        ClampToWorkArea(window, CursorWorkAreaDip(), margin);
    }

    private static void ClampToWorkArea(Window window, Rect work, double margin)
    {
        var maxLeft = work.Right - window.Width - margin;
        var maxTop = work.Bottom - window.Height - margin;
        window.Left = Math.Clamp(window.Left, work.Left + margin, Math.Max(work.Left + margin, maxLeft));
        window.Top = Math.Clamp(window.Top, work.Top + margin, Math.Max(work.Top + margin, maxTop));
    }

    private static void ApplyDwmFramePreferences(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero)
            return;

        ApplyDwmFramePreferences(hwnd);
    }

    private static void ApplyDwmFramePreferences(IntPtr hwnd)
    {
        var borderColor = DWMWA_COLOR_NONE;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_BORDER_COLOR, ref borderColor, sizeof(uint));

        var cornerPreference = DWMWCP_ROUND;
        _ = DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref cornerPreference, sizeof(int));
    }

    private static Point DpiScaleForPoint(int x, int y)
    {
        try
        {
            var monitor = MonitorFromPoint(new POINT { X = x, Y = y }, MONITOR_DEFAULTTONEAREST);
            if (monitor != IntPtr.Zero &&
                GetDpiForMonitor(monitor, MonitorDpiType.Effective, out var dpiX, out var dpiY) == 0 &&
                dpiX > 0 &&
                dpiY > 0)
            {
                return new Point(dpiX / 96.0, dpiY / 96.0);
            }
        }
        catch
        {
            // Fall through to 96 DPI.
        }

        return new Point(1, 1);
    }

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool ReleaseCapture();

    [DllImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int dwAttribute, ref uint pvAttribute, int cbAttribute);

    [DllImport("dwmapi.dll", EntryPoint = "DwmSetWindowAttribute")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int dwAttribute, ref int pvAttribute, int cbAttribute);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(POINT pt, int dwFlags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(
        IntPtr hmonitor,
        MonitorDpiType dpiType,
        out uint dpiX,
        out uint dpiY);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }
}
