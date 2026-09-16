using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;

namespace LobsterInput.Services;

internal static class ClipboardTextNative
{
    private const uint CfUnicodeText = 13;
    private const uint GmemMoveable = 0x0002;
    private const uint GmemZeroInit = 0x0040;
    private const int DefaultTimeoutMs = 900;
    private static readonly object OwnerLock = new();
    private static HwndSource? _ownerSource;

    public static bool TrySetText(string text, int timeoutMs = DefaultTimeoutMs)
    {
        if (string.IsNullOrEmpty(text))
            return false;

        IntPtr handle = IntPtr.Zero;
        var opened = false;
        try
        {
            opened = TryOpen(timeoutMs);
            if (!opened)
                return false;

            if (!EmptyClipboard())
                return false;

            var bytes = Encoding.Unicode.GetBytes(text + '\0');
            handle = GlobalAlloc(GmemMoveable | GmemZeroInit, (UIntPtr)bytes.Length);
            if (handle == IntPtr.Zero)
                return false;

            var locked = GlobalLock(handle);
            if (locked == IntPtr.Zero)
                return false;

            try
            {
                Marshal.Copy(bytes, 0, locked, bytes.Length);
            }
            finally
            {
                GlobalUnlock(handle);
            }

            if (SetClipboardData(CfUnicodeText, handle) == IntPtr.Zero)
                return false;

            handle = IntPtr.Zero;
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[ClipboardNative] Set text failed: {ex.Message}");
            return false;
        }
        finally
        {
            if (opened)
                CloseClipboard();
            if (handle != IntPtr.Zero)
                GlobalFree(handle);
        }
    }

    public static bool TryGetText(out string? text, int timeoutMs = DefaultTimeoutMs)
    {
        text = null;
        var opened = false;
        try
        {
            opened = TryOpen(timeoutMs);
            if (!opened)
                return false;

            if (!IsClipboardFormatAvailable(CfUnicodeText))
                return true;

            var handle = GetClipboardData(CfUnicodeText);
            if (handle == IntPtr.Zero)
                return false;

            var locked = GlobalLock(handle);
            if (locked == IntPtr.Zero)
                return false;

            try
            {
                text = Marshal.PtrToStringUni(locked);
                return true;
            }
            finally
            {
                GlobalUnlock(handle);
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[ClipboardNative] Get text failed: {ex.Message}");
            return false;
        }
        finally
        {
            if (opened)
                CloseClipboard();
        }
    }

    public static bool TryClear(int timeoutMs = DefaultTimeoutMs)
    {
        var opened = false;
        try
        {
            opened = TryOpen(timeoutMs);
            return opened && EmptyClipboard();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[ClipboardNative] Clear failed: {ex.Message}");
            return false;
        }
        finally
        {
            if (opened)
                CloseClipboard();
        }
    }

    public static uint GetSequenceNumber() => GetClipboardSequenceNumber();

    private static bool TryOpen(int timeoutMs)
    {
        var stopwatch = Stopwatch.StartNew();
        var delay = 12;
        var owner = ResolveOwnerHandle();

        while (stopwatch.ElapsedMilliseconds < timeoutMs)
        {
            if (OpenClipboard(owner))
                return true;

            Thread.Sleep(delay);
            delay = Math.Min(delay + 8, 40);
        }

        return OpenClipboard(owner);
    }

    private static IntPtr ResolveOwnerHandle()
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null)
            return IntPtr.Zero;

        try
        {
            return dispatcher.CheckAccess()
                ? EnsureOwnerHandle()
                : dispatcher.Invoke(EnsureOwnerHandle);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[ClipboardNative] Owner handle unavailable: {ex.Message}");
            return IntPtr.Zero;
        }
    }

    private static IntPtr EnsureOwnerHandle()
    {
        lock (OwnerLock)
        {
            if (_ownerSource != null && _ownerSource.Handle != IntPtr.Zero)
                return _ownerSource.Handle;

            var parameters = new HwndSourceParameters("LobsterInputClipboardOwner")
            {
                Width = 0,
                Height = 0,
                WindowStyle = unchecked((int)0x80000000)
            };
            _ownerSource = new HwndSource(parameters);
            return _ownerSource.Handle;
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr GetClipboardData(uint uFormat);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsClipboardFormatAvailable(uint format);

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalFree(IntPtr hMem);
}
