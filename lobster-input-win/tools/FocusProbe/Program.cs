using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using LobsterInput.Services;
using LobsterInput.Services.TextTargets;

namespace FocusProbe;

internal static class Program
{
    [STAThread]
    public static void Main()
    {
        Console.OutputEncoding = Encoding.UTF8;
        if (Application.Current == null)
            new Application();

        Console.WriteLine("=== FocusProbe Fill Lab ===");
        Console.WriteLine("请在 3 秒内把焦点放在 Cursor/VSCode 终端输入行…");
        Thread.Sleep(3000);

        var fg = Native.GetForegroundWindow();
        var proc = Native.ProcessName(fg);
        if (!proc.Equals("Cursor", StringComparison.OrdinalIgnoreCase) &&
            !proc.Equals("Code", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"警告: 当前前台不是 Cursor/VSCode，而是 '{proc}'。结果可能无效。");
        }
        AutomationElement? focused;
        try { focused = AutomationElement.FocusedElement; }
        catch (Exception ex) { Console.WriteLine($"FocusedElement error: {ex.Message}"); return; }

        if (focused == null)
        {
            Console.WriteLine("没有焦点元素，退出。");
            return;
        }

        var hwnd = fg;
        var snapshot = SelectedTextService.TakeSnapshot(hwnd, includeCommandCopyProbe: false);
        var screen = FindXtermScreen(focused);
        var renderHwnd = Native.GetGuiThreadFocus(hwnd);
        TextTargetWin32.TryResolveInputFocusWindow(hwnd, out var inputHwnd);
        var renderWidgets = Native.ListDescendantsByClass(hwnd, "Chrome_RenderWidgetHostHWND");

        Console.WriteLine($"fg=0x{hwnd.ToInt64():X} proc={Native.ProcessName(hwnd)} renderFocus=0x{renderHwnd.ToInt64():X} class={Native.ClassName(renderHwnd)}");
        Console.WriteLine($"inputFocus=0x{inputHwnd.ToInt64():X} class={Native.ClassName(inputHwnd)} renderWidgets={renderWidgets.Count}");
        Console.WriteLine($"focusedClass={Safe(() => focused.Current.ClassName ?? "")}");
        var focusedRect = SafeRect(focused);
        Console.WriteLine($"focusedRect={focusedRect}");
        var terminalFocus = FindTerminalFocusContainer(focused);
        if (terminalFocus != null)
            Console.WriteLine($"terminalFocusRect={SafeRect(terminalFocus)} class={Safe(() => terminalFocus?.Current.ClassName ?? "<none>")}");

        FillVerifier.Instance.Attach(hwnd, focused);
        Console.WriteLine($"fillVerifierAttached={FillVerifier.Instance.IsAttached}");
        Console.WriteLine($"screenClass={Safe(() => screen?.Current.ClassName ?? "<none>")}");

        var baselineScreen = ReadScreenTail(screen, 800);
        var baselineValue = ReadValue(focused);
        Console.WriteLine($"baselineValue='{Trim(baselineValue ?? "", 80)}'");
        Console.WriteLine($"baselineScreenTail='{Trim(baselineScreen ?? "", 160)}'");

        var token = DateTime.Now.ToString("HHmmss");
        RunFillCase("A.ValuePattern.SetValue", focused, () => ValueSet(focused, $"probeA-{token}"), focused, screen, $"probeA-{token}");
        RunFillCase("B.UnicodeSendInput", focused, () => UnicodeType(focused, $"probeB-{token}"), focused, screen, $"probeB-{token}");
        RunFillCase("B2.AttachedUnicode", focused, () => AttachedUnicodePaste(hwnd, focused, $"probeB2-{token}"), focused, screen, $"probeB2-{token}", readName: true);
        RunFillCase("B3.AttachedVkKeys", focused, () => AttachedVkPaste(hwnd, focused, $"probeB3-{token}"), focused, screen, $"probeB3-{token}", readName: true);
        RunFillCase("E3.ClickTerminal+Paste", terminalFocus ?? focused, () => ClickTerminalPaste(hwnd, terminalFocus ?? focused, focused, $"probeE3-{token}"), focused, screen, $"probeE3-{token}", readName: true);
        RunFillCase("C.Clipboard+CtrlV", focused, () => ClipboardPaste(focused, renderHwnd, $"probeC-{token}"), focused, screen, $"probeC-{token}");
        RunFillCase("D.SelectedTextService.PasteText", focused, () => SelectedTextService.PasteText($"probeD-{token}", hwnd, snapshot, snapshot), focused, screen, $"probeD-{token}", readName: true);
        RunFillCase("E.AttachedClipboard+CtrlV", focused, () => AttachedClipboardPaste(hwnd, focused, $"probeE-{token}"), focused, screen, $"probeE-{token}", readName: true);
        RunFillCase("F.AttachThread+Unicode", focused, () => Native.AttachedUnicodeType(focused, renderHwnd, hwnd, $"probeF-{token}"), focused, screen, $"probeF-{token}", readName: true);
        RunFillCase("G.WM_PASTE", focused, () => Native.WmPaste(focused, renderHwnd, $"probeG-{token}"), focused, screen, $"probeG-{token}", readName: true);
        RunFillCase("I.WM_CHAR", focused, () => Native.WmCharType(renderHwnd != IntPtr.Zero ? renderHwnd : hwnd, focused, $"probeI-{token}"), focused, screen, $"probeI-{token}", readName: true);

        Console.WriteLine("\n=== Done ===");
        FillVerifier.Instance.Detach();
    }

    private static void RunFillCase(
        string name,
        AutomationElement focused,
        Func<bool> fill,
        AutomationElement valueEl,
        AutomationElement? screen,
        string needle,
        bool readName = false)
    {
        Console.WriteLine($"\n--- {name} ---");
        try
        {
            TryFocus(focused);
            var beforeValue = ReadValue(valueEl) ?? "";
            FillVerifier.Instance.Arm();
            var ok = fill();
            var eventConfirmed = FillVerifier.Instance.WaitForChange(TimeSpan.FromMilliseconds(600));
            Thread.Sleep(120);
            var value = ReadValue(valueEl) ?? "";
            var screenTail = ReadScreenTail(screen, 800) ?? "";
            var nameText = readName ? Safe(() => valueEl.Current.Name ?? "") : "";
            var inValue = value.Contains(needle, StringComparison.Ordinal);
            var inScreen = screenTail.Contains(needle, StringComparison.Ordinal);
            var inName = nameText.Contains(needle, StringComparison.Ordinal);
            Console.WriteLine($"fillReturned={ok}");
            Console.WriteLine($"beforeValue='{Trim(beforeValue, 60)}' afterValue='{Trim(value, 100)}'");
            Console.WriteLine($"valueHasNeedle={inValue}");
            Console.WriteLine($"screenHasNeedle={inScreen} screenTail='{Trim(screenTail, 180)}'");
            if (readName)
                Console.WriteLine($"nameHasNeedle={inName} nameTail='{Trim(nameText, 180)}'");
            var consumed = !string.IsNullOrEmpty(beforeValue) &&
                string.IsNullOrEmpty(value) &&
                !string.Equals(beforeValue, value, StringComparison.Ordinal);
            Console.WriteLine($"eventConfirmed={eventConfirmed} eventSource='{Trim(FillVerifier.Instance.LastChangeSource, 120)}'");
            Console.WriteLine($"helperCleared={string.IsNullOrEmpty(value)} consumed={consumed} REAL_SUCCESS={inScreen || inName || consumed || eventConfirmed}");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"ERROR: {ex.Message} lastError={Marshal.GetLastWin32Error()}");
        }
    }

    private static AutomationElement? FindXtermScreen(AutomationElement focused)
    {
        for (var el = focused; el != null; el = SafeParent(el))
        {
            var cls = Safe(() => el.Current.ClassName ?? "");
            if (cls.Contains("xterm-screen", StringComparison.OrdinalIgnoreCase))
                return el;
        }
        return null;
    }

    private static AutomationElement? SafeParent(AutomationElement el)
    {
        try { return TreeWalker.ControlViewWalker.GetParent(el); }
        catch { return null; }
    }

    private static string? ReadScreenTail(AutomationElement? screen, int maxChars)
    {
        if (screen == null) return null;
        try
        {
            if (screen.TryGetCurrentPattern(TextPattern.Pattern, out var tpObj))
            {
                var full = ((TextPattern)tpObj).DocumentRange.GetText(-1) ?? "";
                if (full.Length <= maxChars) return full;
                return full[^maxChars..];
            }
        }
        catch { }
        return null;
    }

    private static bool TryFocus(AutomationElement el)
    {
        try { el.SetFocus(); Thread.Sleep(50); return el.Current.HasKeyboardFocus; }
        catch { return false; }
    }

    private static bool ValueSet(AutomationElement el, string text)
    {
        if (!el.TryGetCurrentPattern(ValuePattern.Pattern, out var obj)) return false;
        ((ValuePattern)obj).SetValue(text);
        return true;
    }

    private static bool UnicodeType(AutomationElement el, string text)
    {
        TryFocus(el);
        var ok = Native.SendUnicodeText(text);
        if (!ok)
            Console.WriteLine($"  Unicode err={Marshal.GetLastWin32Error()}");
        return ok;
    }

    private static bool AttachedUnicodePaste(IntPtr rootHwnd, AutomationElement el, string text)
    {
        return TextTargetWin32.TryRunAttachedInput(
            rootHwnd,
            () => { try { el.SetFocus(); Thread.Sleep(40); } catch { } },
            () => TextTargetWin32.SendUnicodeText(text),
            out var sent) && sent;
    }

    private static bool AttachedVkPaste(IntPtr rootHwnd, AutomationElement el, string text)
    {
        return TextTargetWin32.TryRunAttachedInput(
            rootHwnd,
            () =>
            {
                TextTargetWin32.TryClickAutomationElement(el);
                try { el.SetFocus(); Thread.Sleep(40); } catch { }
            },
            () => TextTargetWin32.SendTextViaVkKeys(text),
            out var sent) && sent;
    }

    private static AutomationElement? FindTerminalFocusContainer(AutomationElement focused)
    {
        for (var el = focused; el != null; el = SafeParent(el))
        {
            var cls = Safe(() => el.Current.ClassName ?? "");
            if (cls.Contains("terminal xterm focus", StringComparison.OrdinalIgnoreCase) ||
                cls.Contains("terminal-wrapper", StringComparison.OrdinalIgnoreCase))
                return el;
        }
        return null;
    }

    private static string SafeRect(AutomationElement el)
    {
        try
        {
            var r = el.Current.BoundingRectangle;
            return $"{r.X:0},{r.Y:0},{r.Width:0}x{r.Height:0}";
        }
        catch { return "<err>"; }
    }

    private static bool ClickTerminalPaste(IntPtr rootHwnd, AutomationElement clickTarget, AutomationElement focusEl, string text)
    {
        if (!ClipboardService.TrySetTextSilently(text))
            return false;
        Thread.Sleep(50);
        return TextTargetWin32.TryRunAttachedInput(
            rootHwnd,
            () =>
            {
                TextTargetWin32.TryClickAutomationElement(clickTarget);
                try { focusEl.SetFocus(); Thread.Sleep(60); } catch { }
            },
            () => TextTargetWin32.SendPasteShortcut(),
            out var sent) && sent;
    }

    private static bool ClipboardPaste(AutomationElement el, IntPtr renderHwnd, string text)
    {
        TryFocus(el);
        if (!ClipboardTextNative.TrySetText(text))
            return false;
        Thread.Sleep(50);
        if (renderHwnd != IntPtr.Zero)
            Native.SetForegroundWindow(renderHwnd);
        Thread.Sleep(30);
        return Native.SendCtrlV();
    }

    private static bool AttachedClipboardPaste(IntPtr rootHwnd, AutomationElement el, string text)
    {
        if (!ClipboardService.TrySetTextSilently(text))
            return false;

        Thread.Sleep(50);
        return TextTargetWin32.TryRunAttachedInput(
            rootHwnd,
            () => { try { el.SetFocus(); Thread.Sleep(40); } catch { } },
            () => TextTargetWin32.SendPasteShortcut(),
            out var sent) && sent;
    }

    private static string? ReadValue(AutomationElement el)
    {
        try
        {
            if (!el.TryGetCurrentPattern(ValuePattern.Pattern, out var obj)) return null;
            return ((ValuePattern)obj).Current.Value;
        }
        catch { return null; }
    }

    private static string Safe(Func<string> fn)
    {
        try { return fn(); }
        catch (Exception ex) { return $"<err:{ex.Message}>"; }
    }

    private static string Trim(string s, int max) => s.Length <= max ? s : s[..max] + "...";
}

internal static class Native
{
    public const int VkControl = 0x11;
    public const int VkV = 0x56;
    public const int InputKeyboard = 1;
    public const int KeyeventfKeyup = 0x0002;

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool GetGUIThreadInfo(uint idThread, ref Guithreadinfo lpgui);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    public struct Guithreadinfo
    {
        public int cbSize, flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    public struct INPUT
    {
        [FieldOffset(0)] public int type;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    private static readonly int InputStructSize = IntPtr.Size == 8 ? 40 : 28;

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk, wScan;
        public uint dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    public static List<IntPtr> ListDescendantsByClass(IntPtr root, string classSubstring)
    {
        var list = new List<IntPtr>();
        if (root == IntPtr.Zero) return list;
        Collect(root);
        return list;

        void Collect(IntPtr parent)
        {
            EnumChildWindows(
                parent,
                (child, _) =>
                {
                    var cls = ClassName(child);
                    if (cls.Contains(classSubstring, StringComparison.OrdinalIgnoreCase))
                        list.Add(child);
                    Collect(child);
                    return true;
                },
                IntPtr.Zero);
        }
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc lpEnumFunc, IntPtr lParam);

    private delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);

    public static string ClassName(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return "";
        var sb = new StringBuilder(256);
        return GetClassName(hwnd, sb, sb.Capacity) > 0 ? sb.ToString() : "";
    }

    public static string ProcessName(IntPtr hwnd)
    {
        if (GetWindowThreadProcessId(hwnd, out var pid) == 0 || pid == 0) return "";
        try { return Process.GetProcessById((int)pid).ProcessName; }
        catch { return ""; }
    }

    public static IntPtr GetGuiThreadFocus(IntPtr hwnd)
    {
        var threadId = GetWindowThreadProcessId(hwnd, out _);
        var info = new Guithreadinfo { cbSize = Marshal.SizeOf<Guithreadinfo>() };
        return GetGUIThreadInfo(threadId, ref info) ? info.hwndFocus : IntPtr.Zero;
    }

    private const int WmPasteMessage = 0x0302;
    public const int KeyeventfUnicode = 0x0004;

    public static bool AttachedUnicodeType(AutomationElement el, IntPtr renderHwnd, IntPtr rootHwnd, string text)
    {
        try { el.SetFocus(); } catch { }
        using var attach = AttachForeground(rootHwnd, renderHwnd);
        SetForegroundWindow(renderHwnd);
        Thread.Sleep(40);
        return SendUnicodeText(text);
    }

    private const int WmChar = 0x0102;

    public static bool WmCharType(IntPtr targetHwnd, AutomationElement el, string text)
    {
        try { el.SetFocus(); } catch { }
        SetForegroundWindow(targetHwnd);
        Thread.Sleep(40);
        foreach (var ch in text)
        {
            if (ch == '\r' || ch == '\n') continue;
            SendMessage(targetHwnd, WmChar, (IntPtr)ch, IntPtr.Zero);
            Thread.Sleep(4);
        }
        return true;
    }

    public static bool AttachedClipboardPaste(AutomationElement el, IntPtr renderHwnd, IntPtr rootHwnd, string text)
    {
        try { el.SetFocus(); } catch { }
        if (!ClipboardTextNative.TrySetText(text)) return false;
        Thread.Sleep(40);
        using var attach = AttachForeground(rootHwnd, renderHwnd);
        SetForegroundWindow(renderHwnd);
        Thread.Sleep(40);
        return SendCtrlV();
    }

    public static bool WmPaste(AutomationElement el, IntPtr renderHwnd, string text)
    {
        try { el.SetFocus(); } catch { }
        if (!ClipboardTextNative.TrySetText(text)) return false;
        Thread.Sleep(40);
        SetForegroundWindow(renderHwnd);
        Thread.Sleep(40);
        return SendMessage(renderHwnd, WmPasteMessage, IntPtr.Zero, IntPtr.Zero) != IntPtr.Zero;
    }

    private static AttachScope AttachForeground(IntPtr rootHwnd, IntPtr renderHwnd)
    {
        var current = GetCurrentThreadId();
        var target = GetWindowThreadProcessId(renderHwnd != IntPtr.Zero ? renderHwnd : rootHwnd, out _);
        var attached = target != 0 && current != target && AttachThreadInput(current, target, true);
        return new AttachScope(current, target, attached);
    }

    private readonly struct AttachScope(uint current, uint target, bool attached) : IDisposable
    {
        public void Dispose()
        {
            if (attached)
                AttachThreadInput(current, target, false);
        }
    }

    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    public static bool SendUnicodeText(string text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        try
        {
            foreach (var ch in text)
            {
                var unit = (ushort)ch;
                var down = MakeUnicodeInput(unit, false);
                var up = MakeUnicodeInput(unit, true);
                var inputs = new[] { down, up };
                if (SendInput((uint)inputs.Length, inputs, InputStructSize) != inputs.Length)
            {
                Console.WriteLine($"  Unicode SendInput failed err={Marshal.GetLastWin32Error()} char={ch}");
                return false;
            }
                Thread.Sleep(8);
            }
            return true;
        }
        catch { return false; }
    }

    private static INPUT MakeUnicodeInput(ushort unit, bool keyUp) => new()
    {
        type = InputKeyboard,
        ki = new KEYBDINPUT
        {
            wVk = 0,
            wScan = unit,
            dwFlags = (uint)(KeyeventfUnicode | (keyUp ? KeyeventfKeyup : 0))
        }
    };

    public static bool SendCtrlV()
    {
        INPUT Key(ushort vk, bool up) => new()
        {
            type = InputKeyboard,
            ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? (uint)KeyeventfKeyup : 0 }
        };
        var inputs = new[] { Key(VkControl, false), Key(VkV, false), Key(VkV, true), Key(VkControl, true) };
        return SendInput((uint)inputs.Length, inputs, InputStructSize) == inputs.Length;
    }
}

internal static class ClipboardTextNative
{
    private const uint CfUnicodeText = 13;
    private const uint GmemMoveable = 0x0002;
    private const uint GmemZeroInit = 0x0040;

    [DllImport("user32.dll", SetLastError = true)] private static extern bool OpenClipboard(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool CloseClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern bool EmptyClipboard();
    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetClipboardData(uint format, IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalLock(IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalUnlock(IntPtr hMem);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr GlobalFree(IntPtr hMem);

    public static bool TrySetText(string text)
    {
        IntPtr handle = IntPtr.Zero;
        if (!OpenClipboard(IntPtr.Zero)) return false;
        try
        {
            EmptyClipboard();
            var bytes = Encoding.Unicode.GetBytes(text + '\0');
            handle = GlobalAlloc(GmemMoveable | GmemZeroInit, (UIntPtr)bytes.Length);
            if (handle == IntPtr.Zero) return false;
            var locked = GlobalLock(handle);
            if (locked == IntPtr.Zero) return false;
            try { Marshal.Copy(bytes, 0, locked, bytes.Length); }
            finally { GlobalUnlock(handle); }
            if (SetClipboardData(CfUnicodeText, handle) == IntPtr.Zero) return false;
            handle = IntPtr.Zero;
            return true;
        }
        finally
        {
            CloseClipboard();
            if (handle != IntPtr.Zero) GlobalFree(handle);
        }
    }
}
