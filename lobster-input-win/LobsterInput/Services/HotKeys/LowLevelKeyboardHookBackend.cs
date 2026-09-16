using System.Diagnostics;
using LobsterInput.Helpers;

namespace LobsterInput.Services.HotKeys;

public sealed class LowLevelKeyboardHookBackend : IHotKeyBackend
{
    private readonly Dictionary<int, HotKeyConfig> _activeHotKeys = new();
    private IReadOnlyDictionary<HotKeyCombo, HotKeyConfig> _configs =
        new Dictionary<HotKeyCombo, HotKeyConfig>();
    private IntPtr _hookId = IntPtr.Zero;
    private LowLevelKeyboardProc? _hookProc;
    private ModifierKeys _currentModifiers;
    private readonly List<int> _pressedModifierKeys = new();
    private readonly List<int> _pendingModifierKeys = new();
    private readonly List<int> _consumedModifierKeys = new();
    private readonly List<int> _replayedModifierKeys = new();
    private bool _disposed;

    public bool IsListening { get; private set; }

    public event Action<HotKeyCombo>? HotKeyPressed;
    public event Action<string>? Error;

    public void Start(IReadOnlyDictionary<HotKeyCombo, HotKeyConfig> configs)
    {
        if (IsListening) return;

        _configs = new Dictionary<HotKeyCombo, HotKeyConfig>(configs);
        _hookProc = HookCallback;
        _hookId = KeyboardHookInterop.Install(_hookProc, out var err);

        if (_hookId == IntPtr.Zero)
        {
            Debug.WriteLine($"[HotKeyBackend] Keyboard hook failed, error={err}");
            DebugTrace.Log("HotKeyBackend", $"Keyboard hook failed, error={err}");
            Error?.Invoke($"Hotkey hook unavailable: {err}");
            _hookProc = null;
            return;
        }

        IsListening = true;
        Debug.WriteLine("[HotKeyBackend] Low-level keyboard hook installed");
        DebugTrace.Log("HotKeyBackend", "Low-level keyboard hook installed");
    }

    public void Stop()
    {
        KeyboardHookInterop.Uninstall(_hookId);

        _hookId = IntPtr.Zero;
        _hookProc = null;
        _activeHotKeys.Clear();
        ReleaseReplayedModifiers();
        _pressedModifierKeys.Clear();
        _pendingModifierKeys.Clear();
        _consumedModifierKeys.Clear();
        _currentModifiers = ModifierKeys.None;
        IsListening = false;
        Debug.WriteLine("[HotKeyBackend] Low-level keyboard hook removed");
        DebugTrace.Log("HotKeyBackend", "Low-level keyboard hook removed");
    }

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (nCode < 0)
                return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);

            var hookStruct = KeyboardHookInterop.ReadKeyboardEvent(lParam);
            if (KeyboardHookInterop.IsInjected(hookStruct))
                return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);

            var vk = hookStruct.vkCode;

            if (wParam == (IntPtr)KeyboardHookInterop.WM_KEYDOWN ||
                wParam == (IntPtr)KeyboardHookInterop.WM_SYSKEYDOWN)
            {
                return HandleKeyDown(nCode, wParam, lParam, vk);
            }

            if (wParam == (IntPtr)KeyboardHookInterop.WM_KEYUP ||
                wParam == (IntPtr)KeyboardHookInterop.WM_SYSKEYUP)
            {
                return HandleKeyUp(nCode, wParam, lParam, vk);
            }

            return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);
        }
        catch (Exception ex)
        {
            DebugTrace.Log("HotKeyBackend", $"Hook callback failed: {ex}");
            ReleaseReplayedModifiers();
            _pendingModifierKeys.Clear();
            _consumedModifierKeys.Clear();
            _currentModifiers = KeyboardHookInterop.GetCurrentModifiers();
            return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);
        }
    }

    private IntPtr HandleKeyDown(int nCode, IntPtr wParam, IntPtr lParam, int vk)
    {
        var modifier = KeyboardHookInterop.ModifierFromVirtualKey(vk);
        if (modifier != ModifierKeys.None)
        {
            AddUnique(_pressedModifierKeys, vk);
            _currentModifiers = BuildModifiers(_pressedModifierKeys);
            if (IsModifierPrefixForConfiguredHotKey(_currentModifiers))
            {
                AddUnique(_pendingModifierKeys, vk);
                return (IntPtr)1;
            }

            return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);
        }

        foreach (var (combo, config) in _configs)
        {
            if (config.IsDisabled) continue;
            if (config.KeyCode != vk || config.Modifiers != _currentModifiers) continue;

            var id = HotKeyId(combo);
            if (_activeHotKeys.ContainsKey(id))
                return (IntPtr)1;

            _activeHotKeys[id] = config;
            ConsumePendingModifiers();
            Debug.WriteLine($"[HotKeyBackend] Intercepted hotkey: {combo}");
            try
            {
                HotKeyPressed?.Invoke(combo);
            }
            catch (Exception ex)
            {
                DebugTrace.Log("HotKeyBackend", $"Hotkey handler failed combo={combo}: {ex}");
            }

            return (IntPtr)1;
        }

        ReplaySuppressedModifiersIfNeeded();
        return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);
    }

    private IntPtr HandleKeyUp(int nCode, IntPtr wParam, IntPtr lParam, int vk)
    {
        var modifier = KeyboardHookInterop.ModifierFromVirtualKey(vk);
        if (modifier != ModifierKeys.None)
        {
            RemoveKey(_pressedModifierKeys, vk);
            _currentModifiers = BuildModifiers(_pressedModifierKeys);
            if (RemoveKey(_pendingModifierKeys, vk))
            {
                ReplayPendingModifierTap(vk);
                return (IntPtr)1;
            }

            if (RemoveKey(_consumedModifierKeys, vk))
                return (IntPtr)1;

            if (RemoveKey(_replayedModifierKeys, vk))
                return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);

            return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);
        }

        foreach (var (id, config) in _activeHotKeys.ToList())
        {
            if (config.KeyCode != vk) continue;
            _activeHotKeys.Remove(id);
            return (IntPtr)1;
        }

        return KeyboardHookInterop.CallNext(_hookId, nCode, wParam, lParam);
    }

    private static int HotKeyId(HotKeyCombo combo) => 0x4C4F + (int)combo;

    private bool IsModifierPrefixForConfiguredHotKey(ModifierKeys modifiers)
    {
        if (modifiers == ModifierKeys.None)
            return false;

        if (!modifiers.HasFlag(ModifierKeys.Alt) &&
            !modifiers.HasFlag(ModifierKeys.Win))
        {
            return false;
        }

        return _configs.Values.Any(config =>
            !config.IsDisabled &&
            (config.Modifiers & modifiers) == modifiers);
    }

    private void ReplaySuppressedModifiersIfNeeded()
    {
        if (_pendingModifierKeys.Count == 0)
            return;

        var keys = _pendingModifierKeys.ToArray();
        _pendingModifierKeys.Clear();
        if (KeyboardHookInterop.SendKeyDowns(keys))
        {
            foreach (var key in keys)
                AddUnique(_replayedModifierKeys, key);
        }
        else
        {
            DebugTrace.Log("HotKeyBackend", $"Suppressed modifier replay failed keys={string.Join(",", keys)}");
        }
    }

    private static void ReplayPendingModifierTap(int vk)
    {
        if (!KeyboardHookInterop.SendKeyTap(vk))
        {
            DebugTrace.Log("HotKeyBackend", $"Suppressed modifier tap replay failed vk={vk}");
        }
    }

    private void ReleaseReplayedModifiers()
    {
        if (_replayedModifierKeys.Count == 0)
            return;

        var keys = _replayedModifierKeys.ToArray();
        Array.Reverse(keys);
        _replayedModifierKeys.Clear();
        if (!KeyboardHookInterop.SendKeyUps(keys))
        {
            DebugTrace.Log("HotKeyBackend", $"Replayed modifier release failed keys={string.Join(",", keys)}");
        }
    }

    private void ConsumePendingModifiers()
    {
        foreach (var key in _pendingModifierKeys)
            AddUnique(_consumedModifierKeys, key);
        _pendingModifierKeys.Clear();
    }

    private static ModifierKeys BuildModifiers(IEnumerable<int> virtualKeys)
    {
        var modifiers = ModifierKeys.None;
        foreach (var virtualKey in virtualKeys)
            modifiers |= KeyboardHookInterop.ModifierFromVirtualKey(virtualKey);
        return modifiers;
    }

    private static void AddUnique(ICollection<int> keys, int key)
    {
        if (!keys.Contains(key))
            keys.Add(key);
    }

    private static bool RemoveKey(ICollection<int> keys, int key)
    {
        if (!keys.Contains(key))
            return false;

        keys.Remove(key);
        return true;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        Stop();
    }
}
