using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LobsterInput.Helpers;

namespace LobsterInput.Services;

public class ClipboardBackup
{
    public string? Text { get; set; }
    public string? Html { get; set; }
    public string? Rtf { get; set; }
    public string[]? Files { get; set; }
    public bool HasImage { get; set; }
    public System.Windows.Media.Imaging.BitmapSource? Image { get; set; }
}

public class ClipboardContextItem
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "text";
    [JsonPropertyName("mime_type")] public string? MimeType { get; set; }
    [JsonPropertyName("text")] public string? Text { get; set; }
    [JsonPropertyName("data_url")] public string? DataUrl { get; set; }
}

public static class ClipboardService
{
    private static bool _clipboardAccessEnabled = true;
    private static readonly List<string> _history = new();
    private static readonly object _historyLock = new();
    private static readonly object _clipboardLock = new();
    private const int MaxHistorySize = 50;
    private const int CompressionDataUrlThresholdBytes = 300_000;
    private const int MaxImageDataUrlBytes = 5_000_000;

    private static string SettingsPath => Path.Combine(
        AppPaths.LocalAppDataDir, "clipboard_settings.json");

    public static bool ClipboardAccessEnabled
    {
        get => _clipboardAccessEnabled;
        set
        {
            _clipboardAccessEnabled = value;
            PersistSetting();
        }
    }

    static ClipboardService()
    {
        LoadSetting();
    }

    public static List<string> ReadHistory(int maxItems = 5)
    {
        lock (_historyLock)
        {
            return _history.Take(maxItems).ToList();
        }
    }

    public static List<ClipboardContextItem> ReadContextItems(int maxItems = 5)
    {
        if (!_clipboardAccessEnabled) return new();
        lock (_clipboardLock)
        {
            var items = new List<ClipboardContextItem>();
            AddCurrentClipboardItem(items);
            AddHistoryTextItems(items, maxItems);
            return items.Take(maxItems).ToList();
        }
    }

    public static void SetText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        if (!TrySetTextSilently(text))
            DebugTrace.Log("Clipboard", "SetText failed");

        if (!ClipboardSentinel.IsInternal(text))
            AddToHistory(text);
    }

    internal static void SetTextSilently(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        TrySetTextSilently(text);
    }

    internal static bool TrySetTextSilently(string text)
    {
        if (string.IsNullOrEmpty(text)) return false;

        lock (_clipboardLock)
        {
            var success = ClipboardTextNative.TrySetText(text, timeoutMs: 900);
            if (!success)
                DebugTrace.Log("Clipboard", "native text write timed out");
            return success;
        }
    }

    internal static bool TryClearSilently()
    {
        lock (_clipboardLock)
        {
            return ClipboardTextNative.TryClear(timeoutMs: 700);
        }
    }

    internal static uint GetSequenceNumber() => ClipboardTextNative.GetSequenceNumber();

    internal static T RunExclusive<T>(Func<T> action)
    {
        lock (_clipboardLock)
        {
            return action();
        }
    }

    public static void SetImage(BitmapSource image)
    {
        lock (_clipboardLock)
        {
            Clipboard.SetImage(image);
        }
    }

    public static string? GetText()
    {
        lock (_clipboardLock)
        {
            return ClipboardTextNative.TryGetText(out var text, timeoutMs: 700)
                ? text
                : null;
        }
    }

    public static ClipboardBackup? BackupClipboard()
    {
        try
        {
            lock (_clipboardLock)
            {
                return RetryClipboardOp(() =>
                {
                    var backup = new ClipboardBackup();
                    var data = Clipboard.GetDataObject();
                    if (data == null) return backup;

                    if (data.GetDataPresent(DataFormats.UnicodeText))
                        backup.Text = data.GetData(DataFormats.UnicodeText) as string;
                    else if (data.GetDataPresent(DataFormats.Text))
                        backup.Text = data.GetData(DataFormats.Text) as string;

                    if (data.GetDataPresent(DataFormats.Html))
                        backup.Html = data.GetData(DataFormats.Html) as string;

                    if (data.GetDataPresent(DataFormats.Rtf))
                        backup.Rtf = data.GetData(DataFormats.Rtf) as string;

                    if (data.GetDataPresent(DataFormats.FileDrop))
                        backup.Files = data.GetData(DataFormats.FileDrop) as string[];

                    if (data.GetDataPresent(DataFormats.Bitmap))
                    {
                        backup.HasImage = true;
                        backup.Image = data.GetData(DataFormats.Bitmap) as System.Windows.Media.Imaging.BitmapSource;
                    }

                    return backup;
                });
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Clipboard] Backup failed: {ex.Message}");
            return null;
        }
    }

    public static void RestoreClipboard(ClipboardBackup backup)
    {
        _ = TryRestoreClipboard(backup);
    }

    internal static bool TryRestoreClipboard(ClipboardBackup backup)
    {
        if (backup == null) return true;

        try
        {
            lock (_clipboardLock)
            {
                RetryClipboardOp(() =>
                {
                    var dataObj = new DataObject();
                    bool hasData = false;

                    if (backup.Text != null)
                    {
                        dataObj.SetData(DataFormats.UnicodeText, backup.Text);
                        hasData = true;
                    }

                    if (backup.Html != null)
                    {
                        dataObj.SetData(DataFormats.Html, backup.Html);
                        hasData = true;
                    }

                    if (backup.Rtf != null)
                    {
                        dataObj.SetData(DataFormats.Rtf, backup.Rtf);
                        hasData = true;
                    }

                    if (backup.Files != null)
                    {
                        dataObj.SetData(DataFormats.FileDrop, backup.Files);
                        hasData = true;
                    }

                    if (backup.HasImage && backup.Image != null)
                    {
                        dataObj.SetData(DataFormats.Bitmap, backup.Image);
                        hasData = true;
                    }

                    if (hasData)
                        Clipboard.SetDataObject(dataObj, true);
                    else
                        Clipboard.Clear();
                });
            }

            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Clipboard] Restore failed: {ex.Message}");
            return false;
        }
    }

    public static void RestoreClipboardEventually(
        ClipboardBackup? backup,
        int delayMs = 600,
        int attempts = 8,
        string? expectedText = null,
        uint? expectedSequenceNumber = null)
    {
        if (backup == null) return;

        Task.Run(async () =>
        {
            for (var i = 0; i < attempts; i++)
            {
                try
                {
                    await Task.Delay(delayMs + (i * 120));
                    if (expectedText != null &&
                        expectedSequenceNumber.HasValue &&
                        !IsExpectedClipboardText(expectedText, expectedSequenceNumber.Value))
                    {
                        DebugTrace.Log("Clipboard", "delayed restore skipped because clipboard changed");
                        return;
                    }

                    var restored = await StaTaskRunner.Run(() => TryRestoreClipboardNonBlocking(backup));
                    if (restored)
                        return;
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[Clipboard] Delayed restore failed: {ex.Message}");
                }
            }
        });
    }

    private static bool IsExpectedClipboardText(string expectedText, uint expectedSequenceNumber)
    {
        var currentSequence = GetSequenceNumber();
        if (currentSequence == expectedSequenceNumber)
            return true;

        var currentText = GetText();
        return string.Equals(currentText, expectedText, StringComparison.Ordinal);
    }

    private static bool TryRestoreClipboardNonBlocking(ClipboardBackup backup)
    {
        if (backup == null) return true;
        if (!Monitor.TryEnter(_clipboardLock, 50))
            return false;

        try
        {
            RetryClipboardOp(() =>
            {
                var dataObj = new DataObject();
                bool hasData = false;

                if (backup.Text != null)
                {
                    dataObj.SetData(DataFormats.UnicodeText, backup.Text);
                    hasData = true;
                }

                if (backup.Html != null)
                {
                    dataObj.SetData(DataFormats.Html, backup.Html);
                    hasData = true;
                }

                if (backup.Rtf != null)
                {
                    dataObj.SetData(DataFormats.Rtf, backup.Rtf);
                    hasData = true;
                }

                if (backup.Files != null)
                {
                    dataObj.SetData(DataFormats.FileDrop, backup.Files);
                    hasData = true;
                }

                if (backup.HasImage && backup.Image != null)
                {
                    dataObj.SetData(DataFormats.Bitmap, backup.Image);
                    hasData = true;
                }

                if (hasData)
                    Clipboard.SetDataObject(dataObj, true);
                else
                    Clipboard.Clear();
            });
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Clipboard] Delayed restore failed: {ex.Message}");
            return false;
        }
        finally
        {
            Monitor.Exit(_clipboardLock);
        }
    }

    private static void AddToHistory(string text)
    {
        if (!_clipboardAccessEnabled ||
            string.IsNullOrWhiteSpace(text) ||
            ClipboardSentinel.IsInternal(text))
        {
            return;
        }

        lock (_historyLock)
        {
            _history.Remove(text);
            _history.Insert(0, text);
            while (_history.Count > MaxHistorySize)
                _history.RemoveAt(_history.Count - 1);
        }
    }

    private static void AddCurrentClipboardItem(List<ClipboardContextItem> items)
    {
        var text = GetText();
        if (!string.IsNullOrWhiteSpace(text) && !ClipboardSentinel.IsInternal(text))
            items.Add(new ClipboardContextItem { Kind = "text", Text = text });
        else if (TryReadImageDataUrl() is { } image)
            items.Add(new ClipboardContextItem {
                Kind = "image", MimeType = image.MimeType, DataUrl = image.DataUrl
            });
    }

    private static void AddHistoryTextItems(List<ClipboardContextItem> items, int maxItems)
    {
        foreach (var text in ReadHistory(maxItems))
        {
            if (ClipboardSentinel.IsInternal(text)) continue;
            if (items.Any(i => i.Text == text)) continue;
            items.Add(new ClipboardContextItem { Kind = "text", Text = text });
        }
    }

    private sealed record ClipboardImagePayload(string MimeType, string DataUrl);

    private static ClipboardImagePayload? TryReadImageDataUrl()
    {
        try
        {
            return RetryClipboardOp(() =>
                Clipboard.ContainsImage() ? EncodeImageDataUrl(Clipboard.GetImage()) : null);
        }
        catch { return null; }
    }

    private static ClipboardImagePayload? EncodeImageDataUrl(BitmapSource? image)
    {
        if (image == null) return null;

        var png = EncodeBitmap(image, new PngBitmapEncoder());
        var pngDataUrl = MakeDataUrl("image/png", png);
        if (pngDataUrl.Length <= CompressionDataUrlThresholdBytes)
            return new ClipboardImagePayload("image/png", pngDataUrl);

        ClipboardImagePayload? smallestAcceptable = null;
        foreach (var quality in new[] { 86, 74, 62, 50, 38, 28, 20 })
        {
            var jpeg = EncodeJpeg(image, quality);
            var dataUrl = MakeDataUrl("image/jpeg", jpeg);
            if (dataUrl.Length >= MaxImageDataUrlBytes)
                continue;
            if (smallestAcceptable == null || dataUrl.Length < smallestAcceptable.DataUrl.Length)
                smallestAcceptable = new ClipboardImagePayload("image/jpeg", dataUrl);
            if (dataUrl.Length <= CompressionDataUrlThresholdBytes)
                return new ClipboardImagePayload("image/jpeg", dataUrl);
        }

        if (smallestAcceptable == null)
            DebugTrace.Log("Clipboard", $"image skipped because compressed payload exceeds limit pngDataUrl={pngDataUrl.Length}");
        return smallestAcceptable;
    }

    private static byte[] EncodeBitmap(BitmapSource image, BitmapEncoder encoder)
    {
        using var stream = new MemoryStream();
        encoder.Frames.Add(BitmapFrame.Create(image));
        encoder.Save(stream);
        return stream.ToArray();
    }

    private static byte[] EncodeJpeg(BitmapSource image, int quality)
    {
        var encoder = new JpegBitmapEncoder { QualityLevel = quality };
        var jpegSource = image.Format == PixelFormats.Bgr24
            ? image
            : new FormatConvertedBitmap(image, PixelFormats.Bgr24, null, 0);
        return EncodeBitmap(jpegSource, encoder);
    }

    private static string MakeDataUrl(string mimeType, byte[] bytes)
    {
        return $"data:{mimeType};base64,{Convert.ToBase64String(bytes)}";
    }

    private static void RetryClipboardOp(Action action, int maxRetries = 8)
    {
        for (int i = 0; i < maxRetries; i++)
        {
            try
            {
                action();
                return;
            }
            catch (System.Runtime.InteropServices.COMException) when (i < maxRetries - 1)
            {
                Thread.Sleep(Math.Min(300, 40 * (i + 1)));
            }
        }
    }

    private static T? RetryClipboardOp<T>(Func<T> func, int maxRetries = 8)
    {
        for (int i = 0; i < maxRetries; i++)
        {
            try
            {
                return func();
            }
            catch (System.Runtime.InteropServices.COMException) when (i < maxRetries - 1)
            {
                Thread.Sleep(Math.Min(300, 40 * (i + 1)));
            }
        }
        return default;
    }

    private static void PersistSetting()
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            var json = JsonSerializer.Serialize(new { clipboardAccessEnabled = _clipboardAccessEnabled });
            File.WriteAllText(SettingsPath, json);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Clipboard] PersistSetting failed: {ex.Message}");
        }
    }

    private static void LoadSetting()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return;
            var json = File.ReadAllText(SettingsPath);
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("clipboardAccessEnabled", out var val))
                _clipboardAccessEnabled = val.GetBoolean();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[Clipboard] LoadSetting failed: {ex.Message}");
        }
    }
}
