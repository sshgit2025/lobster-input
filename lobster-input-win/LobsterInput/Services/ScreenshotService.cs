using System.Diagnostics;
using IOPath = System.IO.Path;
using LobsterInput.Helpers;
using LobsterInput.Services.Screenshot;

namespace LobsterInput.Services;

public enum ScreenshotCaptureResult
{
    Copied,
    Cancelled,
    Failed
}

public sealed class ScreenshotService
{
    private static readonly string SettingsPath = IOPath.Combine(
        AppPaths.LocalAppDataDir,
        "screenshot_settings.txt");

    private static readonly string LongImageSettingsPath = IOPath.Combine(
        AppPaths.LocalAppDataDir,
        "long_image_settings.txt");

    public static ScreenshotService Instance { get; } = new();

    private bool _isCapturing;

    private ScreenshotService()
    {
    }

    public static bool ConfirmationEnabled
    {
        get
        {
            try
            {
                return File.Exists(SettingsPath) &&
                       File.ReadAllText(SettingsPath).Trim() == "1";
            }
            catch
            {
                return false;
            }
        }
        set
        {
            try
            {
                Directory.CreateDirectory(IOPath.GetDirectoryName(SettingsPath)!);
                File.WriteAllText(SettingsPath, value ? "1" : "0");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Screenshot] Save setting failed: {ex.Message}");
            }
        }
    }

    /// 长图模式（无需确认模式下滚动拼接长图）。与二次确认互斥，开启其一应关闭另一个（由设置 UI 保证）。
    public static bool LongImageModeEnabled
    {
        get
        {
            try
            {
                return File.Exists(LongImageSettingsPath) &&
                       File.ReadAllText(LongImageSettingsPath).Trim() == "1";
            }
            catch
            {
                return false;
            }
        }
        set
        {
            try
            {
                Directory.CreateDirectory(IOPath.GetDirectoryName(LongImageSettingsPath)!);
                File.WriteAllText(LongImageSettingsPath, value ? "1" : "0");
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[Screenshot] Save long-image setting failed: {ex.Message}");
            }
        }
    }

    public ScreenshotCaptureResult CaptureToClipboard()
    {
        if (_isCapturing) return ScreenshotCaptureResult.Cancelled;
        _isCapturing = true;

        try
        {
            var confirmationEnabled = ConfirmationEnabled;
            DebugTrace.Log("Screenshot", $"capture begin confirmation={confirmationEnabled}, async=false");

            var bounds = ScreenCaptureService.VirtualScreenCaptureBounds();
            var snapshot = ScreenCaptureService.CaptureVirtualScreen();
            if (snapshot == null)
            {
                DebugTrace.Log("Screenshot", "capture failed because snapshot is null");
                return ScreenshotCaptureResult.Failed;
            }

            DebugTrace.Log("Screenshot", $"snapshot ready {snapshot.PixelWidth}x{snapshot.PixelHeight}");
            var window = new ScreenshotSelectionWindow(snapshot, bounds, confirmationEnabled);
            var result = window.ShowDialog() == true
                ? ScreenshotCaptureResult.Copied
                : window.Result;
            DebugTrace.Log("Screenshot", $"capture end result={result}");
            return result;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Screenshot] Capture failed: {ex.Message}");
            DebugTrace.LogError("Screenshot.Capture", ex);
            return ScreenshotCaptureResult.Failed;
        }
        finally
        {
            _isCapturing = false;
        }
    }

    public async Task<ScreenshotCaptureResult> CaptureToClipboardAsync()
    {
        if (_isCapturing) return ScreenshotCaptureResult.Cancelled;
        _isCapturing = true;

        try
        {
            var confirmationEnabled = ConfirmationEnabled;
            DebugTrace.Log("Screenshot", $"capture begin confirmation={confirmationEnabled}, async=true");

            var bounds = ScreenCaptureService.VirtualScreenCaptureBounds();
            var snapshot = await Task.Run(ScreenCaptureService.CaptureVirtualScreen);
            if (snapshot == null)
            {
                DebugTrace.Log("Screenshot", "capture failed because snapshot is null");
                return ScreenshotCaptureResult.Failed;
            }

            DebugTrace.Log("Screenshot", $"snapshot ready {snapshot.PixelWidth}x{snapshot.PixelHeight}");
            var window = new ScreenshotSelectionWindow(snapshot, bounds, confirmationEnabled);
            var longImage = !confirmationEnabled && LongImageModeEnabled;
            window.LongImageMode = longImage;
            var dialogResult = window.ShowDialog();

            if (longImage && window.LongImagePixelRect is { } pixelRect)
            {
                // 选区窗口已关闭、无覆盖层；弹出滚动采集小窗，监听滚轮反复抓选区并拼接。
                var session = new ScrollingCaptureWindow(pixelRect);
                var sessionResult = await session.RunAsync();
                DebugTrace.Log("Screenshot", $"long image session result={sessionResult}");
                return sessionResult;
            }

            var result = dialogResult == true
                ? ScreenshotCaptureResult.Copied
                : window.Result;
            DebugTrace.Log("Screenshot", $"capture end result={result}");
            return result;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Screenshot] Capture failed: {ex.Message}");
            DebugTrace.LogError("Screenshot.CaptureAsync", ex);
            return ScreenshotCaptureResult.Failed;
        }
        finally
        {
            _isCapturing = false;
        }
    }

}
