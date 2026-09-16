using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Services.TextTargets;

namespace LobsterInput.Workflows;

internal enum RecordingContextProfile
{
    Dictation,
    SelectionAware
}

internal sealed class RecordingContextCapture
{
    private readonly object _clipboardGate = new();
    private SelectionSnapshot? _selectionSnapshot;
    private List<string> _clipboardHistory = new();
    private List<ClipboardContextItem> _clipboardItems = new();
    private readonly Task<SelectionSnapshot?>? _selectionSnapshotTask;
    private Task<List<string>>? _clipboardHistoryTask;
    private Task<List<ClipboardContextItem>>? _clipboardItemsTask;
    private readonly RecordingContextProfile _profile;
    private readonly TimeSpan _selectionTimeout;
    private readonly bool _deferClipboardCapture;

    private RecordingContextCapture(
        Task<SelectionSnapshot?>? selectionSnapshotTask,
        Task<List<string>>? clipboardHistoryTask,
        Task<List<ClipboardContextItem>>? clipboardItemsTask,
        RecordingContextProfile profile,
        bool deferClipboardCapture)
    {
        _selectionSnapshotTask = selectionSnapshotTask;
        _clipboardHistoryTask = clipboardHistoryTask;
        _clipboardItemsTask = clipboardItemsTask;
        _profile = profile;
        _deferClipboardCapture = deferClipboardCapture;
        _selectionTimeout = profile == RecordingContextProfile.SelectionAware
            ? TimeSpan.FromMilliseconds(3500)
            : TimeSpan.FromMilliseconds(650);
    }

    public static RecordingContextCapture Start(
        IntPtr? targetWindow,
        RecordingContextProfile profile)
    {
        if (profile == RecordingContextProfile.Dictation)
        {
            var dictationSelectionTask = StaTaskRunner.Run(() =>
            {
                try
                {
                    Thread.Sleep(120);
                    return TextTargetService.Instance.CaptureSnapshot(
                        targetWindow,
                        includeCommandCopyProbe: false);
                }
                catch (Exception ex)
                {
                    DebugTrace.LogError("RecordingContext.Selection", ex);
                    return null;
                }
            });

            var historyTask = ClipboardService.ClipboardAccessEnabled
                ? Task.Run(() => ClipboardService.ReadHistory(3))
                : null;

            return new RecordingContextCapture(
                dictationSelectionTask,
                historyTask,
                null,
                profile,
                false);
        }

        var includeCommandCopyProbe = profile == RecordingContextProfile.SelectionAware;

        var selectionTask = StaTaskRunner.Run(() =>
        {
            try
            {
                Thread.Sleep(120);
                return TextTargetService.Instance.CaptureSnapshot(
                    targetWindow,
                    includeCommandCopyProbe);
            }
            catch (Exception ex)
            {
                DebugTrace.LogError("RecordingContext.Selection", ex);
                return null;
            }
        });

        if (!ClipboardService.ClipboardAccessEnabled)
            return new RecordingContextCapture(selectionTask, null, null, profile, false);

        var deferClipboardCapture = profile == RecordingContextProfile.SelectionAware;
        Task<List<string>>? clipboardHistoryTask = null;
        Task<List<ClipboardContextItem>>? clipboardItemsTask = null;
        if (!deferClipboardCapture)
            StartClipboardTasks(out clipboardHistoryTask, out clipboardItemsTask);

        return new RecordingContextCapture(
            selectionTask,
            clipboardHistoryTask,
            clipboardItemsTask,
            profile,
            deferClipboardCapture);
    }

    public async Task<SelectionSnapshot?> ResolveSelectionSnapshotAsync()
    {
        if (_selectionSnapshot != null) return _selectionSnapshot;
        if (_selectionSnapshotTask == null) return null;

        try
        {
            _selectionSnapshot = await _selectionSnapshotTask.WaitAsync(_selectionTimeout);
            if (_selectionSnapshot != null &&
                ClipboardSentinel.IsInternal(_selectionSnapshot.Text))
            {
                DebugTrace.Log("RecordingContext", "dropped internal selection sentinel");
                _selectionSnapshot.Text = "";
            }
        }
        catch (TimeoutException)
        {
            DebugTrace.Log(
                "RecordingContext",
                $"Selection snapshot timed out before processing profile={_profile}, timeoutMs={_selectionTimeout.TotalMilliseconds:0}");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("RecordingContext.Selection", ex);
        }
        finally
        {
            EnsureClipboardCaptureStarted();
        }

        return _selectionSnapshot;
    }

    public async Task<List<string>> ResolveClipboardHistoryAsync()
    {
        if (_clipboardHistory.Count > 0) return _clipboardHistory;
        EnsureClipboardCaptureStarted();
        if (_clipboardHistoryTask == null) return new List<string>();

        try { _clipboardHistory = await _clipboardHistoryTask.WaitAsync(TimeSpan.FromMilliseconds(900)); }
        catch { _clipboardHistory = new List<string>(); }
        _clipboardHistory = _clipboardHistory
            .Where(text => !ClipboardSentinel.IsInternal(text))
            .ToList();
        return _clipboardHistory;
    }

    public async Task<List<ClipboardContextItem>> ResolveClipboardItemsAsync()
    {
        if (_clipboardItems.Count > 0) return _clipboardItems;
        EnsureClipboardCaptureStarted();
        if (_clipboardItemsTask == null) return new List<ClipboardContextItem>();

        try { _clipboardItems = await _clipboardItemsTask.WaitAsync(TimeSpan.FromMilliseconds(900)); }
        catch { _clipboardItems = new List<ClipboardContextItem>(); }
        _clipboardItems = _clipboardItems
            .Where(item => item.Kind != "text" || !ClipboardSentinel.IsInternal(item.Text))
            .ToList();
        return _clipboardItems;
    }

    private void EnsureClipboardCaptureStarted()
    {
        if (!_deferClipboardCapture || !ClipboardService.ClipboardAccessEnabled)
        {
            return;
        }

        lock (_clipboardGate)
        {
            if (_clipboardHistoryTask != null || _clipboardItemsTask != null)
                return;

            StartClipboardTasks(out _clipboardHistoryTask, out _clipboardItemsTask);
        }
    }

    private static void StartClipboardTasks(
        out Task<List<string>> clipboardHistoryTask,
        out Task<List<ClipboardContextItem>> clipboardItemsTask)
    {
        clipboardHistoryTask = Task.Run(() => ClipboardService.ReadHistory(5));
        clipboardItemsTask = StaTaskRunner.Run(() =>
        {
            try
            {
                return ClipboardService.ReadContextItems(1);
            }
            catch (Exception ex)
            {
                DebugTrace.LogError("RecordingContext.Clipboard", ex);
                return new List<ClipboardContextItem>();
            }
        });
    }
}
