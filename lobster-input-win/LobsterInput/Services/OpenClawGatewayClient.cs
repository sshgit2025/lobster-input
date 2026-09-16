using System.Diagnostics;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using LobsterInput.Config;

namespace LobsterInput.Services;

public class GatewayAgentEvent
{
    public enum EventType { Started, Text, Done, Error }

    public EventType Type { get; set; }
    public string Content { get; set; } = "";
    public string Accumulated { get; set; } = "";
    public string? RunId { get; set; }
    public int? MessageSeq { get; set; }
}

public sealed class OpenClawGatewayClient
{
    public static OpenClawGatewayClient Instance { get; } = new();

    private static readonly string OpenClawHome =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".openclaw");
    private static readonly string ConfigFilePath = Path.Combine(OpenClawHome, "openclaw.json");

    private OpenClawGatewayClient() { }

    public async Task SendAsync(
        string content,
        List<Dictionary<string, object>>? attachments,
        string binaryPath,
        string sessionKey,
        Action<GatewayAgentEvent>? onEvent,
        CancellationToken cancellationToken = default)
    {
        var baselineSeq = await SessionMaxSeqAsync(binaryPath, sessionKey, cancellationToken);
        var credential = ReadGatewayCredential()
            ?? throw new InvalidOperationException("未找到 OpenClaw Gateway 本地认证凭证");

        await using var connection = new OpenClawGatewayWebSocketConnection(
            new Uri(ApiConfig.OpenClaw.GatewayWs),
            credential,
            sessionKey,
            baselineSeq,
            onEvent);

        var finalText = await connection.RunAsync(content, attachments, cancellationToken);
        onEvent?.Invoke(new GatewayAgentEvent
        {
            Type = GatewayAgentEvent.EventType.Done,
            Content = finalText,
            Accumulated = finalText
        });
    }

    public async Task<string> AbortActiveSessionAsync(
        string binaryPath,
        string sessionKey,
        string? runId = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var credential = ReadGatewayCredential()
                ?? throw new InvalidOperationException("未找到 OpenClaw Gateway 本地认证凭证");
            await using var connection = new OpenClawGatewayWebSocketConnection(
                new Uri(ApiConfig.OpenClaw.GatewayWs),
                credential,
                sessionKey,
                0,
                null);
            return await connection.AbortAsync(runId, cancellationToken);
        }
        catch
        {
            var paramsJson = JsonSerializer.Serialize(new { key = sessionKey, runId });
            var output = await RunOpenClawAsync(binaryPath, new[]
            {
                "gateway", "call", "sessions.abort",
                "--timeout", "10000",
                "--json",
                "--params", paramsJson
            }, TimeSpan.FromSeconds(15), cancellationToken);

            return ExtractAbortText(output);
        }
    }

    public async Task DeleteSessionAsync(
        string binaryPath,
        string sessionKey,
        CancellationToken cancellationToken = default)
    {
        var paramsJson = JsonSerializer.Serialize(new { key = sessionKey, deleteTranscript = true });
        _ = await RunOpenClawAsync(binaryPath, new[]
        {
            "gateway", "call", "sessions.delete",
            "--timeout", "10000",
            "--json",
            "--params", paramsJson
        }, TimeSpan.FromSeconds(15), cancellationToken);
    }

    private static async Task<int> SessionMaxSeqAsync(
        string binaryPath,
        string sessionKey,
        CancellationToken cancellationToken)
    {
        try
        {
            var paramsJson = JsonSerializer.Serialize(new { key = sessionKey });
            var output = await RunOpenClawAsync(binaryPath, new[]
            {
                "gateway", "call", "sessions.get",
                "--timeout", "10000",
                "--json",
                "--params", paramsJson
            }, TimeSpan.FromSeconds(15), cancellationToken);

            using var doc = JsonDocument.Parse(output);
            if (!doc.RootElement.TryGetProperty("messages", out var messages)
                || messages.ValueKind != JsonValueKind.Array)
                return 0;

            var max = 0;
            foreach (var row in messages.EnumerateArray())
            {
                if (TryGetMessageSeq(row, null, out var seq))
                    max = Math.Max(max, seq);
            }
            return max;
        }
        catch
        {
            return 0;
        }
    }

    private static GatewayCredential? ReadGatewayCredential()
    {
        if (!File.Exists(ConfigFilePath)) return null;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(ConfigFilePath));
            var root = doc.RootElement;
            if (!root.TryGetProperty("gateway", out var gw)) return null;
            if (!gw.TryGetProperty("auth", out var auth)) return null;

            var mode = auth.TryGetProperty("mode", out var modeEl)
                ? modeEl.GetString() ?? "token"
                : "token";

            if (mode == "password"
                && auth.TryGetProperty("password", out var pwEl)
                && !string.IsNullOrWhiteSpace(pwEl.GetString()))
                return new GatewayCredential("password", pwEl.GetString()!);

            if (auth.TryGetProperty("token", out var tokenEl)
                && !string.IsNullOrWhiteSpace(tokenEl.GetString()))
                return new GatewayCredential("token", tokenEl.GetString()!);

            return null;
        }
        catch
        {
            return null;
        }
    }

    private static async Task<string> RunOpenClawAsync(
        string binaryPath,
        IEnumerable<string> arguments,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var timeoutCts = new CancellationTokenSource(timeout);
        using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(timeoutCts.Token, cancellationToken);
        var argList = arguments.ToList();
        var psi = CreateProcessStartInfo(binaryPath, argList);

        using var proc = new Process { StartInfo = psi };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();

        proc.OutputDataReceived += (_, e) =>
        {
            if (e.Data != null) stdout.AppendLine(e.Data);
        };
        proc.ErrorDataReceived += (_, e) =>
        {
            if (e.Data != null) stderr.AppendLine(e.Data);
        };

        proc.Start();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        try
        {
            await proc.WaitForExitAsync(linkedCts.Token);
        }
        catch (OperationCanceledException) when (timeoutCts.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            TryKill(proc);
            throw new TimeoutException("OpenClaw 请求超时");
        }

        if (proc.ExitCode != 0)
        {
            var err = stderr.Length > 0 ? stderr.ToString() : stdout.ToString();
            throw new InvalidOperationException($"OpenClaw 命令失败 {proc.ExitCode}: {err}");
        }

        return stdout.ToString();
    }

    private static ProcessStartInfo CreateProcessStartInfo(string binaryPath, IReadOnlyList<string> arguments)
    {
        if (binaryPath.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)
            || binaryPath.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
        {
            return new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand " + BuildPowerShellCommand(binaryPath, arguments),
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
        }

        var psi = new ProcessStartInfo
        {
            FileName = binaryPath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var arg in arguments) psi.ArgumentList.Add(arg);
        return psi;
    }

    private static string ExtractAbortText(string output)
    {
        var trimmed = output.Trim();
        try
        {
            using var doc = JsonDocument.Parse(trimmed);
            return ExtractAbortText(doc.RootElement);
        }
        catch (JsonException)
        {
            return string.IsNullOrWhiteSpace(trimmed) ? "OpenClaw 中断请求已发送" : trimmed;
        }
    }

    private static string ExtractAbortText(JsonElement root)
    {
        if (root.TryGetProperty("aborted", out var aborted)
            && aborted.ValueKind == JsonValueKind.True)
            return "已中断 OpenClaw 当前任务";

        if (root.TryGetProperty("status", out var statusEl))
        {
            var status = statusEl.GetString();
            if (status == "aborted") return "已中断 OpenClaw 当前任务";
            if (status == "no-active-run") return "OpenClaw 当前没有正在运行的任务";
        }

        return "OpenClaw 中断请求已发送";
    }

    private static bool TryGetMessageSeq(JsonElement message, int? fallbackSeq, out int seq)
    {
        if (message.TryGetProperty("__openclaw", out var meta)
            && meta.ValueKind == JsonValueKind.Object
            && meta.TryGetProperty("seq", out var seqEl)
            && seqEl.TryGetInt32(out seq))
            return true;

        if (fallbackSeq.HasValue)
        {
            seq = fallbackSeq.Value;
            return true;
        }

        seq = 0;
        return false;
    }

    private static string ExtractMessageText(JsonElement value)
    {
        if (value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
            return "";

        if (value.ValueKind == JsonValueKind.String)
            return value.GetString() ?? "";

        if (value.ValueKind == JsonValueKind.Array)
        {
            var pieces = new List<string>();
            foreach (var block in value.EnumerateArray())
            {
                if (block.ValueKind != JsonValueKind.Object) continue;
                if (block.TryGetProperty("text", out var textEl) && textEl.ValueKind == JsonValueKind.String)
                    pieces.Add(textEl.GetString() ?? "");
                else if (block.TryGetProperty("content", out var contentEl) && contentEl.ValueKind == JsonValueKind.String)
                    pieces.Add(contentEl.GetString() ?? "");
                else if (block.TryGetProperty("type", out var typeEl) && typeEl.ValueKind == JsonValueKind.String)
                {
                    var type = typeEl.GetString() ?? "item";
                    if (block.TryGetProperty("name", out var nameEl) && nameEl.ValueKind == JsonValueKind.String)
                        pieces.Add($"[{type}] {nameEl.GetString()}");
                    else
                        pieces.Add($"[{type}]");
                }
            }
            return string.Join("\n", pieces.Where(p => !string.IsNullOrWhiteSpace(p)));
        }

        if (value.ValueKind == JsonValueKind.Object)
        {
            if (value.TryGetProperty("text", out var textEl) && textEl.ValueKind == JsonValueKind.String)
                return textEl.GetString() ?? "";
            if (value.TryGetProperty("content", out var contentEl) && contentEl.ValueKind == JsonValueKind.String)
                return contentEl.GetString() ?? "";
        }

        return value.GetRawText();
    }

    private static string BuildPowerShellCommand(string binaryPath, IEnumerable<string> arguments)
    {
        var args = string.Join(", ", arguments.Select(PsQuote));
        var script = "$ErrorActionPreference='Stop'; "
            + "& " + PsQuote(binaryPath) + " @(" + args + "); "
            + "exit $LASTEXITCODE";
        return Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
    }

    private static string PsQuote(string value) => "'" + value.Replace("'", "''") + "'";

    private static void TryKill(Process proc)
    {
        try
        {
            if (!proc.HasExited) proc.Kill(entireProcessTree: true);
        }
        catch
        {
            // best effort
        }
    }

    private sealed record GatewayCredential(string Mode, string Value)
    {
        public Dictionary<string, object> AuthPayload =>
            Mode == "password"
                ? new Dictionary<string, object> { ["password"] = Value }
                : new Dictionary<string, object> { ["token"] = Value };
    }

    private sealed class OpenClawGatewayWebSocketConnection : IAsyncDisposable
    {
        private readonly Uri _url;
        private readonly GatewayCredential _credential;
        private readonly string _sessionKey;
        private readonly Action<GatewayAgentEvent>? _onEvent;
        private readonly ClientWebSocket _socket = new();
        private readonly Dictionary<string, TaskCompletionSource<JsonElement>> _pendingResponses = new();
        private readonly OpenClawLiveTranscriptRenderer _renderer;
        private readonly object _gate = new();
        private Task? _receiveTask;
        private TaskCompletionSource<string>? _completion;
        private TaskCompletionSource? _challenge;
        private string? _runId;
        private int? _messageSeq;
        private bool _completed;

        public OpenClawGatewayWebSocketConnection(
            Uri url,
            GatewayCredential credential,
            string sessionKey,
            int baselineSeq,
            Action<GatewayAgentEvent>? onEvent)
        {
            _url = url;
            _credential = credential;
            _sessionKey = sessionKey;
            _onEvent = onEvent;
            _renderer = new OpenClawLiveTranscriptRenderer(baselineSeq);
        }

        public async Task<string> RunAsync(
            string message,
            List<Dictionary<string, object>>? attachments,
            CancellationToken cancellationToken)
        {
            await ConnectAsync(cancellationToken);
            await RequestAsync("sessions.subscribe", new Dictionary<string, object>(), TimeSpan.FromSeconds(10), cancellationToken);
            await RequestAsync(
                "sessions.create",
                new Dictionary<string, object> { ["key"] = _sessionKey },
                TimeSpan.FromSeconds(10),
                cancellationToken);
            await RequestAsync(
                "sessions.messages.subscribe",
                new Dictionary<string, object> { ["key"] = _sessionKey },
                TimeSpan.FromSeconds(10),
                cancellationToken);
            _completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);

            var sendParams = new Dictionary<string, object>
            {
                ["key"] = _sessionKey,
                ["message"] = message
            };
            if (attachments is { Count: > 0 })
                sendParams["attachments"] = attachments;

            var response = await RequestAsync(
                "sessions.send",
                sendParams,
                TimeSpan.FromSeconds(20),
                cancellationToken);

            if (response.TryGetProperty("runId", out var runIdEl) && runIdEl.ValueKind == JsonValueKind.String)
                _runId = runIdEl.GetString();
            if (response.TryGetProperty("messageSeq", out var seqEl) && seqEl.TryGetInt32(out var seq))
                _messageSeq = seq;

            _onEvent?.Invoke(new GatewayAgentEvent
            {
                Type = GatewayAgentEvent.EventType.Started,
                RunId = _runId,
                MessageSeq = _messageSeq
            });

            using var timeoutCts = new CancellationTokenSource(TimeSpan.FromMinutes(4));
            using var linkedCts = CancellationTokenSource.CreateLinkedTokenSource(timeoutCts.Token, cancellationToken);
            using var _ = linkedCts.Token.Register(() => _completion.TrySetCanceled(linkedCts.Token));
            return await _completion.Task;
        }

        public async Task<string> AbortAsync(string? runId, CancellationToken cancellationToken)
        {
            await ConnectAsync(cancellationToken);
            var parameters = new Dictionary<string, object> { ["key"] = _sessionKey };
            if (!string.IsNullOrWhiteSpace(runId))
                parameters["runId"] = runId;
            var response = await RequestAsync("sessions.abort", parameters, TimeSpan.FromSeconds(10), cancellationToken);
            return ExtractAbortText(response);
        }

        private async Task ConnectAsync(CancellationToken cancellationToken)
        {
            _challenge = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            await _socket.ConnectAsync(_url, cancellationToken);
            _receiveTask = Task.Run(() => ReceiveLoopAsync(cancellationToken), CancellationToken.None);

            await WaitWithTimeoutAsync(_challenge.Task, TimeSpan.FromSeconds(10), cancellationToken);
            await RequestAsync("connect", BuildConnectParams(), TimeSpan.FromSeconds(10), cancellationToken, "connect-1");
        }

        private Dictionary<string, object> BuildConnectParams() => new()
        {
            ["minProtocol"] = 4,
            ["maxProtocol"] = 4,
            ["client"] = new Dictionary<string, object>
            {
                ["id"] = "gateway-client",
                ["version"] = "lobster-input-win",
                ["platform"] = "windows",
                ["mode"] = "backend",
            },
            ["role"] = "operator",
            ["scopes"] = new[] { "operator.read", "operator.write", "operator.admin" },
            ["caps"] = Array.Empty<object>(),
            ["commands"] = Array.Empty<object>(),
            ["permissions"] = new Dictionary<string, object>(),
            ["auth"] = _credential.AuthPayload,
            ["locale"] = Thread.CurrentThread.CurrentUICulture.Name,
            ["userAgent"] = "lobster-input-win/openclaw-gateway",
        };

        private async Task<JsonElement> RequestAsync(
            string method,
            Dictionary<string, object> parameters,
            TimeSpan timeout,
            CancellationToken cancellationToken,
            string? id = null)
        {
            id ??= Guid.NewGuid().ToString("N");
            var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate)
                _pendingResponses[id] = tcs;

            var payload = JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["type"] = "req",
                ["id"] = id,
                ["method"] = method,
                ["params"] = parameters
            });
            var bytes = Encoding.UTF8.GetBytes(payload);
            await _socket.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, cancellationToken);

            return await WaitWithTimeoutAsync(tcs.Task, timeout, cancellationToken);
        }

        private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
        {
            var buffer = new byte[64 * 1024];
            try
            {
                while (_socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
                {
                    using var ms = new MemoryStream();
                    WebSocketReceiveResult result;
                    do
                    {
                        result = await _socket.ReceiveAsync(new ArraySegment<byte>(buffer), cancellationToken);
                        if (result.MessageType == WebSocketMessageType.Close)
                            throw new WebSocketException("OpenClaw Gateway WebSocket 连接已关闭");
                        ms.Write(buffer, 0, result.Count);
                    } while (!result.EndOfMessage);

                    if (result.MessageType == WebSocketMessageType.Text)
                        HandleMessage(Encoding.UTF8.GetString(ms.ToArray()));
                }
            }
            catch (Exception ex)
            {
                FailAll(ex);
            }
        }

        private void HandleMessage(string text)
        {
            using var doc = JsonDocument.Parse(text);
            var root = doc.RootElement.Clone();
            if (!root.TryGetProperty("type", out var typeEl)) return;
            var type = typeEl.GetString();
            if (type == "res")
                HandleResponse(root);
            else if (type == "event")
                HandleEvent(root);
        }

        private void HandleResponse(JsonElement root)
        {
            if (!root.TryGetProperty("id", out var idEl)) return;
            var id = idEl.GetString();
            if (string.IsNullOrEmpty(id)) return;

            TaskCompletionSource<JsonElement>? tcs;
            lock (_gate)
            {
                if (!_pendingResponses.Remove(id, out tcs)) return;
            }

            if (root.TryGetProperty("ok", out var okEl) && okEl.ValueKind == JsonValueKind.True)
            {
                JsonElement payload;
                if (root.TryGetProperty("payload", out var payloadEl))
                {
                    payload = payloadEl.Clone();
                }
                else
                {
                    using var empty = JsonDocument.Parse("{}");
                    payload = empty.RootElement.Clone();
                }
                tcs.TrySetResult(payload);
            }
            else
            {
                var message = "未知错误";
                if (root.TryGetProperty("error", out var err)
                    && err.TryGetProperty("message", out var msgEl)
                    && msgEl.ValueKind == JsonValueKind.String)
                    message = msgEl.GetString() ?? message;
                tcs.TrySetException(new InvalidOperationException($"OpenClaw Gateway 拒绝请求：{message}"));
            }
        }

        private void HandleEvent(JsonElement root)
        {
            if (!root.TryGetProperty("event", out var eventEl)) return;
            var eventName = eventEl.GetString();
            var payload = root.TryGetProperty("payload", out var payloadEl)
                ? payloadEl
                : default;

            if (eventName == "connect.challenge")
            {
                _challenge?.TrySetResult();
                return;
            }

            if (payload.ValueKind != JsonValueKind.Object)
                return;

            if (!IsCurrentSession(payload)) return;

            switch (eventName)
            {
                case "agent":
                    HandleAgentEvent(payload);
                    break;
                case "chat":
                    HandleChatEvent(payload);
                    break;
                case "session.message":
                    HandleSessionMessage(payload);
                    break;
                case "sessions.changed":
                    HandleSessionChanged(payload);
                    break;
                case "session.tool":
                case "session.operation":
                    Publish(_renderer.AddOperationalEvent(eventName, payload), "");
                    break;
            }
        }

        private bool IsCurrentSession(JsonElement payload)
        {
            if (payload.ValueKind != JsonValueKind.Object)
                return true;
            if (!payload.TryGetProperty("sessionKey", out var keyEl) || keyEl.ValueKind != JsonValueKind.String)
                return true;
            var key = keyEl.GetString();
            return key == _sessionKey || key == $"agent:main:{_sessionKey}";
        }

        private void HandleAgentEvent(JsonElement payload)
        {
            if (!IsCurrentRun(payload)) return;
            if (!payload.TryGetProperty("stream", out var streamEl) || streamEl.ValueKind != JsonValueKind.String)
                return;
            var stream = streamEl.GetString() ?? "";
            var data = payload.TryGetProperty("data", out var dataEl) ? dataEl : default;

            if (stream == "assistant"
                && data.ValueKind == JsonValueKind.Object
                && data.TryGetProperty("text", out var textEl)
                && textEl.ValueKind == JsonValueKind.String)
            {
                var chunk = textEl.GetString() ?? "";
                Publish(_renderer.UpdateAssistantDelta(chunk), chunk);
                return;
            }

            Publish(_renderer.AddAgentProgress(stream, data), "");
        }

        private void HandleChatEvent(JsonElement payload)
        {
            if (!IsCurrentRun(payload)) return;
            if (payload.TryGetProperty("deltaText", out var deltaEl) && deltaEl.ValueKind == JsonValueKind.String)
            {
                var chunk = deltaEl.GetString() ?? "";
                Publish(_renderer.UpdateAssistantDelta(chunk), chunk);
            }
            if (payload.TryGetProperty("state", out var stateEl)
                && stateEl.GetString() == "final")
                Complete(_renderer.RenderFinal());
        }

        private void HandleSessionMessage(JsonElement payload)
        {
            if (!payload.TryGetProperty("message", out var message)) return;
            int? fallbackSeq = null;
            if (payload.TryGetProperty("messageSeq", out var seqEl) && seqEl.TryGetInt32(out var seq))
                fallbackSeq = seq;
            Publish(_renderer.AddSessionMessage(message, fallbackSeq), "");
        }

        private void HandleSessionChanged(JsonElement payload)
        {
            var hasRunId = payload.TryGetProperty("runId", out var runIdEl) && runIdEl.ValueKind == JsonValueKind.String;
            if (hasRunId && !IsCurrentRun(payload)) return;
            if (payload.TryGetProperty("phase", out var phaseEl))
            {
                if (phaseEl.GetString() == "start")
                    Publish(_renderer.AddProgress("任务开始执行"), "");
                else if (phaseEl.GetString() == "end")
                    Complete(_renderer.RenderFinal());
            }
            if (hasRunId
                && payload.TryGetProperty("status", out var statusEl)
                && statusEl.GetString() == "aborted")
                Complete("OpenClaw 当前任务已中断");
        }

        private bool IsCurrentRun(JsonElement payload)
        {
            if (string.IsNullOrEmpty(_runId)) return true;
            if (payload.ValueKind != JsonValueKind.Object) return true;
            if (!payload.TryGetProperty("runId", out var runIdEl) || runIdEl.ValueKind != JsonValueKind.String)
                return true;
            return runIdEl.GetString() == _runId;
        }

        private void Publish(string? rendered, string chunk)
        {
            if (string.IsNullOrWhiteSpace(rendered)) return;
            _onEvent?.Invoke(new GatewayAgentEvent
            {
                Type = GatewayAgentEvent.EventType.Text,
                Content = chunk,
                Accumulated = rendered
            });
        }

        private void Complete(string text)
        {
            if (_completed) return;
            _completed = true;
            var finalText = string.IsNullOrWhiteSpace(text) ? "（OpenClaw 未返回内容）" : text.Trim();
            _completion?.TrySetResult(finalText);
        }

        private void FailAll(Exception ex)
        {
            _challenge?.TrySetException(ex);
            lock (_gate)
            {
                foreach (var pending in _pendingResponses.Values)
                    pending.TrySetException(ex);
                _pendingResponses.Clear();
            }
            _completion?.TrySetException(ex);
        }

        private static async Task<T> WaitWithTimeoutAsync<T>(Task<T> task, TimeSpan timeout, CancellationToken cancellationToken)
        {
            var delay = Task.Delay(timeout, cancellationToken);
            var winner = await Task.WhenAny(task, delay);
            if (winner == delay) throw new TimeoutException("OpenClaw 请求超时");
            return await task;
        }

        private static async Task WaitWithTimeoutAsync(Task task, TimeSpan timeout, CancellationToken cancellationToken)
        {
            var delay = Task.Delay(timeout, cancellationToken);
            var winner = await Task.WhenAny(task, delay);
            if (winner == delay) throw new TimeoutException("OpenClaw 请求超时");
            await task;
        }

        public async ValueTask DisposeAsync()
        {
            try
            {
                if (_socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
                    await _socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "client closed", CancellationToken.None);
            }
            catch
            {
                // best effort
            }
            _socket.Dispose();
        }
    }

    private sealed class OpenClawLiveTranscriptRenderer
    {
        private readonly int _baselineSeq;
        private readonly Dictionary<int, OpenClawTranscriptMessage> _messagesBySeq = new();
        private readonly List<string> _progressLines = new();
        private readonly HashSet<string> _progressSet = new();
        private string _assistantDraft = "";

        public OpenClawLiveTranscriptRenderer(int baselineSeq)
        {
            _baselineSeq = baselineSeq;
        }

        public string? AddProgress(string text)
        {
            var clean = text.Trim();
            if (clean.Length == 0 || _progressSet.Contains(clean)) return null;
            _progressSet.Add(clean);
            _progressLines.Add(clean);
            return Render();
        }

        public string? AddAgentProgress(string stream, JsonElement data)
        {
            if (stream is "codex_app_server.lifecycle" or "lifecycle")
            {
                if (data.ValueKind != JsonValueKind.Object || !data.TryGetProperty("phase", out var phaseEl)) return null;
                return phaseEl.GetString() switch
                {
                    "startup" => AddProgress("正在启动 OpenClaw 执行环境"),
                    "thread_ready" => AddProgress("会话已就绪"),
                    "turn_starting" => AddProgress("开始执行用户任务"),
                    "start" => AddProgress("任务开始执行"),
                    "end" => AddProgress("任务执行完成"),
                    var phase when !string.IsNullOrWhiteSpace(phase) => AddProgress($"OpenClaw：{phase}"),
                    _ => null
                };
            }

            if (stream == "codex_app_server.item")
            {
                if (data.ValueKind != JsonValueKind.Object) return null;
                var phase = data.TryGetProperty("phase", out var phaseEl) ? phaseEl.GetString() ?? "" : "";
                var type = data.TryGetProperty("type", out var typeEl) ? typeEl.GetString() ?? "item" : "item";
                return (phase, type) switch
                {
                    (_, "userMessage") => null,
                    ("started", "reasoning") => AddProgress("OpenClaw 正在分析任务"),
                    ("completed", "reasoning") => AddProgress("OpenClaw 分析完成"),
                    ("started", "toolCall") => AddProgress("开始调用工具"),
                    ("completed", "toolCall") => AddProgress("工具调用完成"),
                    ("started", "commandExecution") => AddProgress("开始执行命令"),
                    ("completed", "commandExecution") => AddProgress("命令执行完成"),
                    ("started", "agentMessage") => AddProgress("OpenClaw 正在生成回复"),
                    ("completed", "agentMessage") => AddProgress("OpenClaw 回复已生成"),
                    _ when !string.IsNullOrEmpty(phase) => AddProgress($"{ReadableItemType(type)}：{ReadablePhase(phase)}"),
                    _ => null
                };
            }

            return null;
        }

        public string? AddOperationalEvent(string eventName, JsonElement payload)
        {
            if (eventName == "session.tool")
            {
                var name = TryGetString(payload, "name") ?? TryGetString(payload, "tool") ?? "工具";
                return AddProgress($"工具：{name}");
            }
            if (eventName == "session.operation")
            {
                var name = TryGetString(payload, "name") ?? TryGetString(payload, "operation") ?? "操作";
                return AddProgress($"操作：{name}");
            }
            return null;
        }

        public string? UpdateAssistantDelta(string text)
        {
            _assistantDraft += text;
            return Render();
        }

        public string? AddSessionMessage(JsonElement row, int? fallbackSeq)
        {
            if (!TryGetMessageSeq(row, fallbackSeq, out var seq) || seq <= _baselineSeq) return null;
            var role = TryGetString(row, "role") ?? "message";
            var content = row.TryGetProperty("content", out var contentEl)
                ? contentEl
                : row.TryGetProperty("text", out var textEl) ? textEl : default;
            var message = new OpenClawTranscriptMessage(role, ExtractMessageText(content), seq);
            if (!ShouldDisplayMessage(message)) return null;
            _messagesBySeq[seq] = message;
            if (message.Role == "assistant" && !string.IsNullOrWhiteSpace(message.Text))
                _assistantDraft = "";
            return Render();
        }

        public string RenderFinal() => Render() ?? "";

        private string? Render()
        {
            var sections = new List<string>();
            if (_progressLines.Count > 0)
                sections.Add("### 执行进度\n\n" + string.Join("\n", _progressLines.Select(line => "- " + line)));

            foreach (var message in _messagesBySeq.OrderBy(pair => pair.Key).Select(pair => pair.Value))
            {
                if (message.Role == "user" || string.IsNullOrWhiteSpace(message.Text)) continue;
                sections.Add($"### {TitleFor(message.Role)}\n\n{message.Text}");
            }

            if (!string.IsNullOrWhiteSpace(_assistantDraft))
                sections.Add("### OpenClaw\n\n" + _assistantDraft);

            var rendered = string.Join("\n\n---\n\n", sections).Trim();
            return rendered.Length == 0 ? null : rendered;
        }

        private static bool ShouldDisplayMessage(OpenClawTranscriptMessage message)
        {
            var text = message.Text.Trim();
            if (text.Length == 0) return false;
            if (text is "[toolCall] bash" or "[toolCall]") return false;
            if (message.Role == "toolCall") return false;
            return true;
        }

        private static string TitleFor(string role) => role switch
        {
            "assistant" => "OpenClaw",
            "tool" => "工具结果",
            "toolCall" => "工具调用",
            "toolResult" => "工具结果",
            _ => role
        };

        private static string ReadableItemType(string type) => type switch
        {
            "userMessage" => "用户指令",
            "reasoning" => "OpenClaw 分析",
            "agentMessage" => "OpenClaw 回复",
            "toolCall" => "工具调用",
            "toolResult" => "工具结果",
            "commandExecution" => "命令执行",
            _ => type
        };

        private static string ReadablePhase(string phase) => phase switch
        {
            "started" => "开始",
            "completed" => "完成",
            _ => phase
        };

        private static string? TryGetString(JsonElement element, string name)
        {
            return element.ValueKind == JsonValueKind.Object
                && element.TryGetProperty(name, out var value)
                && value.ValueKind == JsonValueKind.String
                    ? value.GetString()
                    : null;
        }
    }

    private sealed record OpenClawTranscriptMessage(string Role, string Text, int Seq);
}
