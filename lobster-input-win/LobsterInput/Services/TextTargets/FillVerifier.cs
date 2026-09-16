using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Threading;
using LobsterInput.Helpers;

namespace LobsterInput.Services.TextTargets;

/// <summary>
/// 盲填结果确认器（对齐 Mac FillVerifier）：
/// 录音开始时挂载 UIA / WinEvent 观察者，盲填后等待目标 App 的内容变化通知。
/// xterm / Chromium 终端画布 TextPattern 往往读不回文本，但 Value/Name/TextChanged 事件仍会触发。
/// WinEvent 钩子必须常驻在持续泵消息的专用线程上：WINEVENT_OUTOFCONTEXT 回调经由
/// 挂钩线程的消息队列派发，而粘贴流程所在的 STA 工作线程在等待确认时会 Thread.Sleep，
/// 若钩子挂在该线程，确认窗口内回调永远无法送达。
/// </summary>
public sealed class FillVerifier
{
    public static FillVerifier Instance { get; } = new();
    private static readonly WinEventDelegate SharedWinEventDelegate = OnSharedWinEvent;

    private const uint EventObjectLocationChange = 0x800B;
    private const uint EventObjectValueChange = 0x800E;
    private const uint EventObjectTextSelectionChanged = 0x8014;
    private const int ObjIdCaret = -8;
    private const uint WineventOutOfContext = 0;
    private const uint WineventSkipOwnProcess = 0x0002;

    private static readonly object PumpGate = new();
    private static readonly ManualResetEventSlim PumpReady = new(false);
    private static Dispatcher? _pumpDispatcher;

    private readonly object _gate = new();
    private IntPtr _targetHwnd;
    private IntPtr _targetRootHwnd;
    private uint _targetProcessId;
    private AutomationElement? _scopeElement;
    private DateTime? _armedAtUtc;
    private DateTime? _changedAtUtc;
    private string _lastChangeSource = "";
    private long _attachmentGeneration;

    private AutomationPropertyChangedEventHandler? _propertyChangedHandler;
    private AutomationEventHandler? _automationEventHandler;
    private IntPtr _winEventHook = IntPtr.Zero;

    private FillVerifier()
    {
    }

    public bool IsAttached
    {
        get
        {
            lock (_gate)
                return _scopeElement != null || _winEventHook != IntPtr.Zero;
        }
    }

    public void Attach(IntPtr hwnd, AutomationElement? focusedElement = null)
    {
        Detach();
        if (hwnd == IntPtr.Zero || !TextTargetWin32.IsKnownWindow(hwnd))
            return;

        if (!TextTargetWin32.TryGetWindowProcessId(hwnd, out var processId) || processId == 0)
            return;

        long generation;
        lock (_gate)
        {
            generation = ++_attachmentGeneration;
            _targetHwnd = hwnd;
            _targetRootHwnd = TextTargetWin32.GetRootWindow(hwnd);
            _targetProcessId = processId;
            _armedAtUtc = null;
            _changedAtUtc = null;
            _lastChangeSource = "";
        }

        // WinEvent 钩子不依赖 UIA 树，必须先装：Electron 冷树拿不到 scope 元素时，
        // MSAA/WinEvent 通道仍是盲填确认的唯一被动信号源。
        var winEventHook = InstallWinEventHook(processId);
        var hookAccepted = false;
        lock (_gate)
        {
            if (_attachmentGeneration == generation)
            {
                _winEventHook = winEventHook;
                hookAccepted = true;
            }
        }
        if (!hookAccepted && winEventHook != IntPtr.Zero)
            RemoveWinEventHook(winEventHook);

        try
        {
            _scopeElement = ResolveScopeElement(hwnd, focusedElement);
            if (_scopeElement == null)
            {
                DebugTrace.Log(
                    "FillVerifier",
                    $"attach degraded to winEvent-only because scope element was unavailable hwnd=0x{hwnd.ToInt64():X}, winEvent={_winEventHook != IntPtr.Zero}");
                return;
            }

            _propertyChangedHandler = (sender, args) =>
                OnAutomationPropertyChanged(generation, sender, args);
            Automation.AddAutomationPropertyChangedEventHandler(
                _scopeElement,
                TreeScope.Subtree,
                _propertyChangedHandler,
                AutomationElement.NameProperty,
                ValuePattern.ValueProperty);

            _automationEventHandler = (sender, args) =>
                OnAutomationEvent(generation, sender, args);
            Automation.AddAutomationEventHandler(
                TextPattern.TextChangedEvent,
                _scopeElement,
                TreeScope.Subtree,
                _automationEventHandler);

            DebugTrace.Log(
                "FillVerifier",
                $"attach hwnd=0x{hwnd.ToInt64():X}, pid={processId}, scope={DescribeElement(_scopeElement)}, winEvent={_winEventHook != IntPtr.Zero}");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.Attach", ex);
            RemoveHandlers(new DetachSnapshot(
                _scopeElement,
                _propertyChangedHandler,
                _automationEventHandler,
                IntPtr.Zero));
            _scopeElement = null;
            _propertyChangedHandler = null;
            _automationEventHandler = null;
        }
    }

    public void Detach()
    {
        var snapshot = SnapshotAndClear();
        RemoveHandlers(snapshot);
    }

    public void DetachInBackground()
    {
        var snapshot = SnapshotAndClear();
        if (snapshot.IsEmpty)
            return;

        _ = Task.Run(() =>
        {
            var stopwatch = Stopwatch.StartNew();
            RemoveHandlers(snapshot);
            DebugTrace.Log("FillVerifier", $"detach background completed elapsedMs={stopwatch.ElapsedMilliseconds}");
        });
    }

    private DetachSnapshot SnapshotAndClear()
    {
        AutomationElement? scopeElement;
        AutomationPropertyChangedEventHandler? propertyChangedHandler;
        AutomationEventHandler? automationEventHandler;
        IntPtr winEventHook;

        lock (_gate)
        {
            _attachmentGeneration++;
            scopeElement = _scopeElement;
            propertyChangedHandler = _propertyChangedHandler;
            automationEventHandler = _automationEventHandler;
            winEventHook = _winEventHook;

            _scopeElement = null;
            _propertyChangedHandler = null;
            _automationEventHandler = null;
            _winEventHook = IntPtr.Zero;
            _targetHwnd = IntPtr.Zero;
            _targetRootHwnd = IntPtr.Zero;
            _targetProcessId = 0;
            _armedAtUtc = null;
            _changedAtUtc = null;
            _lastChangeSource = "";
        }

        return new DetachSnapshot(
            scopeElement,
            propertyChangedHandler,
            automationEventHandler,
            winEventHook);
    }

    private static void RemoveHandlers(DetachSnapshot snapshot)
    {
        try
        {
            if (snapshot.ScopeElement != null && snapshot.PropertyChangedHandler != null)
            {
                Automation.RemoveAutomationPropertyChangedEventHandler(
                    snapshot.ScopeElement,
                    snapshot.PropertyChangedHandler);
            }

            if (snapshot.ScopeElement != null && snapshot.AutomationEventHandler != null)
            {
                Automation.RemoveAutomationEventHandler(
                    TextPattern.TextChangedEvent,
                    snapshot.ScopeElement,
                    snapshot.AutomationEventHandler);
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.DetachHandlers", ex);
        }

        if (snapshot.WinEventHook != IntPtr.Zero)
        {
            RemoveWinEventHook(snapshot.WinEventHook);
        }
    }

    private static IntPtr InstallWinEventHook(uint processId)
    {
        var dispatcher = EnsurePumpDispatcher();
        if (dispatcher == null)
            return IntPtr.Zero;

        try
        {
            return dispatcher.Invoke(() => SetWinEventHook(
                EventObjectLocationChange,
                EventObjectTextSelectionChanged,
                IntPtr.Zero,
                SharedWinEventDelegate,
                processId,
                0,
                WineventOutOfContext | WineventSkipOwnProcess));
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.InstallWinEventHook", ex);
            return IntPtr.Zero;
        }
    }

    private static void RemoveWinEventHook(IntPtr hook)
    {
        try
        {
            var dispatcher = EnsurePumpDispatcher();
            if (dispatcher != null)
            {
                dispatcher.Invoke(() => UnhookWinEvent(hook));
                return;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.RemoveWinEventHook", ex);
        }

        UnhookWinEvent(hook);
    }

    private static Dispatcher? EnsurePumpDispatcher()
    {
        lock (PumpGate)
        {
            if (_pumpDispatcher != null &&
                !_pumpDispatcher.HasShutdownStarted &&
                !_pumpDispatcher.HasShutdownFinished)
            {
                return _pumpDispatcher;
            }

            PumpReady.Reset();
            var thread = new Thread(() =>
            {
                _pumpDispatcher = Dispatcher.CurrentDispatcher;
                PumpReady.Set();
                Dispatcher.Run();
            })
            {
                IsBackground = true,
                Name = "LobsterInput FillVerifier pump"
            };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();

            return PumpReady.Wait(TimeSpan.FromSeconds(2)) ? _pumpDispatcher : null;
        }
    }

    public void Arm()
    {
        lock (_gate)
        {
            _armedAtUtc = DateTime.UtcNow;
            _changedAtUtc = null;
            _lastChangeSource = "";
        }
    }

    public bool WaitForChange(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (IsConfirmed)
                return true;

            Thread.Sleep(30);
        }

        return IsConfirmed;
    }

    public bool IsConfirmed
    {
        get
        {
            lock (_gate)
            {
                return _armedAtUtc.HasValue &&
                    _changedAtUtc.HasValue &&
                    _changedAtUtc.Value >= _armedAtUtc.Value;
            }
        }
    }

    public string LastChangeSource
    {
        get
        {
            lock (_gate)
                return _lastChangeSource;
        }
    }

    private void MarkChanged(long generation, string source)
    {
        lock (_gate)
        {
            if (generation != _attachmentGeneration || !_armedAtUtc.HasValue)
                return;

            _changedAtUtc = DateTime.UtcNow;
            _lastChangeSource = source;
        }
    }

    private void OnAutomationPropertyChanged(
        long generation,
        object sender,
        AutomationPropertyChangedEventArgs e)
    {
        try
        {
            if (sender is not AutomationElement element)
                return;

            if (!IsRelevantElement(generation, element))
                return;

            var propertyName = e.Property.ProgrammaticName ?? e.Property.Id.ToString();
            MarkChanged(generation, $"uia-property:{propertyName}");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.PropertyChanged", ex);
        }
    }

    private void OnAutomationEvent(long generation, object sender, AutomationEventArgs e)
    {
        try
        {
            if (sender is AutomationElement element && !IsRelevantElement(generation, element))
                return;

            MarkChanged(generation, $"uia-event:{e.EventId.ProgrammaticName}");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.AutomationEvent", ex);
        }
    }

    private static void OnSharedWinEvent(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        Instance.OnWinEvent(
            hWinEventHook,
            eventType,
            hwnd,
            idObject,
            idChild,
            dwEventThread,
            dwmsEventTime);
    }

    private void OnWinEvent(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime)
    {
        try
        {
            if (hwnd == IntPtr.Zero)
                return;

            long generation;
            uint targetProcessId;
            IntPtr targetRoot;
            lock (_gate)
            {
                if (hWinEventHook == IntPtr.Zero || hWinEventHook != _winEventHook)
                    return;

                generation = _attachmentGeneration;
                targetProcessId = _targetProcessId;
                targetRoot = _targetRootHwnd;
            }

            // 只认文本写入的直接迹象：值变化、文本选区变化、插入符移动（经典 Win32
            // 控件的插入符移动无需无障碍激活即有事件）。NAMECHANGE/LIVEREGION 这类
            // 杂音事件会把聊天页/动态页的无关更新误判成填充成功，而误判成功没有兜底。
            var relevant = eventType is EventObjectValueChange
                or EventObjectTextSelectionChanged ||
                (eventType == EventObjectLocationChange && idObject == ObjIdCaret);
            if (!relevant)
                return;

            if (!TextTargetWin32.TryGetWindowProcessId(hwnd, out var processId) || processId != targetProcessId)
                return;

            // 同进程但不同顶层窗口的事件（如 explorer 的任务栏时钟 NAMECHANGE、
            // 浏览器其它窗口）不能作为本次填充的确认信号。
            if (targetRoot != IntPtr.Zero && TextTargetWin32.GetRootWindow(hwnd) != targetRoot)
                return;

            MarkChanged(generation, $"win-event:0x{eventType:X}");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.WinEvent", ex);
        }
    }

    private bool IsRelevantElement(long generation, AutomationElement element)
    {
        try
        {
            uint targetProcessId;
            lock (_gate)
            {
                if (generation != _attachmentGeneration)
                    return false;
                targetProcessId = _targetProcessId;
            }

            var processId = element.Current.ProcessId;
            if (targetProcessId != 0 && processId != (int)targetProcessId)
                return false;

            return true;
        }
        catch
        {
            return false;
        }
    }

    private static AutomationElement? ResolveScopeElement(IntPtr hwnd, AutomationElement? focusedElement)
    {
        if (focusedElement != null)
        {
            try
            {
                var walker = TreeWalker.ControlViewWalker;
                for (var current = focusedElement; current != null; current = walker.GetParent(current))
                {
                    var className = current.Current.ClassName ?? "";
                    if (className.Contains("Chrome_WidgetWin", StringComparison.OrdinalIgnoreCase) ||
                        className.Contains("xterm-screen", StringComparison.OrdinalIgnoreCase) ||
                        className.Contains("terminal-wrapper", StringComparison.OrdinalIgnoreCase))
                    {
                        return current;
                    }
                }

                return focusedElement;
            }
            catch (Exception ex)
            {
                DebugTrace.LogError("FillVerifier.ResolveScopeFocused", ex);
            }
        }

        try
        {
            return AutomationElement.FromHandle(hwnd);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("FillVerifier.ResolveScopeHandle", ex);
            return null;
        }
    }

    private static string DescribeElement(AutomationElement element)
    {
        try
        {
            return element.Current.ClassName ?? element.Current.ControlType.ProgrammaticName;
        }
        catch
        {
            return "unknown";
        }
    }

    private delegate void WinEventDelegate(
        IntPtr hWinEventHook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint dwEventThread,
        uint dwmsEventTime);

    [DllImport("user32.dll")]
    private static extern IntPtr SetWinEventHook(
        uint eventMin,
        uint eventMax,
        IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc,
        uint idProcess,
        uint idThread,
        uint dwFlags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    private sealed record DetachSnapshot(
        AutomationElement? ScopeElement,
        AutomationPropertyChangedEventHandler? PropertyChangedHandler,
        AutomationEventHandler? AutomationEventHandler,
        IntPtr WinEventHook)
    {
        public bool IsEmpty =>
            ScopeElement == null &&
            PropertyChangedHandler == null &&
            AutomationEventHandler == null &&
            WinEventHook == IntPtr.Zero;
    }
}
