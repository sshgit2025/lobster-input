using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using LobsterInput.Helpers;

namespace LobsterInput.Services.TextTargets;

internal static class TextTargetWin32
{
    public const int SW_RESTORE = 9;
    public const int VK_CONTROL = 0x11;
    public const int VK_C = 0x43;
    public const int VK_V = 0x56;
    public const int VK_SHIFT = 0x10;

    private const ushort VK_LSHIFT_EX = 0xA0;
    private const ushort VK_RSHIFT_EX = 0xA1;
    private const ushort VK_LMENU_EX = 0xA4;
    private const ushort VK_RMENU_EX = 0xA5;
    private const ushort VK_LWIN_EX = 0x5B;
    private const ushort VK_RWIN_EX = 0x5C;

    private const int MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const int MOUSEEVENTF_LEFTUP = 0x0004;

    private const int GA_ROOT = 2;

    private static readonly HashSet<string> TerminalProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "WindowsTerminal",
        "pwsh",
        "powershell",
        "cmd",
        "bash",
        "wsl",
        "ubuntu",
        "debian",
        "fedora",
        "openSUSE",
        "kali",
        "alacritty",
        "ConEmu",
        "ConEmu64",
        "ConEmuC",
        "ConEmuC64",
        "Hyper",
        "wezterm",
        "WindowsTerminalServer",
    };

    private static readonly HashSet<string> TerminalWindowClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "ConsoleWindowClass",
        "CASCADIA_HOSTING_WINDOW_CLASS",
    };

    private const int INPUT_KEYBOARD = 1;
    private const int KEYEVENTF_KEYUP = 0x0002;
    private const int KEYEVENTF_UNICODE = 0x0004;
    private const int WM_GETTEXT = 0x000D;
    private const int WM_GETTEXTLENGTH = 0x000E;
    private const int EM_GETSEL = 0x00B0;
    private const int EM_REPLACESEL = 0x00C2;
    private const int GWL_STYLE = -16;
    private const int ES_READONLY = 0x0800;
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private const uint KEYBD_EVENT_KEYUP = 0x0002;

    public static IntPtr FocusedWindow => GetForegroundWindow();

    public static bool TryGetWindowProcessId(IntPtr hwnd, out uint processId)
    {
        processId = 0;
        if (hwnd == IntPtr.Zero)
            return false;

        var threadId = GetWindowThreadProcessId(hwnd, out processId);
        return threadId != 0;
    }

    public static uint GetWindowThreadId(IntPtr hwnd) =>
        hwnd == IntPtr.Zero ? 0 : GetWindowThreadProcessId(hwnd, out _);

    public static bool TryGetCursorPosition(out Point point)
    {
        point = default;
        if (!GetCursorPos(out var nativePoint))
            return false;

        point = new Point(nativePoint.X, nativePoint.Y);
        return true;
    }

    public static bool TryGetFocusedChildWindow(IntPtr targetWindow, out IntPtr focusedChild)
    {
        focusedChild = IntPtr.Zero;
        var threadId = GetWindowThreadId(targetWindow);
        if (threadId == 0) return false;

        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        if (!GetGUIThreadInfo(threadId, ref info))
            return false;

        focusedChild = info.hwndFocus != IntPtr.Zero ? info.hwndFocus : info.hwndCaret;
        return focusedChild != IntPtr.Zero;
    }

    public static bool TryGetCaretWindow(IntPtr targetWindow, out IntPtr caretWindow)
    {
        caretWindow = IntPtr.Zero;
        var threadId = GetWindowThreadId(targetWindow);
        if (threadId == 0) return false;

        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        if (!GetGUIThreadInfo(threadId, ref info))
            return false;

        caretWindow = info.hwndCaret;
        return caretWindow != IntPtr.Zero;
    }

    public static bool TryGetEditSelection(IntPtr hwnd, out int start, out int end)
    {
        start = 0;
        end = 0;
        if (hwnd == IntPtr.Zero)
            return false;

        SendMessage(hwnd, EM_GETSEL, out start, out end);
        return start >= 0 && end >= 0;
    }

    public static bool IsNativeEditControl(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd))
            return false;

        var className = GetClassNameSafe(hwnd);
        if (string.IsNullOrWhiteSpace(className))
            return false;

        return className.Equals("Edit", StringComparison.OrdinalIgnoreCase) ||
            className.Contains("RichEdit", StringComparison.OrdinalIgnoreCase) ||
            className.Contains(".EDIT.", StringComparison.OrdinalIgnoreCase);
    }

    public static bool IsNativeEditReadOnly(IntPtr hwnd) => IsEditReadOnly(hwnd);

    public static string GetWindowTextSafe(IntPtr hwnd)
    {
        try
        {
            SendMessageTimeout(
                hwnd,
                WM_GETTEXTLENGTH,
                IntPtr.Zero,
                IntPtr.Zero,
                SMTO_ABORTIFHUNG,
                300,
                out var lengthResult);
            var length = lengthResult.ToInt32();
            if (length <= 0)
                return "";

            var buffer = new StringBuilder(length + 1);
            SendMessage(hwnd, WM_GETTEXT, new IntPtr(buffer.Capacity), buffer);
            return buffer.ToString();
        }
        catch
        {
            return "";
        }
    }

    public static bool TryReplaceEditSelection(IntPtr editHwnd, string text, string verificationNeedle)
    {
        if (editHwnd == IntPtr.Zero || string.IsNullOrEmpty(text))
            return false;

        try
        {
            if (!IsWindow(editHwnd))
            {
                DebugTrace.Log("SelectedText", $"EM_REPLACESEL skipped invalid hwnd=0x{editHwnd.ToInt64():X}");
                return false;
            }

            if (IsEditReadOnly(editHwnd))
            {
                DebugTrace.Log("SelectedText", $"EM_REPLACESEL skipped readonly hwnd=0x{editHwnd.ToInt64():X}");
                return false;
            }

            var sent = SendMessageTimeout(
                editHwnd,
                EM_REPLACESEL,
                new IntPtr(1),
                text,
                SMTO_ABORTIFHUNG,
                1000,
                out _);

            if (sent == IntPtr.Zero)
            {
                DebugTrace.Log("SelectedText", $"EM_REPLACESEL failed hwnd=0x{editHwnd.ToInt64():X}, error={Marshal.GetLastWin32Error()}");
                return false;
            }

            if (string.IsNullOrWhiteSpace(verificationNeedle))
                return true;

            var current = GetWindowTextSafe(editHwnd);
            if (current.Contains(verificationNeedle, StringComparison.Ordinal))
                return true;

            DebugTrace.Log("SelectedText", $"EM_REPLACESEL sent but verification was unavailable hwnd=0x{editHwnd.ToInt64():X}");
            return true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EM_REPLACESEL", ex);
            return false;
        }
    }

    public static bool FocusWindowForInput(IntPtr hwnd, Action? focusElement)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd)) return false;

        try { ShowWindow(hwnd, SW_RESTORE); } catch { }

        var currentForeground = GetForegroundWindow();
        var currentThread = GetCurrentThreadId();
        var targetThread = GetWindowThreadId(hwnd);
        var foregroundThread = currentForeground != IntPtr.Zero
            ? GetWindowThreadId(currentForeground)
            : 0;

        var attachedTarget = false;
        var attachedForeground = false;
        try
        {
            if (targetThread != 0 && targetThread != currentThread)
                attachedTarget = AttachThreadInput(currentThread, targetThread, true);
            if (foregroundThread != 0 && foregroundThread != currentThread && foregroundThread != targetThread)
                attachedForeground = AttachThreadInput(currentThread, foregroundThread, true);

            SetForegroundWindow(hwnd);
            focusElement?.Invoke();
        }
        finally
        {
            if (attachedForeground)
                AttachThreadInput(currentThread, foregroundThread, false);
            if (attachedTarget)
                AttachThreadInput(currentThread, targetThread, false);
        }

        return true;
    }

    public static bool AttachToWindowThread<T>(IntPtr hwnd, Func<T> action, out T? result)
    {
        result = default;
        var currentThreadId = GetCurrentThreadId();
        var targetThreadId = GetWindowThreadId(hwnd);

        var attached = false;
        try
        {
            if (targetThreadId != 0 && currentThreadId != targetThreadId)
                attached = AttachThreadInput(currentThreadId, targetThreadId, true);

            result = action();
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            if (attached)
                AttachThreadInput(currentThreadId, targetThreadId, false);
        }
    }

    public static bool IsKnownWindow(IntPtr hwnd) => hwnd != IntPtr.Zero && IsWindow(hwnd);

    /// <summary>
    /// Console hosts (Windows Terminal, classic PowerShell/cmd, WSL shells) do not expose
    /// standard Win32 Edit or reliable UIA value patterns. They still accept Ctrl+V paste.
    /// </summary>
    public static bool IsTerminalInputWindow(IntPtr hwnd)
    {
        if (!IsKnownWindow(hwnd))
            return false;

        var root = GetAncestor(hwnd, GA_ROOT);
        if (root == IntPtr.Zero)
            root = hwnd;

        var className = GetClassNameSafe(root);
        if (!string.IsNullOrWhiteSpace(className))
        {
            foreach (var terminalClass in TerminalWindowClasses)
            {
                if (className.Equals(terminalClass, StringComparison.OrdinalIgnoreCase) ||
                    className.Contains(terminalClass, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }

        if (!TryGetWindowProcessName(root, out var processName) || string.IsNullOrWhiteSpace(processName))
            return false;

        return TerminalProcessNames.Contains(processName);
    }

    public static bool IsForegroundWindow(IntPtr hwnd) => GetForegroundWindow() == hwnd;

    private static int InputStructSize => IntPtr.Size == 8 ? 40 : 28;

    public static bool TryGetRenderFocusWindow(IntPtr targetWindow, out IntPtr renderWindow)
    {
        renderWindow = IntPtr.Zero;
        var root = GetAncestor(targetWindow, GA_ROOT);
        if (root == IntPtr.Zero)
            root = targetWindow;

        var threadId = GetWindowThreadId(root);
        if (threadId == 0)
            return false;

        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf<GUITHREADINFO>() };
        if (GetGUIThreadInfo(threadId, ref info) && info.hwndFocus != IntPtr.Zero)
        {
            if (IsChromeRenderWidgetHost(info.hwndFocus))
            {
                renderWindow = info.hwndFocus;
                return true;
            }
        }

        if (TryFindDescendantByClassSubstring(root, "Chrome_RenderWidgetHostHWND", out var descendant))
        {
            renderWindow = descendant;
            return true;
        }

        if (info.hwndFocus != IntPtr.Zero)
        {
            renderWindow = info.hwndFocus;
            return true;
        }

        return false;
    }

    public static IntPtr GetRootWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return IntPtr.Zero;

        var root = GetAncestor(hwnd, GA_ROOT);
        return root != IntPtr.Zero ? root : hwnd;
    }

    public static bool TryResolveInputFocusWindow(IntPtr rootWindow, out IntPtr inputWindow)
    {
        inputWindow = IntPtr.Zero;
        if (!IsKnownWindow(rootWindow))
            return false;

        var root = GetRootWindow(rootWindow);
        if (TryGetRenderFocusWindow(root, out var renderFocus) &&
            IsChromeRenderWidgetHost(renderFocus))
        {
            inputWindow = renderFocus;
            return true;
        }

        if (TryFindDescendantByClassSubstring(root, "Chrome_RenderWidgetHostHWND", out var renderWidget))
        {
            inputWindow = renderWidget;
            return true;
        }

        inputWindow = root;
        return true;
    }

    public static bool TryRunAttachedInput(
        IntPtr rootWindow,
        Action? prepareFocus,
        Func<bool> sendInput,
        out bool sendResult)
    {
        sendResult = false;
        if (!TryResolveInputFocusWindow(rootWindow, out var inputWindow))
            return false;

        if (TryGetWindowProcessId(rootWindow, out var processId) && processId != 0)
        {
            try { AllowSetForegroundWindow((int)processId); }
            catch { }
        }

        var currentThread = GetCurrentThreadId();
        var inputThread = GetWindowThreadId(inputWindow);
        var root = GetRootWindow(rootWindow);
        var rootThread = GetWindowThreadId(root);
        var foreground = GetForegroundWindow();
        var foregroundThread = foreground != IntPtr.Zero ? GetWindowThreadId(foreground) : 0;

        var attachments = new List<(uint From, uint To)>();
        void TryAttach(uint from, uint to)
        {
            if (from == 0 || to == 0 || from == to)
                return;

            if (AttachThreadInput(from, to, true))
                attachments.Add((from, to));
        }

        try
        {
            var rootWasForeground = IsForegroundWindow(root);
            TryAttach(currentThread, inputThread);
            TryAttach(currentThread, rootThread);
            TryAttach(currentThread, foregroundThread);

            if (!rootWasForeground)
            {
                try { ShowWindow(root, SW_RESTORE); } catch { }
                SetForegroundWindow(root);
                Thread.Sleep(40);
            }

            prepareFocus?.Invoke();
            Thread.Sleep(50);
            sendResult = sendInput();
            return true;
        }
        finally
        {
            for (var i = attachments.Count - 1; i >= 0; i--)
            {
                var (from, to) = attachments[i];
                AttachThreadInput(from, to, false);
            }
        }
    }

    private static bool IsChromeRenderWidgetHost(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero)
            return false;

        var className = GetClassNameSafe(hwnd);
        return className.Contains("Chrome_RenderWidgetHostHWND", StringComparison.OrdinalIgnoreCase);
    }

    private static bool TryFindDescendantByClassSubstring(
        IntPtr parent,
        string classSubstring,
        out IntPtr found)
    {
        found = IntPtr.Zero;
        if (!IsKnownWindow(parent))
            return false;

        var match = IntPtr.Zero;
        SearchDescendants(parent);
        found = match;
        return found != IntPtr.Zero;

        void SearchDescendants(IntPtr hwnd)
        {
            if (match != IntPtr.Zero)
                return;

            EnumChildWindows(
                hwnd,
                (child, _) =>
                {
                    if (match != IntPtr.Zero)
                        return false;

                    if (GetClassNameSafe(child).Contains(classSubstring, StringComparison.OrdinalIgnoreCase))
                    {
                        match = child;
                        return false;
                    }

                    SearchDescendants(child);
                    return match == IntPtr.Zero;
                },
                IntPtr.Zero);
        }
    }

    public static bool SendPasteShortcut()
    {
        return SendKeyCombo(VK_CONTROL, VK_V) ||
            SendKeyComboFallback(VK_CONTROL, VK_V);
    }

    public static bool SendCopyShortcut()
    {
        return SendKeyCombo(VK_CONTROL, VK_C) ||
            SendKeyComboFallback(VK_CONTROL, VK_C);
    }

    public static bool TryClickAutomationElement(AutomationElement element)
    {
        try
        {
            var rect = element.Current.BoundingRectangle;
            if (rect.IsEmpty || rect.Width <= 0 || rect.Height <= 0)
                return false;

            var x = (int)(rect.X + Math.Max(4, rect.Width / 2));
            var y = (int)(rect.Y + Math.Max(4, rect.Height / 2));
            SetCursorPos(x, y);
            Thread.Sleep(30);
            mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
            mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
            Thread.Sleep(50);
            return true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.EmbeddedTerminalClick", ex);
            return false;
        }
    }

    public static bool SendTextViaVkKeys(string text, int maxTextLength = 160)
    {
        if (string.IsNullOrEmpty(text) || text.Length > maxTextLength)
            return false;
        if (text.Contains('\r') || text.Contains('\n'))
            return false;

        try
        {
            foreach (var ch in text)
            {
                var packed = VkKeyScan(ch);
                if (packed == -1)
                {
                    DebugTrace.Log("SelectedText", $"VkKeyScan unsupported char='{ch}'");
                    return false;
                }

                var vk = (ushort)(packed & 0xFF);
                var needsShift = (packed & 0x100) != 0;
                var inputs = new List<INPUT>(4);
                if (needsShift)
                    inputs.Add(MakeKeyInput(VK_SHIFT, false));
                inputs.Add(MakeKeyInput(vk, false));
                inputs.Add(MakeKeyInput(vk, true));
                if (needsShift)
                    inputs.Add(MakeKeyInput(VK_SHIFT, true));

                var sent = SendInput((uint)inputs.Count, inputs.ToArray(), InputStructSize);
                if (sent != inputs.Count)
                {
                    DebugTrace.Log("SelectedText", $"Vk SendInput failed sent={sent}/{inputs.Count}, error={Marshal.GetLastWin32Error()}");
                    return false;
                }

                Thread.Sleep(8);
            }

            return true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.VkInput", ex);
            return false;
        }
    }

    public static bool SendPasteViaSendKeys()
    {
        try
        {
            System.Windows.Forms.SendKeys.SendWait("^v");
            return true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.SendKeysPaste", ex);
            return false;
        }
    }

    public static bool SendUnicodeText(string text, int maxTextLength = 160)
    {
        if (string.IsNullOrEmpty(text) || text.Length > maxTextLength)
            return false;
        if (text.Contains('\r') || text.Contains('\n'))
            return false;

        try
        {
            foreach (var chunk in ChunkUtf16(text, 32))
            {
                var inputs = new List<INPUT>(chunk.Length * 2);
                foreach (var unit in chunk)
                {
                    inputs.Add(MakeUnicodeInput(unit, false));
                    inputs.Add(MakeUnicodeInput(unit, true));
                }

                var sent = SendInput((uint)inputs.Count, inputs.ToArray(), InputStructSize);
                if (sent != inputs.Count)
                {
                    DebugTrace.Log("SelectedText", $"Unicode SendInput failed sent={sent}/{inputs.Count}, error={Marshal.GetLastWin32Error()}");
                    return false;
                }

                Thread.Sleep(8);
            }

            return true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.UnicodeInput", ex);
            return false;
        }
    }

    /// <summary>
    /// SendInput does not reset keyboard state (documented MSDN caveat): modifiers the
    /// user still physically holds — typically the Alt of the recording hotkey — would
    /// turn Ctrl+V into Ctrl+Alt+V at the target. Wait briefly for release, then
    /// force-release leftovers inside the same batch. The combo modifier goes down
    /// first so a bare Alt/Win key-up cannot activate the menu bar or Start menu.
    /// </summary>
    private static bool SendKeyCombo(int modifier, int key)
    {
        WaitForPollutingModifierRelease(600);

        var inputs = new List<INPUT>(10)
        {
            MakeKeyInput((ushort)modifier, false)
        };
        foreach (var vk in PollutingModifierVks)
        {
            if (IsPhysicalKeyDown(vk))
                inputs.Add(MakeKeyInput(vk, true));
        }
        inputs.Add(MakeKeyInput((ushort)key, false));
        inputs.Add(MakeKeyInput((ushort)key, true));
        inputs.Add(MakeKeyInput((ushort)modifier, true));

        var sent = SendInput((uint)inputs.Count, inputs.ToArray(), InputStructSize);
        if (sent != inputs.Count)
        {
            var err = Marshal.GetLastWin32Error();
            DebugTrace.Log("SelectedText", $"SendInput failed sent={sent}/{inputs.Count}, size={InputStructSize}, error={err}");
        }
        return sent == inputs.Count;
    }

    private static readonly ushort[] PollutingModifierVks =
    {
        VK_LSHIFT_EX, VK_RSHIFT_EX, VK_LMENU_EX, VK_RMENU_EX, VK_LWIN_EX, VK_RWIN_EX,
    };

    private static void WaitForPollutingModifierRelease(int timeoutMs)
    {
        var stopwatch = Stopwatch.StartNew();
        while (stopwatch.ElapsedMilliseconds < timeoutMs)
        {
            if (!PollutingModifierVks.Any(IsPhysicalKeyDown))
                return;

            Thread.Sleep(15);
        }

        DebugTrace.Log("SelectedText", "modifier release wait timed out; forcing key-up");
    }

    private static bool IsPhysicalKeyDown(ushort vk) =>
        (GetAsyncKeyState(vk) & 0x8000) != 0;

    private static bool SendKeyComboFallback(int modifier, int key)
    {
        try
        {
            keybd_event((byte)modifier, 0, 0, UIntPtr.Zero);
            keybd_event((byte)key, 0, 0, UIntPtr.Zero);
            keybd_event((byte)key, 0, KEYBD_EVENT_KEYUP, UIntPtr.Zero);
            keybd_event((byte)modifier, 0, KEYBD_EVENT_KEYUP, UIntPtr.Zero);
            DebugTrace.Log("SelectedText", $"keybd_event combo attempted after SendInput rejection key=0x{key:X2}");
            return true;
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("SelectedText.keybd_event", ex);
            return false;
        }
    }

    private static bool IsEditReadOnly(IntPtr hwnd)
    {
        var style = GetWindowLong(hwnd, GWL_STYLE);
        return (style & ES_READONLY) == ES_READONLY;
    }

    private static bool TryGetWindowProcessName(IntPtr hwnd, out string processName)
    {
        processName = "";
        if (!TryGetWindowProcessId(hwnd, out var processId) || processId == 0)
            return false;

        try
        {
            using var process = Process.GetProcessById((int)processId);
            processName = process.ProcessName;
            return !string.IsNullOrWhiteSpace(processName);
        }
        catch
        {
            return false;
        }
    }

    private static string GetClassNameSafe(IntPtr hwnd)
    {
        try
        {
            var builder = new StringBuilder(256);
            return GetClassName(hwnd, builder, builder.Capacity) > 0
                ? builder.ToString()
                : "";
        }
        catch
        {
            return "";
        }
    }

    private static INPUT MakeKeyInput(ushort vk, bool keyUp)
    {
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            ki = new KEYBDINPUT
            {
                wVk = vk,
                wScan = 0,
                dwFlags = keyUp ? (uint)KEYEVENTF_KEYUP : 0,
                time = 0,
                dwExtraInfo = IntPtr.Zero
            }
        };
    }

    private static INPUT MakeUnicodeInput(ushort codeUnit, bool keyUp)
    {
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = codeUnit,
                dwFlags = (uint)(KEYEVENTF_UNICODE | (keyUp ? KEYEVENTF_KEYUP : 0)),
                time = 0,
                dwExtraInfo = IntPtr.Zero
            }
        };
    }

    private static IEnumerable<ushort[]> ChunkUtf16(string text, int maxUnits)
    {
        var units = text.ToCharArray().Select(c => (ushort)c).ToArray();
        for (var i = 0; i < units.Length; i += maxUnits)
            yield return units.Skip(i).Take(Math.Min(maxUnits, units.Length - i)).ToArray();
    }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    private static extern short VkKeyScan(char ch);

    [DllImport("user32.dll")]
    private static extern IntPtr GetAncestor(IntPtr hwnd, int gaFlags);

    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(int dwProcessId);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumChildProc lpEnumFunc, IntPtr lParam);

    private delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO lpgui);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SendMessageTimeout(
        IntPtr hWnd,
        int msg,
        IntPtr wParam,
        IntPtr lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        int msg,
        IntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, StringBuilder lParam);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessage(IntPtr hWnd, int msg, out int wParam, out int lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct INPUT
    {
        [FieldOffset(0)] public int type;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GUITHREADINFO
    {
        public int cbSize;
        public int flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public RECT rcCaret;
    }
}
