using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using LobsterInput.Config;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Stores;

namespace LobsterInput.Services;

public sealed record RealtimeAsrFinal(string Text, string Language, int? CreditsRemaining);

public sealed class RealtimeAsrWebSocketClient : IDisposable
{
    private readonly ClientWebSocket _socket = new();
    private readonly CancellationTokenSource _cts = new();
    private readonly TaskCompletionSource _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource<RealtimeAsrFinal> _final = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Channel<OutgoingMessage> _sendQueue = Channel.CreateUnbounded<OutgoingMessage>(
        new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false
        });
    private Task? _receiveTask;
    private Task? _sendTask;
    private bool _disposed;
    private volatile bool _isReady;
    private volatile bool _closing;
    private volatile bool _finishRequested;
    private volatile bool _finalReceived;

    public string AsrSessionId { get; } = $"windows_{Guid.NewGuid():D}";
    public bool IsReady => _isReady;

    public event Action<string, string>? PartialReceived;
    public event Action<string, string>? CompletedReceived;
    public event Action<RealtimeAsrFinal>? Finished;
    public event Action<string>? Error;

    public async Task ConnectAsync(string language)
    {
        _isReady = false;
        _closing = false;
        _finishRequested = false;
        _finalReceived = false;
        var url = BuildUrl(language);
        if (!string.IsNullOrWhiteSpace(AuthStore.Instance.Token))
            _socket.Options.SetRequestHeader("Authorization", $"Bearer {AuthStore.Instance.Token}");
        _socket.Options.SetRequestHeader("X-Client-Platform", "windows");
        _socket.Options.SetRequestHeader("X-App-Variant", ApiConfig.AppVariant);
        _socket.Options.SetRequestHeader("Accept-Language", language);
        _socket.Options.SetRequestHeader("X-Accept-Language", language);

        try
        {
            await _socket.ConnectAsync(url, _cts.Token);
        }
        catch (WebSocketException ex) when (IsForbiddenHandshake(ex))
        {
            AuthSessionManager.Invalidate("RealtimeASR.Connect", "websocket_auth_rejected");
            throw;
        }
        _sendTask = Task.Run(SendLoopAsync);
        _receiveTask = Task.Run(ReceiveLoopAsync);
        await _ready.Task.WaitAsync(TimeSpan.FromSeconds(30));
        _isReady = true;
    }

    public bool EnqueueAudio(byte[] bytes)
    {
        if (_disposed ||
            _closing ||
            _finishRequested ||
            _finalReceived ||
            !_isReady ||
            _socket.State != WebSocketState.Open ||
            bytes.Length == 0)
            return false;
        return _sendQueue.Writer.TryWrite(new OutgoingMessage(bytes, WebSocketMessageType.Binary, null));
    }

    public Task RequestFinishAsync()
    {
        if (_finishRequested || _finalReceived) return Task.CompletedTask;
        if (!_isReady || _socket.State != WebSocketState.Open)
            throw new WebSocketException("Realtime ASR websocket is not ready.");
        _finishRequested = true;
        var payload = Encoding.UTF8.GetBytes("{\"type\":\"finish\"}");
        if (!_sendQueue.Writer.TryWrite(new OutgoingMessage(payload, WebSocketMessageType.Text, null)))
            throw new WebSocketException("Realtime ASR send queue is closed.");
        DebugTrace.Log("RealtimeASR", $"finish enqueued asrSession={AsrSessionId}");
        return Task.CompletedTask;
    }

    public async Task<RealtimeAsrFinal> FinishAsync()
    {
        await RequestFinishAsync();
        return await _final.Task.WaitAsync(TimeSpan.FromSeconds(90));
    }

    public async Task<RealtimeAsrFinal?> WaitForFinalAsync(TimeSpan timeout)
    {
        if (_final.Task.IsCompletedSuccessfully)
            return _final.Task.Result;
        try
        {
            return await _final.Task.WaitAsync(timeout);
        }
        catch (TimeoutException)
        {
            return null;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    public void Close()
    {
        if (_disposed) return;
        _disposed = true;
        _isReady = false;
        _closing = true;
        _sendQueue.Writer.TryComplete();
        _ready.TrySetCanceled();
        _final.TrySetCanceled();
        _cts.Cancel();
        try
        {
            if (_socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "client closed", CancellationToken.None).Wait(500);
        }
        catch
        {
            // Ignore shutdown races.
        }
        _socket.Dispose();
        _cts.Dispose();
    }

    public void Dispose() => Close();

    private static bool IsForbiddenHandshake(WebSocketException exception)
    {
        return exception.Message.Contains("403", StringComparison.Ordinal);
    }

    private async Task SendLoopAsync()
    {
        try
        {
            await foreach (var message in _sendQueue.Reader.ReadAllAsync(_cts.Token))
            {
                await _socket.SendAsync(message.Payload, message.Type, true, _cts.Token);
                message.Sent?.TrySetResult();
            }
        }
        catch (OperationCanceledException)
        {
            CancelPendingSends();
        }
        catch (Exception ex)
        {
            _isReady = false;
            if (_closing || _finalReceived)
            {
                CancelPendingSends();
                return;
            }
            _ready.TrySetException(ex);
            _final.TrySetException(ex);
            Error?.Invoke(ex.Message);
            FailPendingSends(ex);
        }
    }

    private async Task ReceiveLoopAsync()
    {
        var buffer = new byte[32 * 1024];
        var builder = new ArraySegment<byte>(buffer);
        try
        {
            while (!_cts.IsCancellationRequested && _socket.State == WebSocketState.Open)
            {
                using var ms = new MemoryStream();
                WebSocketReceiveResult result;
                do
                {
                    result = await _socket.ReceiveAsync(builder, _cts.Token);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        _isReady = false;
                        return;
                    }
                    ms.Write(buffer, 0, result.Count);
                } while (!result.EndOfMessage);

                if (result.MessageType == WebSocketMessageType.Text)
                    HandleMessage(Encoding.UTF8.GetString(ms.ToArray()));
            }
        }
        catch (OperationCanceledException)
        {
            _isReady = false;
            _ready.TrySetCanceled();
            _final.TrySetCanceled();
        }
        catch (Exception ex)
        {
            _isReady = false;
            if (_closing || _finalReceived)
                return;
            _ready.TrySetException(ex);
            _final.TrySetException(ex);
            Error?.Invoke(ex.Message);
        }
    }

    private void HandleMessage(string text)
    {
        JsonDocument doc;
        try { doc = JsonDocument.Parse(text); }
        catch { return; }

        using (doc)
        {
            var root = doc.RootElement;
            var type = StringProp(root, "type");
            switch (type)
            {
                case "ready":
                    _isReady = true;
                    _ready.TrySetResult();
                    break;
                case "partial":
                    PartialReceived?.Invoke(StringProp(root, "text"), StringProp(root, "language"));
                    break;
                case "completed":
                    CompletedReceived?.Invoke(
                        FirstNonEmpty(StringProp(root, "text"), StringProp(root, "transcript")),
                        StringProp(root, "language"));
                    break;
                case "finished":
                    var final = new RealtimeAsrFinal(
                        FirstNonEmpty(StringProp(root, "text"), StringProp(root, "transcript")),
                        StringProp(root, "language"),
                        IntProp(root, "credits_remaining"));
                    _finalReceived = true;
                    _isReady = false;
                    _final.TrySetResult(final);
                    Finished?.Invoke(final);
                    break;
                case "error":
                    var message = FirstNonEmpty(StringProp(root, "message"), "Realtime ASR error");
                    _isReady = false;
                    _ready.TrySetException(new ApiException(500, message));
                    _final.TrySetException(new ApiException(500, message));
                    Error?.Invoke(message);
                    break;
            }
        }
    }

    private Uri BuildUrl(string language)
    {
        var builder = new UriBuilder(ApiConfig.AudioV2.RealtimeASR);
        var uiLanguage = Uri.EscapeDataString(language);
        builder.Query = string.Join("&", new[]
        {
            $"language={uiLanguage}",
            "sample_rate=16000",
            "audio_format=pcm",
            "vad=true",
            "max_duration_sec=60",
            $"asr_session_id={Uri.EscapeDataString(AsrSessionId)}"
        });
        return builder.Uri;
    }

    private static string StringProp(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null
            ? value.GetString() ?? ""
            : "";

    private static int? IntProp(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result)
            ? result
            : null;

    private static string FirstNonEmpty(params string[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value)) ?? "";

    private void CancelPendingSends()
    {
        while (_sendQueue.Reader.TryRead(out var pending))
            pending.Sent?.TrySetCanceled();
    }

    private void FailPendingSends(Exception ex)
    {
        while (_sendQueue.Reader.TryRead(out var pending))
            pending.Sent?.TrySetException(ex);
    }

    private sealed record OutgoingMessage(
        byte[] Payload,
        WebSocketMessageType Type,
        TaskCompletionSource? Sent);
}
