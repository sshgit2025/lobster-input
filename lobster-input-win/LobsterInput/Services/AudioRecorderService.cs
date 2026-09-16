using System.Diagnostics;
using System.IO;
using System.Timers;
using CommunityToolkit.Mvvm.ComponentModel;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using LobsterInput.Services.Audio;

namespace LobsterInput.Services;

public enum RecordingState
{
    Idle,
    Recording,
    Processing
}

public sealed record InputDeviceInfo(string Id, string Name, bool IsSelected);

public sealed partial class AudioRecorderService : ObservableObject, IDisposable
{
    [ObservableProperty]
    private RecordingState _state = RecordingState.Idle;

    [ObservableProperty]
    private float _audioLevel;

    [ObservableProperty]
    private int? _countdown;

    [ObservableProperty]
    private int _elapsedSeconds;

    public string? LastStopIssue { get; private set; }

    public double MaxDuration { get; set; } = 60;
    public const int CountdownWarningSeconds = 10;

    private SafeWasapiCapture? _capture;
    private WaveFileWriter? _writer;
    private WaveFormat? _captureFormat;
    private string? _captureDeviceId;
    private string? _tempFilePath;
    private string? _outputFilePath;
    private System.Timers.Timer? _durationTimer;
    private readonly Stopwatch _recordingStopwatch = new();
    private volatile bool _captureDeviceInvalidated;
    private bool _disposed;
    private bool _cancelled;
    private readonly object _writeLock = new();
    private readonly object _captureLock = new();
    private readonly object _durationTickLock = new();
    private double _recordingSquareSum;
    private long _recordingSampleCount;
    private float _recordingPeak;
    private double _activeMaxDuration;

    private readonly AudioDeviceService _deviceService = AudioDeviceService.Instance;
    private readonly List<byte> _captureBuffer = new();
    private int _maxDurationSignalSent;

    public static AudioRecorderService Instance { get; } = new();

    public event Action? MaxDurationReached;

    private AudioRecorderService()
    {
    }

    public IReadOnlyList<InputDeviceInfo> InputDevices() => _deviceService.InputDevices();

    public void SelectInputDevice(string? deviceId)
    {
        _deviceService.SelectInputDevice(deviceId);
        DebugTrace.Log("AudioRecorder", $"Input device selected id={deviceId ?? "default"}, realtime={RealtimeRecognitionStore.IsEnabled}");
        if (RealtimeRecognitionStore.IsEnabled)
        {
            ReleasePreparedCaptureForRealtimeStart();
            return;
        }
        _ = PrepareAsync(forceRebuild: true);
    }

    public void ReleasePreparedCaptureForRealtimeStart()
    {
        if (_disposed) return;

        lock (_captureLock)
        {
            if (State != RecordingState.Idle) return;
            DebugTrace.Log("AudioRecorder", "Release prepared capture before realtime start");
            DisposeCaptureLocked();
        }
    }

    public Task PrepareAsync(bool forceRebuild = false)
    {
        return Task.Run(() =>
        {
            if (_disposed) return;

            lock (_captureLock)
            {
                if (State != RecordingState.Idle) return;
                if (forceRebuild)
                    DisposeCaptureLocked();

                if (_capture != null) return;

                try
                {
                    if (!EnsureCaptureLocked())
                    {
                        Debug.WriteLine("[AudioRecorder] Prepare skipped: no capture device");
                        return;
                    }

                    Debug.WriteLine($"[AudioRecorder] Prepared capture, format={_captureFormat}");
                }
                catch (Exception ex)
                {
                    Debug.WriteLine($"[AudioRecorder] Prepare failed: {ex.Message}");
                    DebugTrace.LogError("AudioRecorder.Prepare", ex);
                    DisposeCaptureLocked();
                }
            }
        });
    }

    public Task<bool> StartRecordingAsync()
    {
        return Task.Run(StartRecordingCore);
    }

    private bool StartRecordingCore()
    {
        if (State != RecordingState.Idle)
            return false;

        _cancelled = false;

        try
        {
            lock (_captureLock)
            {
                if (_captureDeviceInvalidated)
                    DisposeCaptureLocked();
                if (!EnsureCaptureLocked())
                {
                    Debug.WriteLine("[AudioRecorder] No capture device available");
                    return false;
                }
            }

            var outputDir = Path.Combine(AppPaths.LocalAppDataDir, "Recordings");
            Directory.CreateDirectory(outputDir);

            var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss_fff");
            _tempFilePath = Path.Combine(outputDir, $"raw_{stamp}.wav");
            _outputFilePath = Path.Combine(outputDir, $"rec_{stamp}.wav");

            var captureFormat = _captureFormat ?? throw new InvalidOperationException("Capture format is not prepared.");
            _writer = new WaveFileWriter(_tempFilePath, captureFormat);
            _captureBuffer.Clear();
            ResetLevelStats();
            LastStopIssue = null;
            _maxDurationSignalSent = 0;

            try
            {
                (_capture ?? throw new InvalidOperationException("Capture is not prepared.")).StartRecording();
            }
            catch (Exception firstEx)
            {
                Debug.WriteLine($"[AudioRecorder] Start prepared capture failed, rebuilding: {firstEx.Message}");
                DebugTrace.LogError("AudioRecorder.StartPrepared", firstEx);
                var failedDeviceId = _captureDeviceId;
                lock (_writeLock)
                {
                    _writer?.Dispose();
                    _writer = null;
                }
                lock (_captureLock)
                {
                    DisposeCaptureLocked();
                    var skipFailedDevice = AudioDeviceService.IsRecoverableCaptureException(firstEx)
                        ? failedDeviceId
                        : null;
                    EnsureCaptureLocked(skipFailedDevice);
                    if (_capture == null)
                        throw;
                }
                lock (_writeLock)
                {
                    var rebuiltFormat = _captureFormat ?? throw new InvalidOperationException("Capture format is not prepared after rebuild.");
                    _writer = new WaveFileWriter(_tempFilePath, rebuiltFormat);
                }
                (_capture ?? throw new InvalidOperationException("Capture is not prepared after rebuild.")).StartRecording();
            }

            SetState(RecordingState.Recording);
            StartDurationTimer();
            Debug.WriteLine($"[AudioRecorder] Recording started, device={_captureDeviceId}, format={_captureFormat}");
            DebugTrace.Log("AudioRecorder", $"Recording started device={_captureDeviceId}, format={_captureFormat}, maxDuration={_activeMaxDuration:0.###}");
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AudioRecorder] Start failed: {ex.Message}");
            lock (_captureLock)
                DisposeCaptureLocked();
            return false;
        }
    }

    public Task<string?> StopRecordingAsync()
    {
        return Task.Run(StopRecordingCore);
    }

    public void MarkProcessingVisual()
    {
        if (State == RecordingState.Recording)
            SetState(RecordingState.Processing);
    }

    private string? StopRecordingCore()
    {
        var stopStopwatch = Stopwatch.StartNew();
        if (State != RecordingState.Recording && _capture == null)
            return null;

        SetState(RecordingState.Processing);
        StopDurationTimer();

        var captureStopwatch = Stopwatch.StartNew();
        try
        {
            _capture?.StopRecording();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AudioRecorder] Stop capture error: {ex.Message}");
            if (IsRecoverableWasapiException(ex))
                _captureDeviceInvalidated = true;
        }
        var captureStopMs = captureStopwatch.ElapsedMilliseconds;

        try
        {
            var writerStopwatch = Stopwatch.StartNew();
            lock (_writeLock)
            {
                _writer?.Dispose();
                _writer = null;
            }
            var writerDisposeMs = writerStopwatch.ElapsedMilliseconds;

            if (_cancelled || _tempFilePath == null || !File.Exists(_tempFilePath))
            {
                CleanupFiles();
                SetState(RecordingState.Idle);
                _ = PrepareAsync(forceRebuild: _captureDeviceInvalidated);
                return null;
            }

            var postProcessStopwatch = Stopwatch.StartNew();
            AudioPostProcessor.ResampleToSpeechWav(_tempFilePath, _outputFilePath!);
            var postProcessMs = postProcessStopwatch.ElapsedMilliseconds;

            if (File.Exists(_tempFilePath))
                File.Delete(_tempFilePath);

            var peak = _recordingPeak;
            var rms = _recordingSampleCount > 0
                ? Math.Sqrt(_recordingSquareSum / _recordingSampleCount)
                : 0;
            DebugTrace.Log("AudioRecorder", $"Recording stopped peak={peak:0.0000}, rms={rms:0.0000}, samples={_recordingSampleCount}");
            DebugTrace.Log(
                "AudioRecorder.Timing",
                $"stopCaptureMs={captureStopMs}, writerDisposeMs={writerDisposeMs}, postProcessMs={postProcessMs}, totalMs={stopStopwatch.ElapsedMilliseconds}");

            if (IsEffectivelySilent(peak, rms))
            {
                LastStopIssue = "没有检测到麦克风声音，请检查当前选择的麦克风输入后再试。";
                DebugTrace.Log("AudioRecorder", LastStopIssue);
                CleanupFiles();
                SetState(RecordingState.Idle);
                _ = PrepareAsync(forceRebuild: _captureDeviceInvalidated);
                return null;
            }

            Debug.WriteLine($"[AudioRecorder] Output ready: {_outputFilePath}");
            if (_captureDeviceInvalidated)
                _ = PrepareAsync(forceRebuild: true);
            return _outputFilePath;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AudioRecorder] Stop processing error: {ex.Message}");
            lock (_captureLock)
                DisposeCaptureLocked();
            CleanupFiles();
            SetState(RecordingState.Idle);
            _ = PrepareAsync();
            return null;
        }
    }

    public void CancelRecording()
    {
        _cancelled = true;
        StopDurationTimer();

        try
        {
            _capture?.StopRecording();
        }
        catch (Exception ex)
        {
            if (IsRecoverableWasapiException(ex))
                _captureDeviceInvalidated = true;
        }

        lock (_writeLock)
        {
            _writer?.Dispose();
            _writer = null;
        }

        CleanupFiles();

        SetState(RecordingState.Idle);
        SetCountdown(null);
        SetElapsedSeconds(0);
        SetAudioLevel(0);
        _ = PrepareAsync(forceRebuild: _captureDeviceInvalidated);
        Debug.WriteLine("[AudioRecorder] Recording cancelled");
    }

    public void ResetToIdle()
    {
        if (State == RecordingState.Recording)
            CancelRecording();
        else
        {
            SetState(RecordingState.Idle);
            SetCountdown(null);
            SetElapsedSeconds(0);
            SetAudioLevel(0);
            _ = PrepareAsync();
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (_cancelled || e.BytesRecorded == 0) return;

        lock (_writeLock)
        {
            if (_writer == null) return;
            _writer?.Write(e.Buffer, 0, e.BytesRecorded);
        }

        UpdateAudioLevel(e.Buffer, e.BytesRecorded);
        UpdateLevelStats(e.Buffer, e.BytesRecorded);
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception == null) return;

        Debug.WriteLine($"[AudioRecorder] Recording error: {e.Exception.Message}");
        DebugTrace.LogError("AudioRecorder.WasapiCapture", e.Exception);
        if (IsRecoverableWasapiException(e.Exception))
        {
            _captureDeviceInvalidated = true;
            DebugTrace.Log("AudioRecorder", "WASAPI capture device invalidated; capture will be rebuilt");
        }
    }

    private static bool IsRecoverableWasapiException(Exception ex)
    {
        return AudioDeviceService.IsRecoverableCaptureException(ex);
    }

    private void ResetCaptureIssueFlags()
    {
        _captureDeviceInvalidated = false;
    }

    private void UpdateAudioLevel(byte[] buffer, int bytesRecorded)
    {
        if (_captureFormat == null) return;

        float maxVal = 0;
        if (_captureFormat.BitsPerSample == 32 && _captureFormat.Encoding == WaveFormatEncoding.IeeeFloat)
        {
            for (int i = 0; i + 3 < bytesRecorded; i += 4)
            {
                var sample = Math.Abs(BitConverter.ToSingle(buffer, i));
                if (sample > maxVal) maxVal = sample;
            }
        }
        else if (_captureFormat.BitsPerSample == 16)
        {
            for (int i = 0; i + 1 < bytesRecorded; i += 2)
            {
                var sample = Math.Abs(BitConverter.ToInt16(buffer, i) / 32768f);
                if (sample > maxVal) maxVal = sample;
            }
        }

        SetAudioLevel(maxVal);
    }

    private void UpdateLevelStats(byte[] buffer, int bytesRecorded)
    {
        if (_captureFormat == null) return;

        if (_captureFormat.BitsPerSample == 32 && _captureFormat.Encoding == WaveFormatEncoding.IeeeFloat)
        {
            for (int i = 0; i + 3 < bytesRecorded; i += 4)
            {
                var sample = Math.Clamp(BitConverter.ToSingle(buffer, i), -1f, 1f);
                var abs = Math.Abs(sample);
                if (abs > _recordingPeak) _recordingPeak = abs;
                _recordingSquareSum += sample * sample;
                _recordingSampleCount++;
            }
        }
        else if (_captureFormat.BitsPerSample == 16)
        {
            for (int i = 0; i + 1 < bytesRecorded; i += 2)
            {
                var sample = BitConverter.ToInt16(buffer, i) / 32768f;
                var abs = Math.Abs(sample);
                if (abs > _recordingPeak) _recordingPeak = abs;
                _recordingSquareSum += sample * sample;
                _recordingSampleCount++;
            }
        }
    }

    private void ResetLevelStats()
    {
        _recordingSquareSum = 0;
        _recordingSampleCount = 0;
        _recordingPeak = 0;
    }

    private static bool IsEffectivelySilent(float peak, double rms)
    {
        return peak < 0.001f && rms < 0.0002;
    }

    #region Duration Timer

    private void StartDurationTimer()
    {
        StopDurationTimer();
        _activeMaxDuration = Math.Max(1, MaxDuration);
        _recordingStopwatch.Restart();
        SetClock(0, null);
        _durationTimer = new System.Timers.Timer(200);
        _durationTimer.Elapsed += OnDurationTick;
        _durationTimer.AutoReset = true;
        _durationTimer.Start();
    }

    private void StopDurationTimer()
    {
        _durationTimer?.Stop();
        _durationTimer?.Dispose();
        _durationTimer = null;
        _recordingStopwatch.Stop();
    }

    private void OnDurationTick(object? sender, ElapsedEventArgs e)
    {
        if (!Monitor.TryEnter(_durationTickLock))
            return;

        try
        {
            var elapsed = _recordingStopwatch.Elapsed.TotalSeconds;
            var maxDuration = _activeMaxDuration > 0 ? _activeMaxDuration : Math.Max(1, MaxDuration);
            var maxDisplaySeconds = Math.Max(1, (int)Math.Round(maxDuration, MidpointRounding.AwayFromZero));
            var elapsedSeconds = Math.Clamp((int)Math.Floor(elapsed), 0, maxDisplaySeconds);
            var remaining = maxDuration - elapsed;
            var displayRemaining = Math.Max(0, maxDisplaySeconds - elapsedSeconds);

            if (remaining <= 0)
            {
                if (Interlocked.Exchange(ref _maxDurationSignalSent, 1) == 0)
                {
                    SetClock(maxDisplaySeconds, 0);
                    StopDurationTimer();
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => MaxDurationReached?.Invoke());
                }
                return;
            }

            var countdown = displayRemaining <= CountdownWarningSeconds
                ? Math.Max(1, displayRemaining)
                : (int?)null;

            SetClock(elapsedSeconds, countdown);
        }
        finally
        {
            Monitor.Exit(_durationTickLock);
        }
    }

    #endregion

    private SafeWasapiCapture CreateCapture(MMDevice device)
    {
        var capture = new SafeWasapiCapture(device);
        capture.DataAvailable += OnDataAvailable;
        capture.RecordingStopped += OnRecordingStopped;
        return capture;
    }

    private bool EnsureCaptureLocked(string? skipDeviceId = null)
    {
        var candidates = _deviceService.ResolveCaptureDeviceCandidates();
        if (candidates.Count == 0) return false;
        var primaryCandidate = candidates.FirstOrDefault(candidate =>
            !string.Equals(candidate.Id, skipDeviceId, StringComparison.OrdinalIgnoreCase));

        if (_capture != null &&
            !_captureDeviceInvalidated &&
            primaryCandidate != null &&
            string.Equals(_captureDeviceId, primaryCandidate.Id, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (_capture != null)
            DisposeCaptureLocked();

        foreach (var candidate in candidates)
        {
            if (string.Equals(candidate.Id, skipDeviceId, StringComparison.OrdinalIgnoreCase))
                continue;

            try
            {
                using var device = _deviceService.OpenCaptureDevice(candidate);
                _capture = CreateCapture(device);
                _captureFormat = _capture.WaveFormat;
                _captureDeviceId = candidate.Id;
                DebugTrace.Log(
                    "AudioRecorder",
                    $"Capture prepared device={candidate.Id}, name={candidate.Name}, order={candidate.Order}, auto={candidate.IsAutomaticSelection}, reason={candidate.Reason}, format={_captureFormat}");
                return true;
            }
            catch (Exception ex)
            {
                DebugTrace.LogError("AudioRecorder.PrepareCandidate", ex);
                if (!candidate.IsAutomaticSelection &&
                    !AudioDeviceService.IsRecoverableCaptureException(ex))
                {
                    break;
                }
            }
        }

        return false;
    }

    private void DisposeCaptureLocked()
    {
        if (_capture != null)
        {
            _capture.DataAvailable -= OnDataAvailable;
            _capture.RecordingStopped -= OnRecordingStopped;
            try
            {
                _capture.Dispose();
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[AudioRecorder] Dispose capture error: {ex.Message}");
            }
            _capture = null;
        }
        ResetCaptureIssueFlags();
        _captureFormat = null;
        _captureDeviceId = null;
    }

    private void CleanupFiles()
    {
        try
        {
            if (_tempFilePath != null && File.Exists(_tempFilePath))
                File.Delete(_tempFilePath);
            if (_outputFilePath != null && File.Exists(_outputFilePath))
                File.Delete(_outputFilePath);
        }
        catch { }

        _tempFilePath = null;
        _outputFilePath = null;
    }

    private void SetState(RecordingState state)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
            State = state;
        else
            dispatcher.Invoke(() => State = state);
    }

    private void SetCountdown(int? countdown)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
            Countdown = countdown;
        else
            dispatcher.BeginInvoke(() => Countdown = countdown);
    }

    private void SetElapsedSeconds(int elapsedSeconds)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
            ElapsedSeconds = elapsedSeconds;
        else
            dispatcher.BeginInvoke(() => ElapsedSeconds = elapsedSeconds);
    }

    private void SetClock(int elapsedSeconds, int? countdown)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            ElapsedSeconds = elapsedSeconds;
            Countdown = countdown;
        }
        else
        {
            dispatcher.BeginInvoke(() =>
            {
                ElapsedSeconds = elapsedSeconds;
                Countdown = countdown;
            });
        }
    }

    private void SetAudioLevel(float level)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
            AudioLevel = level;
        else
            dispatcher.BeginInvoke(() => AudioLevel = level);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        CancelRecording();
        lock (_captureLock)
            DisposeCaptureLocked();
        _deviceService.Dispose();
    }
}
