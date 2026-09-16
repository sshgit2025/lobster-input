using System.Diagnostics;
using System.Windows;
using LobsterInput.Helpers;
using LobsterInput.Services;
using LobsterInput.Views.Overlays;

namespace LobsterInput.Lifecycle;

public interface IOverlayPresenter : IDisposable
{
    void Initialize();
}

public sealed class OverlayPresenter : IOverlayPresenter
{
    private readonly HotKeyHandler _handler;
    private readonly HotKeyService _hotKeys;
    private readonly AudioRecorderService _recorder;
    private RecordingOverlay? _recordingOverlay;
    private RealtimeRecordingOverlay? _realtimeOverlay;
    private ResultOverlay? _resultOverlay;
    private OpenClawTaskOverlay? _openClawTaskOverlay;
    private ClarifyOverlay? _clarifyOverlay;
    private TipOverlay? _tipOverlay;
    private bool _initialized;
    private bool _disposed;

    public OverlayPresenter(
        HotKeyHandler handler,
        HotKeyService hotKeys,
        AudioRecorderService recorder)
    {
        _handler = handler;
        _hotKeys = hotKeys;
        _recorder = recorder;
    }

    public void Initialize()
    {
        if (_initialized) return;
        _initialized = true;

        _recordingOverlay = new RecordingOverlay();
        _realtimeOverlay = new RealtimeRecordingOverlay();
        _resultOverlay = new ResultOverlay();
        _openClawTaskOverlay = new OpenClawTaskOverlay();
        _clarifyOverlay = new ClarifyOverlay();
        _tipOverlay = new TipOverlay();

        _hotKeys.OnHotKeyPressed = OnHotKeyPressed;
        _hotKeys.HookError += OnHookError;

        _handler.ShowRecordingOverlay += OnShowRecordingOverlay;
        _handler.HideRecordingOverlay += OnHideRecordingOverlay;
        _handler.ShowRealtimeOverlay += OnShowRealtimeOverlay;
        _handler.HideRealtimeOverlay += OnHideRealtimeOverlay;
        _handler.UpdateRealtimeText += OnUpdateRealtimeText;
        _handler.ShowTip += OnShowTip;
        _handler.ShowClarify += OnShowClarify;
        _handler.ShowResult += OnShowResult;
        _handler.UpdateSearchResult += OnUpdateSearchResult;
        OpenClawManager.Instance.TaskEvent += OnOpenClawTaskEvent;

        _recordingOverlay.CancelRequested += OnRecordingCancelRequested;
        _realtimeOverlay.CancelRequested += OnRealtimeCancelRequested;
    }

    private void OnHotKeyPressed(HotKeyCombo combo)
    {
        Debug.WriteLine($"[OverlayPresenter] HotKey pressed: {combo}");
        _handler.Handle(combo);
    }

    private void OnHookError(string message)
    {
        RunOnUi(() => _tipOverlay?.ShowTip(message));
    }

    private void OnShowRecordingOverlay()
    {
        RunOnUi(() => _recordingOverlay?.ShowOverlay());
    }

    private void OnHideRecordingOverlay()
    {
        RunOnUi(() => _recordingOverlay?.HideOverlay());
    }

    private void OnShowRealtimeOverlay()
    {
        RunOnUi(() => _realtimeOverlay?.ShowOverlay());
    }

    private void OnHideRealtimeOverlay()
    {
        RunOnUi(() => _realtimeOverlay?.HideOverlay());
    }

    private void OnUpdateRealtimeText(string text)
    {
        RunOnUi(() => _realtimeOverlay?.UpdateLiveText(text));
    }

    private void OnShowTip(string message)
    {
        RunOnUi(() => _tipOverlay?.ShowTip(message));
    }

    private void OnShowClarify(string question)
    {
        RunOnUi(() => _clarifyOverlay?.ShowQuestion(question));
    }

    private void OnShowResult(string text, bool isMarkdown)
    {
        var requestedAt = Stopwatch.GetTimestamp();
        DebugTrace.Log(
            "OverlayPresenter",
            $"show result requested markdown={isMarkdown}, text={text.Length}");
        RunOnUi(() =>
        {
            var elapsedMs = Stopwatch.GetElapsedTime(requestedAt).TotalMilliseconds;
            DebugTrace.Log(
                "OverlayPresenter",
                $"show result ui begin markdown={isMarkdown}, dispatchMs={elapsedMs:0}");
            if (isMarkdown)
                _resultOverlay?.ShowMarkdown(text);
            else
                _resultOverlay?.ShowResult(text);
            DebugTrace.Log(
                "OverlayPresenter",
                $"show result ui end markdown={isMarkdown}, dispatchMs={Stopwatch.GetElapsedTime(requestedAt).TotalMilliseconds:0}");
        });
    }

    private void OnUpdateSearchResult(Guid streamId, string text)
    {
        RunOnUi(() => _resultOverlay?.UpdateMarkdown(text, streamId));
    }

    private void OnOpenClawTaskEvent(OpenClawTaskEvent evt)
    {
        RunOnUi(() =>
        {
            if (_openClawTaskOverlay == null) return;
            switch (evt.Type)
            {
                case OpenClawTaskEventType.Connecting:
                    _openClawTaskOverlay.ShowConnecting();
                    break;
                case OpenClawTaskEventType.Started:
                    _openClawTaskOverlay.ShowRunning(evt.RunId, evt.MessageSeq);
                    break;
                case OpenClawTaskEventType.Progress:
                    _openClawTaskOverlay.UpdateTranscript(evt.Text);
                    break;
                case OpenClawTaskEventType.Finished:
                    _openClawTaskOverlay.Finish(evt.Text);
                    break;
                case OpenClawTaskEventType.Aborted:
                    _openClawTaskOverlay.MarkAborted(evt.Text);
                    break;
                case OpenClawTaskEventType.Error:
                    _openClawTaskOverlay.ShowError(evt.Text);
                    break;
            }
        });
    }

    private void OnRecordingCancelRequested(object? sender, EventArgs e)
    {
        if (_recorder.State is RecordingState.Recording or RecordingState.Idle)
        {
            _handler.CancelDuringRecording();
            return;
        }

        if (_recorder.State == RecordingState.Processing)
            _handler.CancelDuringProcessing();
    }

    private void OnRealtimeCancelRequested(object? sender, EventArgs e)
    {
        _handler.CancelDuringRealtime();
    }

    private static void RunOnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            action();
            return;
        }

        dispatcher.Invoke(action);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _hotKeys.OnHotKeyPressed = null;
        _hotKeys.HookError -= OnHookError;

        _handler.ShowRecordingOverlay -= OnShowRecordingOverlay;
        _handler.HideRecordingOverlay -= OnHideRecordingOverlay;
        _handler.ShowRealtimeOverlay -= OnShowRealtimeOverlay;
        _handler.HideRealtimeOverlay -= OnHideRealtimeOverlay;
        _handler.UpdateRealtimeText -= OnUpdateRealtimeText;
        _handler.ShowTip -= OnShowTip;
        _handler.ShowClarify -= OnShowClarify;
        _handler.ShowResult -= OnShowResult;
        OpenClawManager.Instance.TaskEvent -= OnOpenClawTaskEvent;

        if (_recordingOverlay != null)
            _recordingOverlay.CancelRequested -= OnRecordingCancelRequested;
        if (_realtimeOverlay != null)
            _realtimeOverlay.CancelRequested -= OnRealtimeCancelRequested;

        RunOnUi(() =>
        {
            _recordingOverlay?.Close();
            _realtimeOverlay?.Close();
            _resultOverlay?.Close();
            _openClawTaskOverlay?.Close();
            _clarifyOverlay?.Close();
            _tipOverlay?.Close();

            _recordingOverlay = null;
            _realtimeOverlay = null;
            _resultOverlay = null;
            _openClawTaskOverlay = null;
            _clarifyOverlay = null;
            _tipOverlay = null;
        });
    }
}
