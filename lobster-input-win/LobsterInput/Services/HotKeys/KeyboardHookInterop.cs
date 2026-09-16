using System.Diagnostics;
using System.Runtime.InteropServices;

namespace LobsterInput.Services.HotKeys;

internal delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

internal static class KeyboardHookInterop
{
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_KEYUP = 0x0101;
    public const int WM_SYSKEYDOWN = 0x0104;
    public const int WM_SYSKEYUP = 0x0105;

    private const int WH_KEYBOARD_LL = 13;
    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int VK_LSHIFT = 0xA0;
    private const int VK_RSHIFT = 0xA1;
    private const int VK_LMENU = 0xA4;
    private const int VK_RMENU = 0xA5;
    private const int VK_LWIN = 0x5B;
    private const int VK_RWIN = 0x5C;
    private const int INPUT_KEYBOARD = 1;
    private const int KEYEVENTF_KEYUP = 0x0002;
    private const int LLKHF_INJECTED = 0x00000010;

    public static IntPtr Install(LowLevelKeyboardProc proc, out int error)
    {
        error = 0;

        using var currentProcess = Process.GetCurrentProcess();
        using var currentModule = currentProcess.MainModule!;
        var hookId = SetWindowsHookEx(
            WH_KEYBOARD_LL,
            proc,
            GetModuleHandle(currentModule.ModuleName),
            0);

        if (hookId == IntPtr.Zero)
            error = Marshal.GetLastWin32Error();

        return hookId;
    }

    public static void Uninstall(IntPtr hookId)
    {
        if (hookId != IntPtr.Zero)
            UnhookWindowsHookEx(hookId);
    }

    public static IntPtr CallNext(IntPtr hookId, int nCode, IntPtr wParam, IntPtr lParam) =>
        CallNextHookEx(hookId, nCode, wParam, lParam);

    public static KeyboardHookEvent ReadKeyboardEvent(IntPtr lParam) =>
        Marshal.PtrToStructure<KeyboardHookEvent>(lParam);

    public static ModifierKeys GetCurrentModifiers()
    {
        var mods = ModifierKeys.None;
        if (IsKeyDown(VK_LCONTROL) || IsKeyDown(VK_RCONTROL)) mods |= ModifierKeys.Control;
        if (IsKeyDown(VK_LMENU) || IsKeyDown(VK_RMENU)) mods |= ModifierKeys.Alt;
        if (IsKeyDown(VK_LSHIFT) || IsKeyDown(VK_RSHIFT)) mods |= ModifierKeys.Shift;
        if (IsKeyDown(VK_LWIN) || IsKeyDown(VK_RWIN)) mods |= ModifierKeys.Win;
        return mods;
    }

    public static bool IsModifierKey(int vk) => ModifierFromVirtualKey(vk) != ModifierKeys.None;

    public static bool IsInjected(KeyboardHookEvent hookEvent) =>
        (hookEvent.flags & LLKHF_INJECTED) == LLKHF_INJECTED;

    public static ModifierKeys ModifierFromVirtualKey(int vk) => vk switch
    {
        VK_LCONTROL or VK_RCONTROL => ModifierKeys.Control,
        VK_LSHIFT or VK_RSHIFT => ModifierKeys.Shift,
        VK_LMENU or VK_RMENU => ModifierKeys.Alt,
        VK_LWIN or VK_RWIN => ModifierKeys.Win,
        _ => ModifierKeys.None
    };

    public static bool SendKeyDowns(IEnumerable<int> virtualKeys) =>
        SendKeyEvents(virtualKeys, keyUp: false);

    public static bool SendKeyUps(IEnumerable<int> virtualKeys) =>
        SendKeyEvents(virtualKeys, keyUp: true);

    public static bool SendKeyTap(int virtualKey)
    {
        var inputs = new[]
        {
            MakeKeyInput((ushort)virtualKey, keyUp: false),
            MakeKeyInput((ushort)virtualKey, keyUp: true)
        };

        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }

    private static bool SendKeyEvents(IEnumerable<int> virtualKeys, bool keyUp)
    {
        var inputs = new List<INPUT>();
        foreach (var virtualKey in virtualKeys)
            inputs.Add(MakeKeyInput((ushort)virtualKey, keyUp));

        if (inputs.Count == 0)
            return true;

        return SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<INPUT>()) == inputs.Count;
    }

    private static bool IsKeyDown(int vk) => (GetAsyncKeyState(vk) & 0x8000) != 0;

    private static INPUT MakeKeyInput(ushort vk, bool keyUp)
    {
        return new INPUT
        {
            type = INPUT_KEYBOARD,
            u = new INPUTUNION
            {
                ki = new KEYBDINPUT
                {
                    wVk = vk,
                    wScan = 0,
                    dwFlags = keyUp ? (uint)KEYEVENTF_KEYUP : 0,
                    time = 0,
                    dwExtraInfo = IntPtr.Zero
                }
            }
        };
    }

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelKeyboardProc lpfn,
        IntPtr hMod,
        uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    public struct KeyboardHookEvent
    {
        public int vkCode;
        public int scanCode;
        public int flags;
        public int time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public int type;
        public INPUTUNION u;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct INPUTUNION
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public HARDWAREINPUT hi;
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
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }
}
