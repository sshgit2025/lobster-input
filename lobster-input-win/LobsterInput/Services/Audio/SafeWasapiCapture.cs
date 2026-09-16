using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace LobsterInput.Services.Audio;

/// <summary>
/// WASAPI capture wrapper matching NAudio's WasapiCapture behavior, with one important
/// hardening: AudioClient.Stop failures are reported through RecordingStopped instead of
/// escaping the capture thread as unhandled exceptions.
/// </summary>
internal sealed class SafeWasapiCapture : IWaveIn
{
    private const long ReftimesPerSec = 10_000_000;
    private const long ReftimesPerMillisec = 10_000;

    private readonly AudioClient _audioClient;
    private readonly bool _useEventSync;
    private readonly int _audioBufferMillisecondsLength;
    private readonly SynchronizationContext? _syncContext;

    private volatile CaptureState _captureState = CaptureState.Stopped;
    private byte[] _recordBuffer = [];
    private Thread? _captureThread;
    private EventWaitHandle? _frameEventWaitHandle;
    private int _bytesPerFrame;
    private bool _initialized;
    private bool _disposed;
    private WaveFormat _waveFormat;

    public SafeWasapiCapture(MMDevice captureDevice, bool useEventSync = false, int audioBufferMillisecondsLength = 100)
    {
        _syncContext = SynchronizationContext.Current;
        _audioClient = captureDevice.AudioClient;
        _useEventSync = useEventSync;
        _audioBufferMillisecondsLength = audioBufferMillisecondsLength;
        _waveFormat = _audioClient.MixFormat;
        ShareMode = AudioClientShareMode.Shared;
    }

    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;

    public AudioClientShareMode ShareMode { get; set; }

    public CaptureState CaptureState => _captureState;

    public WaveFormat WaveFormat
    {
        get => _waveFormat.AsStandardWaveFormat();
        set => _waveFormat = value;
    }

    public void StartRecording()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_captureState != CaptureState.Stopped)
            throw new InvalidOperationException("Previous recording still in progress");

        _captureState = CaptureState.Starting;
        InitializeCaptureDevice();
        _captureThread = new Thread(() => CaptureThread(_audioClient))
        {
            IsBackground = true,
            Name = "LobsterInput.WasapiCapture"
        };
        _captureThread.Start();
    }

    public void StopRecording()
    {
        if (_captureState != CaptureState.Stopped)
            _captureState = CaptureState.Stopping;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        StopRecording();
        var thread = _captureThread;
        if (thread != null && thread != Thread.CurrentThread)
        {
            if (!thread.Join(TimeSpan.FromSeconds(2)))
                DebugTrace.Log("AudioRecorder", "SafeWasapiCapture dispose timed out waiting for capture thread");
        }

        _frameEventWaitHandle?.Dispose();
        _audioClient.Dispose();
        GC.SuppressFinalize(this);
    }

    private void InitializeCaptureDevice()
    {
        if (_initialized) return;

        var requestedDuration = ReftimesPerMillisec * _audioBufferMillisecondsLength;
        if (ShareMode == AudioClientShareMode.Exclusive && !_audioClient.IsFormatSupported(ShareMode, _waveFormat))
            throw new ArgumentException("Unsupported Wave Format");

        var streamFlags = GetAudioClientStreamFlags();
        if (_useEventSync)
        {
            if (ShareMode == AudioClientShareMode.Shared)
            {
                _audioClient.Initialize(
                    ShareMode,
                    AudioClientStreamFlags.EventCallback | streamFlags,
                    requestedDuration,
                    0,
                    _waveFormat,
                    Guid.Empty);
            }
            else
            {
                _audioClient.Initialize(
                    ShareMode,
                    AudioClientStreamFlags.EventCallback | streamFlags,
                    requestedDuration,
                    requestedDuration,
                    _waveFormat,
                    Guid.Empty);
            }

            _frameEventWaitHandle = new EventWaitHandle(false, EventResetMode.AutoReset);
            _audioClient.SetEventHandle(_frameEventWaitHandle.SafeWaitHandle.DangerousGetHandle());
        }
        else
        {
            _audioClient.Initialize(ShareMode, streamFlags, requestedDuration, 0, _waveFormat, Guid.Empty);
        }

        var bufferFrameCount = _audioClient.BufferSize;
        _bytesPerFrame = _waveFormat.Channels * _waveFormat.BitsPerSample / 8;
        _recordBuffer = new byte[bufferFrameCount * _bytesPerFrame];
        _initialized = true;
    }

    private AudioClientStreamFlags GetAudioClientStreamFlags()
    {
        return ShareMode == AudioClientShareMode.Shared
            ? AudioClientStreamFlags.AutoConvertPcm | AudioClientStreamFlags.SrcDefaultQuality
            : 0;
    }

    private void CaptureThread(AudioClient client)
    {
        Exception? exception = null;
        try
        {
            DoRecording(client);
        }
        catch (Exception ex)
        {
            exception = ex;
        }
        finally
        {
            try
            {
                client.Stop();
            }
            catch (Exception ex)
            {
                exception ??= ex;
            }
        }

        _captureThread = null;
        _captureState = CaptureState.Stopped;
        RaiseRecordingStopped(exception);
    }

    private void DoRecording(AudioClient client)
    {
        var bufferFrameCount = client.BufferSize;
        var actualDuration = (long)(ReftimesPerSec * bufferFrameCount / _waveFormat.SampleRate);
        var sleepMilliseconds = (int)(actualDuration / ReftimesPerMillisec / 2);
        var waitMilliseconds = (int)(3 * actualDuration / ReftimesPerMillisec);
        var capture = client.AudioCaptureClient;

        client.Start();
        if (_captureState == CaptureState.Starting)
            _captureState = CaptureState.Capturing;

        while (_captureState == CaptureState.Capturing)
        {
            if (_useEventSync)
                _frameEventWaitHandle?.WaitOne(waitMilliseconds, false);
            else
                Thread.Sleep(sleepMilliseconds);

            if (_captureState != CaptureState.Capturing) break;
            ReadNextPacket(capture);
        }
    }

    private void ReadNextPacket(AudioCaptureClient capture)
    {
        var packetSize = capture.GetNextPacketSize();
        var recordBufferOffset = 0;

        while (packetSize != 0)
        {
            var buffer = capture.GetBuffer(out var framesAvailable, out var flags);
            var bytesAvailable = framesAvailable * _bytesPerFrame;
            var spaceRemaining = Math.Max(0, _recordBuffer.Length - recordBufferOffset);
            if (spaceRemaining < bytesAvailable && recordBufferOffset > 0)
            {
                DataAvailable?.Invoke(this, new WaveInEventArgs(_recordBuffer, recordBufferOffset));
                recordBufferOffset = 0;
            }

            if ((flags & AudioClientBufferFlags.Silent) != AudioClientBufferFlags.Silent)
                Marshal.Copy(buffer, _recordBuffer, recordBufferOffset, bytesAvailable);
            else
                Array.Clear(_recordBuffer, recordBufferOffset, bytesAvailable);

            recordBufferOffset += bytesAvailable;
            capture.ReleaseBuffer(framesAvailable);
            packetSize = capture.GetNextPacketSize();
        }

        DataAvailable?.Invoke(this, new WaveInEventArgs(_recordBuffer, recordBufferOffset));
    }

    private void RaiseRecordingStopped(Exception? exception)
    {
        var handler = RecordingStopped;
        if (handler == null) return;

        if (_syncContext == null)
            handler(this, new StoppedEventArgs(exception));
        else
            _syncContext.Post(_ => handler(this, new StoppedEventArgs(exception)), null);
    }
}
