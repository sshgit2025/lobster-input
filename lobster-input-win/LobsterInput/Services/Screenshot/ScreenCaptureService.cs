using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;
using LobsterInput.Helpers;

namespace LobsterInput.Services.Screenshot;

public readonly record struct ScreenCaptureBounds(
    Rect PixelBounds);

public static class ScreenCaptureService
{
    private const int SM_XVIRTUALSCREEN = 76;
    private const int SM_YVIRTUALSCREEN = 77;
    private const int SM_CXVIRTUALSCREEN = 78;
    private const int SM_CYVIRTUALSCREEN = 79;
    private const int SRCCOPY = 0x00CC0020;
    private const int CAPTUREBLT = 0x40000000;

    public static Rect VirtualScreenBounds() => new(
        GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN),
        GetSystemMetrics(SM_CXVIRTUALSCREEN),
        GetSystemMetrics(SM_CYVIRTUALSCREEN));

    public static ScreenCaptureBounds VirtualScreenCaptureBounds()
    {
        var pixelBounds = VirtualScreenBounds();
        DebugTrace.Log(
            "Screenshot",
            $"virtualScreen px={pixelBounds.X:0},{pixelBounds.Y:0},{pixelBounds.Width:0}x{pixelBounds.Height:0}");
        return new ScreenCaptureBounds(pixelBounds);
    }

    public static BitmapSource? CaptureVirtualScreen()
    {
        var bounds = VirtualScreenBounds();
        var width = (int)bounds.Width;
        var height = (int)bounds.Height;
        if (width <= 0 || height <= 0) return null;

        var screenDc = GetDC(IntPtr.Zero);
        var memDc = CreateCompatibleDC(screenDc);
        var hBitmap = CreateCompatibleBitmap(screenDc, width, height);
        var oldObj = SelectObject(memDc, hBitmap);

        try
        {
            if (!BitBlt(memDc, 0, 0, width, height, screenDc,
                    (int)bounds.X, (int)bounds.Y, SRCCOPY | CAPTUREBLT))
                return null;

            var source = Imaging.CreateBitmapSourceFromHBitmap(
                hBitmap,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        finally
        {
            SelectObject(memDc, oldObj);
            DeleteObject(hBitmap);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    /// <summary>抓取屏幕上指定像素矩形（虚拟屏坐标）。用于长图模式滚动期间反复采集固定选区。</summary>
    public static BitmapSource? CaptureRect(int x, int y, int width, int height)
    {
        if (width <= 0 || height <= 0) return null;

        var screenDc = GetDC(IntPtr.Zero);
        var memDc = CreateCompatibleDC(screenDc);
        var hBitmap = CreateCompatibleBitmap(screenDc, width, height);
        var oldObj = SelectObject(memDc, hBitmap);

        try
        {
            if (!BitBlt(memDc, 0, 0, width, height, screenDc, x, y, SRCCOPY | CAPTUREBLT))
                return null;

            var source = Imaging.CreateBitmapSourceFromHBitmap(
                hBitmap,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            source.Freeze();
            return source;
        }
        finally
        {
            SelectObject(memDc, oldObj);
            DeleteObject(hBitmap);
            DeleteDC(memDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hDc);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr hDc, int width, int height);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hDc, IntPtr hObj);

    [DllImport("gdi32.dll")]
    private static extern bool BitBlt(IntPtr hDc, int x, int y, int width, int height,
        IntPtr hDcSrc, int srcX, int srcY, int rop);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObj);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr hDc);

}
