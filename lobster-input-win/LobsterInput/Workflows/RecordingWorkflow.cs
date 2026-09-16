using System.Diagnostics;
using System.Text;
using System.Windows;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Services.TextTargets;
using LobsterInput.Stores;

namespace LobsterInput.Workflows;

public enum RecordingWorkflowState
{
    Idle,
    Starting,
    Recording,
    Stopping,
    Processing
}

public sealed class RecordingWorkflow
{
    private readonly AudioRecorderService _recorder = AudioRecorderService.Instance;
    private readonly RealtimeAudioStreamer _realtimeStreamer = RealtimeAudioStreamer.Instance;
    private readonly HistoryStore _historyStore = HistoryStore.Instance;
    private readonly ApiClient _api = ApiClient.Instance;
    private readonly object _gate = new();
    private readonly HashSet<string> _cancelledRecordIds = new();
    private const int RealtimeAudioBufferLimitBytes = 2_500_000;
    private RecordingSession? _session;
    private RecordingWorkflowState _state = RecordingWorkflowState.Idle;
    private string? _processingRecordId;
    private RealtimeRecordingSession? _realtimeSession;

    public bool SkipSystemPaste { get; set; }

    public event Action? ShowRecordingOverlay;
    public event Action? HideRecordingOverlay;
    public event Action? ShowRealtimeOverlay;
    public event Action? HideRealtimeOverlay;
    public event Action<string>? UpdateRealtimeText;
    public event Action<string>? ShowTip;
    public event Action<string>? ShowClarify;
    public event Action<string, bool>? ShowResult;
    public event Action<Guid, string>? UpdateSearchResult;

    public RecordingWorkflow()
    {
        _recorder.MaxDurationReached += () => _ = StopAndProcessAsync();
        _realtimeStreamer.MaxDurationReached += () => _ = StopRealtimeAndProcessAsync();
    }

    public void Handle(HotKeyCombo combo)
    {
        Debug.WriteLine($"[RecordingWorkflow] Handle {combo}, recorder={_recorder.State}, workflow={_state}");

        if (combo == HotKeyCombo.Screenshot)
        {
            if (_state != RecordingWorkflowState.Idle || _recorder.State != RecordingState.Idle) return;
            _ = HandleScreenshotAsync();
            return;
        }

        var operation = combo switch
        {
            HotKeyCombo.Transcribe => "transcribe",
            HotKeyCombo.Rewrite => "rewrite",
            HotKeyCombo.Agent => "agent",
            _ => "transcribe"
        };

        if (RealtimeRecognitionStore.IsEnabled)
        {
            HandleRealtime(operation);
            return;
        }

        if (_recorder.State == RecordingState.Recording)
        {
            _ = StopAndProcessAsync();
            return;
        }

        if (_state is RecordingWorkflowState.Starting or RecordingWorkflowState.Stopping or RecordingWorkflowState.Processing)
            return;

        if (_recorder.State != RecordingState.Idle || !AuthStore.Instance.IsLoggedIn)
            return;

        var targetWindow = TextTargetService.Instance.GetFocusedWindow();
        var profile = string.Equals(operation, "transcribe", StringComparison.OrdinalIgnoreCase)
            ? RecordingContextProfile.Dictation
            : RecordingContextProfile.SelectionAware;
        var context = RecordingContextCapture.Start(targetWindow, profile);
        _ = StaTaskRunner.Run(() =>
        {
            FillVerifier.Instance.Attach(targetWindow);
            return true;
        });
        lock (_gate)
        {
            _session = new RecordingSession(operation, targetWindow, context);
            _state = RecordingWorkflowState.Starting;
        }

        _ = StartRecordingAsync();
    }

    private void HandleRealtime(string operation)
    {
        if (_realtimeStreamer.State == RealtimeRecordingState.Streaming)
        {
            _ = StopRealtimeAndProcessAsync();
            return;
        }

        if (_state is RecordingWorkflowState.Starting or RecordingWorkflowState.Stopping or RecordingWorkflowState.Processing)
            return;

        if (_realtimeStreamer.State != RealtimeRecordingState.Idle ||
            _recorder.State != RecordingState.Idle ||
            !AuthStore.Instance.IsLoggedIn)
            return;

        var targetWindow = TextTargetService.Instance.GetFocusedWindow();
        var profile = string.Equals(operation, "transcribe", StringComparison.OrdinalIgnoreCase)
            ? RecordingContextProfile.Dictation
            : RecordingContextProfile.SelectionAware;
        var context = RecordingContextCapture.Start(targetWindow, profile);
        _ = StaTaskRunner.Run(() =>
        {
            FillVerifier.Instance.Attach(targetWindow);
            return true;
        });
        lock (_gate)
        {
            _session = new RecordingSession(operation, targetWindow, context);
            _state = RecordingWorkflowState.Starting;
        }

        _ = StartRealtimeRecordingAsync();
    }

    private async Task StartRealtimeRecordingAsync()
    {
        try
        {
            ClearRealtimeSession(closeClient: true);
            _recorder.ReleasePreparedCaptureForRealtimeStart();
            if (!_realtimeStreamer.PrepareStartingVisualState())
            {
                ResetSession();
                return;
            }
            ShowRealtimeOverlay?.Invoke();

            var languageCode = LanguageManager.GetLanguageCode(LanguageManager.Instance.Current);
            var client = new RealtimeAsrWebSocketClient();
            client.PartialReceived += (text, language) => OnRealtimeText(client, text, language);
            client.CompletedReceived += (text, language) => OnRealtimeText(client, text, language);
            client.Finished += final =>
            {
                if (!string.IsNullOrWhiteSpace(final.Text))
                    OnRealtimeText(client, final.Text, final.Language);
                if (IsCurrentRealtimeClient(client) && final.CreditsRemaining.HasValue)
                    AuthStore.Instance.CreditsRemaining = final.CreditsRemaining.Value;
            };
            client.Error += message => DebugTrace.Log("RealtimeASR", message);

            var realtimeSession = new RealtimeRecordingSession(client);
            realtimeSession.ConnectTask = ConnectRealtimeClientAsync(realtimeSession, languageCode);
            _realtimeSession = realtimeSession;

            var success = await _realtimeStreamer.StartAsync(bytes =>
            {
                HandleRealtimeAudioChunk(realtimeSession, bytes);
                return Task.CompletedTask;
            });

            if (!success)
            {
                ClearRealtimeSession(closeClient: true);
                ShowTip?.Invoke(L10n.RecordingStartFailed);
                ResetSession();
                HideRealtimeOverlay?.Invoke();
                return;
            }

            var abandoned = false;
            lock (_gate)
            {
                if (_session == null)
                {
                    _state = RecordingWorkflowState.Idle;
                    abandoned = true;
                }
                else
                {
                    _state = RecordingWorkflowState.Recording;
                    realtimeSession.AcceptingPreview = client.IsReady;
                }
            }

            if (abandoned)
            {
                _realtimeStreamer.Cancel();
                ClearRealtimeSession(closeClient: true);
                return;
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("RecordingWorkflow.RealtimeStart", ex);
            ClearRealtimeSession(closeClient: true);
            _realtimeStreamer.Cancel();
            ResetSession();
            HideRealtimeOverlay?.Invoke();
            ShowTip?.Invoke(ex.ToDisplayMessage());
        }
    }

    private async Task ConnectRealtimeClientAsync(RealtimeRecordingSession realtimeSession, string languageCode)
    {
        try
        {
            var client = realtimeSession.Client;
            await client.ConnectAsync(languageCode);
            lock (_gate)
            {
                if (ReferenceEquals(_realtimeSession, realtimeSession))
                {
                    realtimeSession.WebsocketReadyOnce = true;
                    if (_state == RecordingWorkflowState.Recording)
                        realtimeSession.AcceptingPreview = true;
                }
            }
            FlushBufferedRealtimeAudio(realtimeSession);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("RealtimeASR.Connect", ex);
        }
    }

    private void HandleRealtimeAudioChunk(RealtimeRecordingSession realtimeSession, byte[] bytes)
    {
        if (!IsCurrentRealtimeSession(realtimeSession)) return;
        var client = realtimeSession.Client;
        if (client.IsReady)
        {
            realtimeSession.WebsocketReadyOnce = true;
            FlushBufferedRealtimeAudio(realtimeSession);
            if (!client.EnqueueAudio(bytes))
                BufferRealtimeAudio(realtimeSession, bytes);
            return;
        }
        BufferRealtimeAudio(realtimeSession, bytes);
    }

    private void BufferRealtimeAudio(RealtimeRecordingSession realtimeSession, byte[] bytes)
    {
        lock (realtimeSession.AudioBufferGate)
        {
            while (realtimeSession.PendingAudioBytes + bytes.Length > RealtimeAudioBufferLimitBytes &&
                   realtimeSession.PendingAudio.Count > 0)
            {
                realtimeSession.PendingAudioBytes -= realtimeSession.PendingAudio.Dequeue().Length;
            }
            if (bytes.Length <= RealtimeAudioBufferLimitBytes)
            {
                realtimeSession.PendingAudio.Enqueue(bytes);
                realtimeSession.PendingAudioBytes += bytes.Length;
            }
        }
    }

    private void FlushBufferedRealtimeAudio(RealtimeRecordingSession realtimeSession)
    {
        var client = realtimeSession.Client;
        if (!client.IsReady) return;
        List<byte[]> chunks = new();
        lock (realtimeSession.AudioBufferGate)
        {
            while (realtimeSession.PendingAudio.Count > 0)
                chunks.Add(realtimeSession.PendingAudio.Dequeue());
            realtimeSession.PendingAudioBytes = 0;
        }

        for (var index = 0; index < chunks.Count; index++)
        {
            if (client.EnqueueAudio(chunks[index])) continue;
            BufferRealtimeAudio(realtimeSession, chunks[index]);
            for (var remaining = index + 1; remaining < chunks.Count; remaining++)
                BufferRealtimeAudio(realtimeSession, chunks[remaining]);
            return;
        }
    }

    private bool ShouldAcceptRealtimePreview(RealtimeAsrWebSocketClient client)
    {
        lock (_gate)
        {
            return _realtimeSession?.AcceptingPreview == true &&
                   ReferenceEquals(_realtimeSession.Client, client) &&
                   _state == RecordingWorkflowState.Recording;
        }
    }

    private bool IsCurrentRealtimeClient(RealtimeAsrWebSocketClient client)
    {
        lock (_gate)
        {
            return ReferenceEquals(_realtimeSession?.Client, client);
        }
    }

    private bool IsCurrentRealtimeSession(RealtimeRecordingSession realtimeSession)
    {
        lock (_gate)
        {
            return ReferenceEquals(_realtimeSession, realtimeSession);
        }
    }

    private void OnRealtimeText(RealtimeAsrWebSocketClient client, string text, string language)
    {
        if (!ShouldAcceptRealtimePreview(client)) return;
        var realtimeSession = _realtimeSession;
        if (realtimeSession == null || !ReferenceEquals(realtimeSession.Client, client)) return;
        realtimeSession.Transcript = text ?? "";
        if (!string.IsNullOrWhiteSpace(language))
            realtimeSession.TranscriptLanguage = language;
        UpdateRealtimeText?.Invoke(realtimeSession.Transcript);
    }

    private static string ChooseRealtimeTranscript(string finalText, string liveFallback)
    {
        var final = (finalText ?? "").Trim();
        var fallback = (liveFallback ?? "").Trim();
        if (string.IsNullOrWhiteSpace(fallback)) return final;
        if (string.IsNullOrWhiteSpace(final)) return fallback;
        if (fallback.Length > final.Length &&
            (fallback.StartsWith(final, StringComparison.Ordinal) ||
             fallback.Contains(final, StringComparison.Ordinal)))
        {
            return fallback;
        }
        return final;
    }

    private async Task StartRecordingAsync()
    {
        try
        {
            ShowRecordingOverlay?.Invoke();

            var success = await _recorder.StartRecordingAsync();
            if (!success)
            {
                ShowTip?.Invoke(L10n.RecordingStartFailed);
                ResetSession();
                HideRecordingOverlay?.Invoke();
                return;
            }

            lock (_gate)
            {
                if (_session == null)
                {
                    _recorder.CancelRecording();
                    _state = RecordingWorkflowState.Idle;
                    return;
                }

                _state = RecordingWorkflowState.Recording;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[RecordingWorkflow] StartRecording error: {ex.Message}");
            DebugTrace.LogError("RecordingWorkflow.Start", ex);
            ResetSession();
            HideRecordingOverlay?.Invoke();
        }
    }

    private async Task StopAndProcessAsync()
    {
        var flowStopwatch = Stopwatch.StartNew();
        RecordingSession? session;
        lock (_gate)
        {
            if (_state is RecordingWorkflowState.Stopping or RecordingWorkflowState.Processing)
                return;

            session = _session;
            if (session == null)
                return;

            _state = RecordingWorkflowState.Stopping;
        }

        _recorder.MarkProcessingVisual();

        var stopStopwatch = Stopwatch.StartNew();
        var audioPath = await _recorder.StopRecordingAsync();
        var stopMs = stopStopwatch.ElapsedMilliseconds;
        if (audioPath == null)
        {
            HideRecordingOverlay?.Invoke();
            if (!string.IsNullOrWhiteSpace(_recorder.LastStopIssue))
                ShowTip?.Invoke(_recorder.LastStopIssue);
            ResetSession();
            return;
        }

        var contextStopwatch = Stopwatch.StartNew();
        var snapshot = await session.Context.ResolveSelectionSnapshotAsync();
        var clipboardHistoryTask = session.Context.ResolveClipboardHistoryAsync();
        var clipboardItemsTask = session.Context.ResolveClipboardItemsAsync();
        await Task.WhenAll(clipboardHistoryTask, clipboardItemsTask);
        var clipboardHistory = await clipboardHistoryTask;
        var clipboardItems = await clipboardItemsTask;
        var contextMs = contextStopwatch.ElapsedMilliseconds;
        var selectedText = SanitizeContextText(snapshot?.Text);
        if (snapshot != null && selectedText == null)
            snapshot.Text = "";

        DebugTrace.Log(
            "RecordingContext",
            $"resolved selected={selectedText?.Length ?? 0}, clipboardHistory={clipboardHistory.Count}, clipboardItems={clipboardItems.Count}");

        var persistedPath = _historyStore.RetentionPolicy == RetentionPolicy.Never
            ? audioPath
            : _historyStore.PersistAudio(audioPath);
        if (!string.Equals(persistedPath, audioPath, StringComparison.OrdinalIgnoreCase))
            DeleteAudioQuietly(audioPath);

        DebugTrace.Log("RecordingWorkflow.History", $"persisted audio={persistedPath ?? "nil"}");

        var record = new RecordingHistory
        {
            Operation = session.Operation,
            AudioFilePath = _historyStore.RetentionPolicy == RetentionPolicy.Never ? null : persistedPath,
            SelectedText = selectedText,
            Status = RecordingStatus.Processing,
            ProcessStartedAt = DateTime.UtcNow
        };

        _historyStore.Add(record);
        _processingRecordId = record.Id;

        DebugTrace.Log(
            "RecordingWorkflow.Timing",
            $"pre-api stopMs={stopMs}, contextMs={contextMs}, totalMs={flowStopwatch.ElapsedMilliseconds}");

        lock (_gate)
        {
            _state = RecordingWorkflowState.Processing;
            _session = null;
        }

        await ProcessRecordAsync(
            record.Id,
            session.Operation,
            persistedPath,
            selectedText,
            snapshot,
            clipboardHistory,
            clipboardItems,
            session.TargetWindow,
            deleteAudioAfterProcessing: _historyStore.RetentionPolicy == RetentionPolicy.Never);
    }

    private async Task StopRealtimeAndProcessAsync()
    {
        var flowStopwatch = Stopwatch.StartNew();
        RecordingSession? session;
        lock (_gate)
        {
            if (_state is RecordingWorkflowState.Stopping or RecordingWorkflowState.Processing)
                return;
            session = _session;
            if (session == null)
                return;
            _state = RecordingWorkflowState.Stopping;
        }

        try
        {
            DebugTrace.Log("RecordingWorkflow.Timing", "realtime stop begin");
            var stopStopwatch = Stopwatch.StartNew();
            await _realtimeStreamer.StopForProcessingAsync();
            DebugTrace.Log(
                "RecordingWorkflow.Timing",
                $"realtime audio stopped stopMs={stopStopwatch.ElapsedMilliseconds}, totalMs={flowStopwatch.ElapsedMilliseconds}");
            var realtimeSession = _realtimeSession;
            var clientTranscript = (realtimeSession?.Transcript ?? "").Trim();
            var transcriptLanguage = realtimeSession?.TranscriptLanguage;
            var asrSessionId = "";
            if (realtimeSession != null)
            {
                realtimeSession.AcceptingPreview = false;
                var client = realtimeSession.Client;
                if (realtimeSession.WebsocketReadyOnce || client.IsReady)
                    asrSessionId = client.AsrSessionId;
                try
                {
                    var readyStopwatch = Stopwatch.StartNew();
                    await WaitForRealtimeReadyAsync(realtimeSession, TimeSpan.FromMilliseconds(800));
                    DebugTrace.Log(
                        "RecordingWorkflow.Timing",
                        $"realtime ready wait ready={client.IsReady}, readyMs={readyStopwatch.ElapsedMilliseconds}, totalMs={flowStopwatch.ElapsedMilliseconds}");
                    if (client.IsReady)
                    {
                        realtimeSession.WebsocketReadyOnce = true;
                        asrSessionId = client.AsrSessionId;
                        FlushBufferedRealtimeAudio(realtimeSession);
                        var finalStopwatch = Stopwatch.StartNew();
                        await client.RequestFinishAsync();
                        var final = await client.WaitForFinalAsync(TimeSpan.FromMilliseconds(1800));
                        DebugTrace.Log(
                            "RecordingWorkflow.Timing",
                            $"realtime final wait received={final != null}, finalMs={finalStopwatch.ElapsedMilliseconds}, totalMs={flowStopwatch.ElapsedMilliseconds}, asrSession={client.AsrSessionId}");
                        if (final != null)
                        {
                            clientTranscript = ChooseRealtimeTranscript(final.Text, realtimeSession.Transcript);
                            if (!string.IsNullOrWhiteSpace(final.Language))
                                transcriptLanguage = final.Language;
                            if (!string.IsNullOrWhiteSpace(final.Text))
                                UpdateRealtimeText?.Invoke(final.Text);
                        }
                        else
                        {
                            DebugTrace.Log(
                                "RealtimeASR",
                                $"client final wait timed out; v2 will resolve server final asrSession={client.AsrSessionId}");
                        }
                    }
                    else
                    {
                        DebugTrace.Log("RealtimeASR", "stop continuing with client transcript because websocket was not ready");
                    }
                }
                catch (Exception ex) { DebugTrace.LogError("RealtimeASR.FinishSignal", ex); }
            }

            var contextStopwatch = Stopwatch.StartNew();
            var snapshot = await session.Context.ResolveSelectionSnapshotAsync();
            var clipboardHistoryTask = session.Context.ResolveClipboardHistoryAsync();
            var clipboardItemsTask = session.Context.ResolveClipboardItemsAsync();
            await Task.WhenAll(clipboardHistoryTask, clipboardItemsTask);
            var clipboardHistory = await clipboardHistoryTask;
            var clipboardItems = await clipboardItemsTask;
            var selectedText = SanitizeContextText(snapshot?.Text);
            if (snapshot != null && selectedText == null)
                snapshot.Text = "";
            DebugTrace.Log(
                "RecordingWorkflow.Timing",
                $"realtime context resolved contextMs={contextStopwatch.ElapsedMilliseconds}, totalMs={flowStopwatch.ElapsedMilliseconds}, snapshotSource={snapshot?.Source ?? "nil"}, editable={snapshot?.IsEditable?.ToString() ?? "unknown"}");

            var record = new RecordingHistory
            {
                Operation = session.Operation,
                AudioFilePath = null,
                SelectedText = selectedText,
                Transcript = clientTranscript,
                Status = RecordingStatus.Processing,
                ProcessStartedAt = DateTime.UtcNow
            };

            _historyStore.Add(record);
            _processingRecordId = record.Id;

            lock (_gate)
            {
                _state = RecordingWorkflowState.Processing;
                _session = null;
            }

            DebugTrace.Log(
                "RecordingWorkflow.Timing",
                $"realtime process dispatch totalMs={flowStopwatch.ElapsedMilliseconds}, transcript={clientTranscript.Length}, target=0x{session.TargetWindow.GetValueOrDefault().ToInt64():X}");

            await ProcessRealtimeRecordAsync(
                record.Id,
                session.Operation,
                clientTranscript,
                asrSessionId,
                selectedText,
                snapshot,
                clipboardHistory,
                clipboardItems,
                session.TargetWindow,
                transcriptLanguage);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("RecordingWorkflow.RealtimeStop", ex);
            ClearRealtimeSession(closeClient: true);
            ShowTip?.Invoke(ex.ToDisplayMessage());
            CompleteRealtimeProcessing();
        }
    }

    public void CancelDuringRecording()
    {
        if (_recorder.State != RecordingState.Recording &&
            _recorder.State != RecordingState.Idle)
            return;

        _recorder.CancelRecording();
        ResetSession();
        HideRecordingOverlay?.Invoke();
    }

    public void CancelDuringProcessing()
    {
        if (_recorder.State != RecordingState.Processing) return;

        if (_processingRecordId != null)
        {
            _cancelledRecordIds.Add(_processingRecordId);
            _historyStore.Update(
                _processingRecordId,
                RecordingStatus.Failed,
                error: L10n.ErrorUserCancelled);
        }

        _processingRecordId = null;
        HideRecordingOverlay?.Invoke();
        _recorder.ResetToIdle();
        lock (_gate)
        {
            _state = RecordingWorkflowState.Idle;
            _session = null;
        }
    }

    public void CancelDuringRealtime()
    {
        if (_realtimeStreamer.State is RealtimeRecordingState.Streaming or RealtimeRecordingState.Starting)
        {
            _realtimeStreamer.Cancel();
            ClearRealtimeSession(closeClient: true);
            ResetSession();
            HideRealtimeOverlay?.Invoke();
            return;
        }

        if (_realtimeStreamer.State != RealtimeRecordingState.Processing) return;

        if (_processingRecordId != null)
        {
            _cancelledRecordIds.Add(_processingRecordId);
            _historyStore.Update(
                _processingRecordId,
                RecordingStatus.Failed,
                error: L10n.ErrorUserCancelled);
        }

        _processingRecordId = null;
        ClearRealtimeSession(closeClient: true);
        _realtimeStreamer.ResetToIdle();
        HideRealtimeOverlay?.Invoke();
        lock (_gate)
        {
            _state = RecordingWorkflowState.Idle;
            _session = null;
        }
    }

    public async Task ProcessRecordAsync(
        string id,
        string operation,
        string? audioPath,
        string? selectedText,
        SelectionSnapshot? snapshot = null,
        List<string>? clipboardHistory = null,
        List<ClipboardContextItem>? clipboardItems = null,
        IntPtr? targetWindow = null,
        bool deleteAudioAfterProcessing = false)
    {
        if (audioPath == null || !File.Exists(audioPath))
        {
            _historyStore.Update(id, RecordingStatus.Failed, error: L10n.ErrorInvalidAudio);
            CompleteProcessing();
            return;
        }

        _historyStore.MarkProcessingStarted(id);

        try
        {
            var fastMode = operation == "transcribe" && TranscribeFastModeStore.IsEnabled;
            selectedText = SanitizeContextText(selectedText);
            clipboardHistory = SanitizeTextList(clipboardHistory);
            clipboardItems = SanitizeClipboardItems(clipboardItems);

            AudioProcessResponse response;
            if (operation == "agent")
            {
                var streamedText = new StringBuilder();
                var streamId = Guid.NewGuid();
                response = await _api.ProcessAudioStreamAsync(
                    audioPath,
                    operation,
                    selectedText,
                    clipboardHistory,
                    clipboardItems,
                    OpenClawManager.Instance.StatusString,
                    OpenClawManager.Instance.AgentSessionActiveForRequest,
                    fastMode,
                    new AudioProcessStreamCallbacks
                    {
                        OnSearchStart = () =>
                        {
                            return Task.CompletedTask;
                        },
                        OnSearchDelta = delta =>
                        {
                            streamedText.Append(delta);
                            UpdateSearchResult?.Invoke(streamId, streamedText.ToString());
                            return Task.CompletedTask;
                        }
                    });
            }
            else
            {
                response = await _api.ProcessAudioAsync(
                    audioPath,
                    operation,
                    selectedText,
                    clipboardHistory,
                    clipboardItems,
                    OpenClawManager.Instance.StatusString,
                    OpenClawManager.Instance.AgentSessionActiveForRequest,
                    fastMode);
            }

            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                if (deleteAudioAfterProcessing)
                    DeleteAudioQuietly(audioPath);
                return;
            }

            var resultToStore = response.ActionType switch
            {
                ActionType.Tip => L10n.TipForCode(response.Result),
                ActionType.OpenclawExecute or
                ActionType.OpenclawSlashCommand or
                _ => response.Result
            };

            RecordingResultStore.Instance.Update(response.Transcript, resultToStore, null);

            if (response.CreditsRemaining.HasValue)
                AuthStore.Instance.CreditsRemaining = response.CreditsRemaining.Value;
            _ = RefreshPlanInfoAsync();

            if (response.ConfigUpdate?.MaxDurationSec is { } newMax)
            {
                _recorder.MaxDuration = newMax;
                _realtimeStreamer.MaxDuration = newMax;
            }

            if (!string.IsNullOrEmpty(response.Warning))
                ShowWarning(response.Warning!);

            await HandleActionAndCompleteProcessingAsync(
                response.ActionType,
                response.Result,
                selectedText,
                clipboardItems,
                snapshot,
                targetWindow,
                response.ClarifyQuestion);

            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                if (deleteAudioAfterProcessing)
                    DeleteAudioQuietly(audioPath);
                return;
            }

            _historyStore.Update(
                id,
                RecordingStatus.Success,
                transcript: response.Transcript,
                result: resultToStore,
                actionType: response.ActionType.ToString());
            if (deleteAudioAfterProcessing)
                DeleteAudioQuietly(audioPath);
        }
        catch (ApiException apiEx)
        {
            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                if (deleteAudioAfterProcessing)
                    DeleteAudioQuietly(audioPath);
                return;
            }

            HandleApiException(id, apiEx);
            if (deleteAudioAfterProcessing)
                DeleteAudioQuietly(audioPath);
            CompleteProcessing();
        }
        catch (Exception ex)
        {
            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                if (deleteAudioAfterProcessing)
                    DeleteAudioQuietly(audioPath);
                return;
            }

            var msg = ex.ToDisplayMessage();
            _historyStore.Update(id, RecordingStatus.Failed, error: msg);
            if (deleteAudioAfterProcessing)
                DeleteAudioQuietly(audioPath);
            RecordingResultStore.Instance.Update("", "", msg);
            CompleteProcessing();
        }
    }

    private async Task ProcessRealtimeRecordAsync(
        string id,
        string operation,
        string transcript,
        string asrSessionId,
        string? selectedText,
        SelectionSnapshot? snapshot,
        List<string>? clipboardHistory,
        List<ClipboardContextItem>? clipboardItems,
        IntPtr? targetWindow,
        string? transcriptLanguage)
    {
        _historyStore.MarkProcessingStarted(id);
        var flowStopwatch = Stopwatch.StartNew();

        try
        {
            var fastMode = operation == "transcribe" && TranscribeFastModeStore.IsEnabled;
            selectedText = SanitizeContextText(selectedText);
            clipboardHistory = SanitizeTextList(clipboardHistory);
            clipboardItems = SanitizeClipboardItems(clipboardItems);

            AudioProcessResponse response;
            var apiStopwatch = Stopwatch.StartNew();
            DebugTrace.Log(
                "RecordingWorkflow.Timing",
                $"realtime api begin operation={operation}, transcript={transcript.Length}, snapshotSource={snapshot?.Source ?? "nil"}, editable={snapshot?.IsEditable?.ToString() ?? "unknown"}, asrSession={asrSessionId}");
            if (operation == "agent")
            {
                var streamedText = new StringBuilder();
                var streamId = Guid.NewGuid();
                response = await _api.ProcessRealtimeTextStreamAsync(
                    transcript,
                    transcript,
                    asrSessionId,
                    operation,
                    selectedText,
                    clipboardHistory,
                    clipboardItems,
                    OpenClawManager.Instance.StatusString,
                    OpenClawManager.Instance.AgentSessionActiveForRequest,
                    fastMode,
                    transcriptLanguage,
                    new AudioProcessStreamCallbacks
                    {
                        OnSearchStart = () =>
                        {
                            return Task.CompletedTask;
                        },
                        OnSearchDelta = delta =>
                        {
                            streamedText.Append(delta);
                            UpdateSearchResult?.Invoke(streamId, streamedText.ToString());
                            return Task.CompletedTask;
                        }
                    });
            }
            else
            {
                response = await _api.ProcessRealtimeTextAsync(
                    transcript,
                    transcript,
                    asrSessionId,
                    operation,
                    selectedText,
                    clipboardHistory,
                    clipboardItems,
                    OpenClawManager.Instance.StatusString,
                    OpenClawManager.Instance.AgentSessionActiveForRequest,
                    fastMode,
                    transcriptLanguage);
            }
            DebugTrace.Log(
                "RecordingWorkflow.Timing",
                $"realtime api end apiMs={apiStopwatch.ElapsedMilliseconds}, totalMs={flowStopwatch.ElapsedMilliseconds}, action={response.ActionType}, result={response.Result.Length}, asrSource={response.AsrResolutionSource ?? ""}");

            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                return;
            }

            var resultToStore = response.ActionType switch
            {
                ActionType.Tip => L10n.TipForCode(response.Result),
                ActionType.OpenclawExecute or
                ActionType.OpenclawSlashCommand or
                _ => response.Result
            };

            RecordingResultStore.Instance.Update(response.Transcript, resultToStore, null);

            if (response.CreditsRemaining.HasValue)
                AuthStore.Instance.CreditsRemaining = response.CreditsRemaining.Value;
            _ = RefreshPlanInfoAsync();

            if (response.ConfigUpdate?.MaxDurationSec is { } newMax)
            {
                _recorder.MaxDuration = newMax;
                _realtimeStreamer.MaxDuration = newMax;
            }

            if (!string.IsNullOrEmpty(response.Warning))
                ShowWarning(response.Warning!);
            if (!string.IsNullOrWhiteSpace(response.AsrResolutionSource))
                DebugTrace.Log("RealtimeASR", $"process success asrSource={response.AsrResolutionSource}");

            var actionStopwatch = Stopwatch.StartNew();
            await HandleActionAndCompleteRealtimeProcessingAsync(
                response.ActionType,
                response.Result,
                selectedText,
                clipboardItems,
                snapshot,
                targetWindow,
                response.ClarifyQuestion);
            DebugTrace.Log(
                "RecordingWorkflow.Timing",
                $"realtime action end actionMs={actionStopwatch.ElapsedMilliseconds}, totalMs={flowStopwatch.ElapsedMilliseconds}, action={response.ActionType}");

            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                return;
            }

            _historyStore.Update(
                id,
                RecordingStatus.Success,
                transcript: response.Transcript,
                result: resultToStore,
                actionType: response.ActionType.ToString());
        }
        catch (ApiException apiEx)
        {
            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                return;
            }

            HandleApiException(id, apiEx);
            CompleteRealtimeProcessing();
        }
        catch (Exception ex)
        {
            if (_cancelledRecordIds.Remove(id))
            {
                _processingRecordId = null;
                return;
            }

            var msg = ex.ToDisplayMessage();
            _historyStore.Update(id, RecordingStatus.Failed, error: msg);
            RecordingResultStore.Instance.Update("", "", msg);
            CompleteRealtimeProcessing();
        }
        finally
        {
            ClearRealtimeSession(closeClient: true);
        }
    }

    private async Task HandleActionAndCompleteProcessingAsync(
        ActionType actionType,
        string result,
        string? selectedText,
        List<ClipboardContextItem>? clipboardItems,
        SelectionSnapshot? snapshot,
        IntPtr? targetWindow,
        string? clarifyQuestion)
    {
        var stopwatch = Stopwatch.StartNew();
        try
        {
            await HandleActionAsync(
                actionType,
                result,
                selectedText,
                clipboardItems,
                snapshot,
                targetWindow,
                clarifyQuestion);
        }
        finally
        {
            CompleteProcessing();

            DebugTrace.Log(
                "RecordingWorkflow.Action",
                $"action completed type={actionType}, elapsedMs={stopwatch.ElapsedMilliseconds}");
        }
    }

    private async Task HandleActionAndCompleteRealtimeProcessingAsync(
        ActionType actionType,
        string result,
        string? selectedText,
        List<ClipboardContextItem>? clipboardItems,
        SelectionSnapshot? snapshot,
        IntPtr? targetWindow,
        string? clarifyQuestion)
    {
        try
        {
            await HandleActionAsync(
                actionType,
                result,
                selectedText,
                clipboardItems,
                snapshot,
                targetWindow,
                clarifyQuestion);
        }
        finally
        {
            CompleteRealtimeProcessing();
        }
    }

    private async Task HandleScreenshotAsync()
    {
        var result = await ScreenshotService.Instance.CaptureToClipboardAsync();
        var message = result switch
        {
            ScreenshotCaptureResult.Copied => L10n.ScreenshotCopied,
            ScreenshotCaptureResult.Cancelled => L10n.ScreenshotCancelled,
            _ => L10n.ScreenshotFailed
        };
        ShowTip?.Invoke(message);
    }

    private async Task RefreshPlanInfoAsync()
    {
        try
        {
            var info = await _api.FetchUserPlanInfoAsync();
            AuthStore.Instance.UpdatePlanInfo(info);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[RecordingWorkflow] Refresh plan failed: {ex.Message}");
        }
    }

    private static void DeleteAudioQuietly(string? audioPath)
    {
        if (string.IsNullOrWhiteSpace(audioPath)) return;

        try
        {
            if (File.Exists(audioPath))
                File.Delete(audioPath);
        }
        catch
        {
            // Best-effort cleanup only.
        }
    }

    private void HandleApiException(string id, ApiException apiEx)
    {
        var failure = ApplyApiExceptionEffects(apiEx);
        _historyStore.Update(id, RecordingStatus.Failed, error: failure.Error, retryable: failure.Retryable);
    }

    private (string Error, bool Retryable) ApplyApiExceptionEffects(ApiException apiEx)
    {
        if (apiEx.RequiresLogout)
        {
            RecordingResultStore.Instance.Clear();
            AuthStore.Instance.Logout();
            return (L10n.ErrorUnauthorized, false);
        }

        if (apiEx.IsCreditsExhausted)
        {
            _ = RefreshPlanInfoAsync();
            var msg = L10n.ErrorCreditsExhausted;
            RecordingResultStore.Instance.Update("", "", msg);
            ShowTip?.Invoke(msg);
            return (msg, false);
        }

        var error = apiEx.ToDisplayMessage();
        RecordingResultStore.Instance.Update("", "", error);

        if (apiEx.ConfigUpdate?.MaxDurationSec is { } cfgMax)
        {
            _recorder.MaxDuration = cfgMax;
            _realtimeStreamer.MaxDuration = cfgMax;
        }

        if (apiEx.IsNonRetryable)
            ShowWarning(error);

        return (error, !apiEx.IsNonRetryable);
    }

    private async Task HandleActionAsync(
        ActionType actionType,
        string text,
        string? selectedText,
        List<ClipboardContextItem>? clipboardItems,
        SelectionSnapshot? snapshot,
        IntPtr? targetWindow,
        string? clarifyQuestion)
    {
        DebugTrace.Log(
            "RecordingWorkflow.Action",
            $"type={actionType}, selected={selectedText?.Length ?? 0}, editable={snapshot?.IsEditable?.ToString() ?? "unknown"}, target=0x{targetWindow.GetValueOrDefault().ToInt64():X}");

        switch (actionType)
        {
            case ActionType.Paste:
                await HandlePasteActionAsync(text, snapshot, targetWindow);
                break;

            case ActionType.Clarify:
                ShowClarify?.Invoke(clarifyQuestion ?? L10n.OverlayClarifyFallback);
                break;

            case ActionType.ShowMarkdown:
                ShowResult?.Invoke(text, true);
                break;

            case ActionType.Tip:
                OpenClawManager.Instance.HandleSessionTipCode(text);
                ShowTip?.Invoke(L10n.TipForCode(text));
                break;

            case ActionType.OpenclawExecute:
            case ActionType.OpenclawInteractive:
                OpenClawManager.Instance.SendToOpenClaw(
                    text,
                    selectedText,
                    clipboardItems);
                break;

            case ActionType.OpenclawSlashCommand:
            case ActionType.OpenclawCliCommand:
                OpenClawManager.Instance.SendCommandToOpenClaw(text);
                break;
        }
    }

    private async Task HandlePasteActionAsync(
        string text,
        SelectionSnapshot? snapshot,
        IntPtr? targetWindow)
    {
        if (string.IsNullOrEmpty(text)) return;

        var stopwatch = Stopwatch.StartNew();
        DebugTrace.Log(
            "RecordingWorkflow.Paste",
            $"begin text={text.Length}, contextEditable={snapshot?.IsEditable?.ToString() ?? "unknown"}, contextSource={snapshot?.Source ?? "nil"}, target=0x{targetWindow.GetValueOrDefault().ToInt64():X}");
        if (!ShouldAttemptSystemPaste(snapshot, targetWindow))
        {
            await HideInputOverlaysAsync();
            DebugTrace.Log(
                "RecordingWorkflow.Paste",
                $"direct result overlay reason=no-fill-target, contextEditable={snapshot?.IsEditable?.ToString() ?? "unknown"}, contextSource={snapshot?.Source ?? "nil"}, elapsedMs={stopwatch.ElapsedMilliseconds}");
            ShowResult?.Invoke(text, false);
            DebugTrace.Log(
                "RecordingWorkflow.Paste",
                $"show result event dispatched reason=no-fill-target, elapsedMs={stopwatch.ElapsedMilliseconds}");
            return;
        }

        await PrepareTargetForSystemPasteAsync();
        var committed = await AttemptFillResultAsync(text, targetWindow, snapshot);
        if (!committed)
        {
            DebugTrace.Log(
                "RecordingWorkflow.Paste",
                $"fallback result overlay reason=commit-failed, elapsedMs={stopwatch.ElapsedMilliseconds}");
            ShowResult?.Invoke(text, false);
            DebugTrace.Log(
                "RecordingWorkflow.Paste",
                $"show result event dispatched reason=commit-failed, elapsedMs={stopwatch.ElapsedMilliseconds}");
        }
    }

    private async Task PrepareTargetForSystemPasteAsync()
    {
        var stopwatch = Stopwatch.StartNew();
        await HideInputOverlaysAsync();
        await Task.Delay(150).ConfigureAwait(false);
        DebugTrace.Log("RecordingWorkflow.Paste", $"target prepared elapsedMs={stopwatch.ElapsedMilliseconds}");
    }

    private async Task HideInputOverlaysAsync()
    {
        try
        {
            if (Application.Current?.Dispatcher != null)
            {
                await Application.Current.Dispatcher.InvokeAsync(() =>
                {
                    HideRecordingOverlay?.Invoke();
                    HideRealtimeOverlay?.Invoke();
                });
            }
            else
            {
                HideRecordingOverlay?.Invoke();
                HideRealtimeOverlay?.Invoke();
            }
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("RecordingWorkflow.PreparePasteTarget", ex);
        }
    }

    private async Task<bool> AttemptFillResultAsync(string text, IntPtr? targetWindow, SelectionSnapshot? contextSnapshot)
    {
        if (SkipSystemPaste) return false;

        var result = await TextTargetService.Instance.CommitTextAsync(
            text,
            targetWindow,
            contextSnapshot,
            SkipSystemPaste);

        DebugTrace.Log(
            "RecordingWorkflow.Paste",
            $"status={result.Status}, reason={result.Reason ?? ""}, contextEditable={contextSnapshot?.IsEditable?.ToString() ?? "unknown"}, contextSource={contextSnapshot?.Source ?? "nil"}");

        return result.Committed;
    }

    private static bool ShouldAttemptSystemPaste(SelectionSnapshot? snapshot, IntPtr? targetWindow)
    {
        // 判定权反转（对齐 Mac TextFillEngine）：录音开始时的上下文快照缺失或不确定
        // （Electron 冷树的常态）不再直接浮窗，一律先交给盲填 + 被动确认流程；
        // 只有可靠的"不可编辑"结论才走浮窗快路径。
        _ = targetWindow;
        return snapshot?.IsEditable != false;
    }

    private void CompleteProcessing()
    {
        _processingRecordId = null;
        HideRecordingOverlay?.Invoke();
        FillVerifier.Instance.Detach();
        _recorder.ResetToIdle();
        lock (_gate)
        {
            _state = RecordingWorkflowState.Idle;
            _session = null;
        }
    }

    private void CompleteRealtimeProcessing()
    {
        var stopwatch = Stopwatch.StartNew();
        _processingRecordId = null;
        DebugTrace.Log("RecordingWorkflow.Timing", "complete realtime begin");
        HideRealtimeOverlay?.Invoke();
        DebugTrace.Log("RecordingWorkflow.Timing", $"complete realtime hide overlay elapsedMs={stopwatch.ElapsedMilliseconds}");
        FillVerifier.Instance.DetachInBackground();
        DebugTrace.Log("RecordingWorkflow.Timing", $"complete realtime verifier detach queued elapsedMs={stopwatch.ElapsedMilliseconds}");
        _realtimeStreamer.ResetToIdle();
        DebugTrace.Log("RecordingWorkflow.Timing", $"complete realtime streamer reset elapsedMs={stopwatch.ElapsedMilliseconds}");
        ClearRealtimeSession(closeClient: true);
        DebugTrace.Log("RecordingWorkflow.Timing", $"complete realtime session cleared elapsedMs={stopwatch.ElapsedMilliseconds}");
        lock (_gate)
        {
            _state = RecordingWorkflowState.Idle;
            _session = null;
        }
        DebugTrace.Log("RecordingWorkflow.Timing", $"complete realtime end elapsedMs={stopwatch.ElapsedMilliseconds}");
    }

    private async Task WaitForRealtimeReadyAsync(RealtimeRecordingSession realtimeSession, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (!IsCurrentRealtimeSession(realtimeSession)) return;
            if (realtimeSession.WebsocketReadyOnce || realtimeSession.Client.IsReady) return;
            await Task.Delay(40);
        }
    }

    private void ClearRealtimeSession(bool closeClient)
    {
        RealtimeRecordingSession? realtimeSession;
        lock (_gate)
        {
            realtimeSession = _realtimeSession;
            if (realtimeSession != null)
                realtimeSession.AcceptingPreview = false;
            _realtimeSession = null;
        }

        if (realtimeSession == null) return;
        realtimeSession.ClearAudioBuffer();
        if (closeClient)
            realtimeSession.Client.Close();
    }

    private void ResetSession()
    {
        lock (_gate)
        {
            _session = null;
            _state = RecordingWorkflowState.Idle;
        }
        ClearRealtimeSession(closeClient: true);
    }

    private static void ShowWarning(string message)
    {
        Application.Current?.Dispatcher.Invoke(() =>
        {
            MessageBox.Show(
                message,
                L10n.AppNameFull,
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        });
    }

    private static string? SanitizeContextText(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return null;

        return ClipboardSentinel.IsInternal(text) ? null : text;
    }

    private static List<string> SanitizeTextList(List<string>? items)
    {
        if (items is not { Count: > 0 })
            return new List<string>();

        return items
            .Where(item => !string.IsNullOrWhiteSpace(item) && !ClipboardSentinel.IsInternal(item))
            .ToList();
    }

    private static List<ClipboardContextItem> SanitizeClipboardItems(List<ClipboardContextItem>? items)
    {
        if (items is not { Count: > 0 })
            return new List<ClipboardContextItem>();

        return items
            .Where(item => item.Kind != "text" ||
                (!string.IsNullOrWhiteSpace(item.Text) && !ClipboardSentinel.IsInternal(item.Text)))
            .ToList();
    }
}

internal sealed record RecordingSession(
    string Operation,
    IntPtr? TargetWindow,
    RecordingContextCapture Context);

internal sealed class RealtimeRecordingSession
{
    public RealtimeRecordingSession(RealtimeAsrWebSocketClient client)
    {
        Client = client;
    }

    public RealtimeAsrWebSocketClient Client { get; }
    public Task? ConnectTask { get; set; }
    public bool AcceptingPreview { get; set; }
    public bool WebsocketReadyOnce { get; set; }
    public string Transcript { get; set; } = "";
    public string? TranscriptLanguage { get; set; }
    public object AudioBufferGate { get; } = new();
    public Queue<byte[]> PendingAudio { get; } = new();
    public int PendingAudioBytes { get; set; }

    public void ClearAudioBuffer()
    {
        lock (AudioBufferGate)
        {
            PendingAudio.Clear();
            PendingAudioBytes = 0;
        }
    }
}
