using System.Windows.Threading;
using LobsterInput.Helpers;

namespace LobsterInput.Services.HotKeys;

public sealed class HotKeyCaptureService : IDisposable
{
    public static HotKeyCaptureService Instance { get; } = new();

    private IntPtr _hookId = IntPtr.Zero;
    private LowLevelKeyboardProc? _hookProc;
    private Action<HotKeyConfig?>? _onCaptured;
    private bool _completionPending;
    private bool _disposed;

    private HotKeyCaptureService()
    {
    }

    public bool IsCapturing => _hookId != IntPtr.Zero;

    public bool Start(Action<HotKeyConfig?> onCaptured)
    {
        Cancel();

        _onCaptured = onCaptured;
        _completionPending = false;
        _hookProc = RecordHookCallback;

        _hookId = KeyboardHookInterop.Install(_hookProc, out var err);

        if (_hookId != IntPtr.Zero)
            return true;

        DebugTrace.Log("HotKeyCapture", $"Capture hook unavailable: {err}");
        _hookProc = null;
        _onCaptured = null;
        return false;
    }

    public void Cancel()
    {
        StopHook();
        _onCaptured = null;
        _completionPending = false;
    }

    private IntPtr RecordHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0 &&
            (wParam == (IntPtr)KeyboardHookInterop.WM_KEYDOWN ||
             wParam == (IntPtr)KeyboardHookInterop.WM_SYSKEYDOWN))
        {
            var hookStruct = KeyboardHookInterop.ReadKeyboardEvent(lParam);
            var vk = hookStruct.vkCode;

            if (vk == 0x1B)
            {
                CompleteOnUiThread(null);
                return (IntPtr)1;
            }

            if (KeyboardHookInterop.IsModifierKey(vk))
                return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);

            var modifiers = KeyboardHookInterop.GetCurrentModifiers();
            if (modifiers == ModifierKeys.None)
                return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);

            CompleteOnUiThread(new HotKeyConfig
            {
                Modifiers = modifiers,
                KeyCode = vk
            });

            return (IntPtr)1;
        }

        return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);
    }

    private void CompleteOnUiThread(HotKeyConfig? config)
    {
        if (_completionPending) return;

        _completionPending = true;
        System.Windows.Application.Current?.Dispatcher.BeginInvoke(
            DispatcherPriority.Normal,
            () =>
            {
                var callback = _onCaptured;
                StopHook();
                _onCaptured = null;
                _completionPending = false;
                callback?.Invoke(config);
            });
    }

    private void StopHook()
    {
        KeyboardHookInterop.Uninstall(_hookId);
        _hookId = IntPtr.Zero;
        _hookProc = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Cancel();
    }

}
