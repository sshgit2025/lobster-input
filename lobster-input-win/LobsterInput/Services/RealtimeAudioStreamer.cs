using System.Buffers.Binary;
using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Services.Audio;
using NAudio.Wave;

namespace LobsterInput.Services;

public enum RealtimeRecordingState
{
    Idle,
    Starting,
    Streaming,
    Processing
}

public sealed partial class RealtimeAudioStreamer : ObservableObject, IDisposable
{
    private SafeWasapiCapture? _capture;
    private Func<byte[], Task>? _onChunk;
    private Task? _tickerTask;
    private CancellationTokenSource? _tickerCts;
    private TaskCompletionSource? _audioVerified;
    private DateTime _startedAt;
    private double _resamplePosition;
    private readonly object _gate = new();
    private readonly object _verifyGate = new();

    public static RealtimeAudioStreamer Instance { get; } = new();

    [ObservableProperty]
    private RealtimeRecordingState _state = RealtimeRecordingState.Idle;

    [ObservableProperty]
    private float _audioLevel;

    [ObservableProperty]
    private int _elapsedSeconds;

    [ObservableProperty]
    private int? _countdown;

    public int MaxDuration { get; set; } = 60;
    public event Action? MaxDurationReached;

    private RealtimeAudioStreamer() { }

    public bool PrepareStartingVisualState()
    {
        lock (_gate)
        {
            if (State != RealtimeRecordingState.Idle) return false;
            AudioLevel = 0;
            ElapsedSeconds = 0;
            Countdown = null;
            State = RealtimeRecordingState.Starting;
            return true;
        }
    }

    public async Task<bool> StartAsync(Func<byte[], Task> onChunk)
    {
        lock (_gate)
        {
            if (State is not (RealtimeRecordingState.Idle or RealtimeRecordingState.Starting))
                return false;
            if (State == RealtimeRecordingState.Idle)
                State = RealtimeRecordingState.Starting;
            _onChunk = onChunk;
            _resamplePosition = 0;
        }

        var candidates = AudioDeviceService.Instance.ResolveCaptureDeviceCandidates();
        if (candidates.Count == 0)
        {
            DebugTrace.Log("RealtimeAudio", "Start skipped: no capture device");
            ResetToIdle();
            return false;
        }

        foreach (var candidate in candidates)
        {
            try
            {
                using var device = AudioDeviceService.Instance.OpenCaptureDevice(candidate);
                _capture = new SafeWasapiCapture(device, audioBufferMillisecondsLength: 60);
                _capture.DataAvailable += OnDataAvailable;
                _capture.RecordingStopped += OnRecordingStopped;
                ResetAudioVerification();
                _capture.StartRecording();
                if (!await WaitForAudioVerificationAsync(TimeSpan.FromMilliseconds(900)).ConfigureAwait(false))
                {
                    DebugTrace.Log(
                        "RealtimeAudio",
                        $"Candidate produced no audio chunks device={candidate.Id}, name={candidate.Name}, order={candidate.Order}, auto={candidate.IsAutomaticSelection}, reason={candidate.Reason}");
                    StopCapture();
                    if (!candidate.IsAutomaticSelection)
                        break;
                    continue;
                }

                _startedAt = DateTime.UtcNow;
                State = RealtimeRecordingState.Streaming;
                StartTicker();
                DebugTrace.Log(
                    "RealtimeAudio",
                    $"Streaming started device={candidate.Id}, name={candidate.Name}, order={candidate.Order}, auto={candidate.IsAutomaticSelection}, format={_capture.WaveFormat}");
                return true;
            }
            catch (Exception ex)
            {
                DebugTrace.LogError("RealtimeAudio.Start", ex);
                StopCapture();
                if (!candidate.IsAutomaticSelection &&
                    !AudioDeviceService.IsRecoverableCaptureException(ex))
                {
                    break;
                }
            }
        }

        ResetToIdle();
        return false;
    }

    public Task StopForProcessingAsync()
    {
        lock (_gate)
        {
            if (State is not (RealtimeRecordingState.Streaming or RealtimeRecordingState.Starting)) return Task.CompletedTask;
            State = RealtimeRecordingState.Processing;
        }

        StopCapture();
        AudioLevel = 0;
        StopTicker();
        return Task.CompletedTask;
    }

    public void Cancel()
    {
        StopCapture();
        ResetToIdle();
    }

    public void ResetToIdle()
    {
        StopTicker();
        StopCapture();
        _onChunk = null;
        AudioLevel = 0;
        ElapsedSeconds = 0;
        Countdown = null;
        State = RealtimeRecordingState.Idle;
    }

    public void Dispose()
    {
        StopTicker();
        StopCapture();
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        var capture = _capture;
        if (State is not (RealtimeRecordingState.Starting or RealtimeRecordingState.Streaming) ||
            capture == null ||
            !ReferenceEquals(sender, capture))
        {
            return;
        }

        var format = capture.WaveFormat;
        var pcm = ConvertChunk(e.Buffer, e.BytesRecorded, format);
        if (pcm.Length == 0) return;

        MarkAudioVerified();
        if (State is not (RealtimeRecordingState.Starting or RealtimeRecordingState.Streaming)) return;
        var handler = _onChunk;
        if (handler != null)
            _ = handler(pcm);
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception != null)
            DebugTrace.LogError("RealtimeAudio.Stop", e.Exception);
    }

    private byte[] ConvertChunk(byte[] buffer, int bytesRecorded, WaveFormat format)
    {
        if (bytesRecorded <= 0 || format.Channels <= 0 || format.SampleRate <= 0) return [];
        var bytesPerSample = Math.Max(1, format.BitsPerSample / 8);
        var frameSize = Math.Max(1, bytesPerSample * format.Channels);
        var frameCount = bytesRecorded / frameSize;
        if (frameCount <= 1) return [];

        var mono = new float[frameCount];
        var peak = 0f;
        for (var frame = 0; frame < frameCount; frame++)
        {
            var sum = 0f;
            for (var channel = 0; channel < format.Channels; channel++)
            {
                var offset = frame * frameSize + channel * bytesPerSample;
                sum += ReadSample(buffer, offset, format);
            }
            var sample = sum / format.Channels;
            mono[frame] = sample;
            peak = Math.Max(peak, Math.Abs(sample));
        }
        AudioLevel = Math.Clamp(peak * 2.4f, 0, 1);

        var step = format.SampleRate / 16000.0;
        var output = new List<short>(Math.Max(1, (int)(frameCount / step)));
        while (_resamplePosition < mono.Length - 1)
        {
            var index = (int)_resamplePosition;
            var frac = _resamplePosition - index;
            var sample = mono[index] * (1 - frac) + mono[index + 1] * frac;
            output.Add((short)Math.Clamp((int)Math.Round(sample * short.MaxValue), short.MinValue, short.MaxValue));
            _resamplePosition += step;
        }
        _resamplePosition -= mono.Length;

        if (output.Count == 0) return [];
        var bytes = new byte[output.Count * 2];
        for (var i = 0; i < output.Count; i++)
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(i * 2, 2), output[i]);
        return bytes;
    }

    private static float ReadSample(byte[] buffer, int offset, WaveFormat format)
    {
        try
        {
            if (format.Encoding == WaveFormatEncoding.IeeeFloat && format.BitsPerSample == 32)
                return Math.Clamp(BitConverter.ToSingle(buffer, offset), -1f, 1f);
            if (format.BitsPerSample == 16)
                return BinaryPrimitives.ReadInt16LittleEndian(buffer.AsSpan(offset, 2)) / 32768f;
            if (format.BitsPerSample == 24)
            {
                var value = buffer[offset] | (buffer[offset + 1] << 8) | (buffer[offset + 2] << 16);
                if ((value & 0x800000) != 0) value |= unchecked((int)0xFF000000);
                return Math.Clamp(value / 8388608f, -1f, 1f);
            }
            if (format.BitsPerSample == 32)
                return Math.Clamp(BinaryPrimitives.ReadInt32LittleEndian(buffer.AsSpan(offset, 4)) / 2147483648f, -1f, 1f);
        }
        catch
        {
        }
        return 0;
    }

    private void StartTicker()
    {
        StopTicker();
        _tickerCts = new CancellationTokenSource();
        var token = _tickerCts.Token;
        _tickerTask = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested && State == RealtimeRecordingState.Streaming)
            {
                var elapsed = DateTime.UtcNow - _startedAt;
                ElapsedSeconds = Math.Max(0, (int)Math.Floor(elapsed.TotalSeconds));
                var remaining = MaxDuration - elapsed.TotalSeconds;
                Countdown = remaining <= 10 ? Math.Max(0, (int)Math.Ceiling(remaining)) : null;
                if (remaining <= 0)
                {
                    MaxDurationReached?.Invoke();
                    return;
                }
                await Task.Delay(200, token);
            }
        }, token);
    }

    private void StopTicker()
    {
        try { _tickerCts?.Cancel(); }
        catch { }
        _tickerCts?.Dispose();
        _tickerCts = null;
        _tickerTask = null;
        Countdown = null;
    }

    private void StopCapture()
    {
        CancelAudioVerification();
        var capture = _capture;
        if (capture == null) return;
        _capture = null;
        capture.DataAvailable -= OnDataAvailable;
        capture.RecordingStopped -= OnRecordingStopped;
        try { capture.StopRecording(); }
        catch { }
        capture.Dispose();
    }

    private void ResetAudioVerification()
    {
        lock (_verifyGate)
        {
            _audioVerified = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        }
    }

    private void MarkAudioVerified()
    {
        lock (_verifyGate)
        {
            _audioVerified?.TrySetResult();
        }
    }

    private void CancelAudioVerification()
    {
        lock (_verifyGate)
        {
            _audioVerified?.TrySetCanceled();
            _audioVerified = null;
        }
    }

    private async Task<bool> WaitForAudioVerificationAsync(TimeSpan timeout)
    {
        TaskCompletionSource? verifier;
        lock (_verifyGate)
        {
            verifier = _audioVerified;
        }
        if (verifier == null) return false;
        try
        {
            await verifier.Task.WaitAsync(timeout).ConfigureAwait(false);
            return true;
        }
        catch (TimeoutException)
        {
            return false;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }
}
