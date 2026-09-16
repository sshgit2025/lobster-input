using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Timers;
using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Config;

namespace LobsterInput.Services;

public enum OpenClawStatus { Unknown, NotInstalled, InstalledServiceDown, Ready }

public enum OpenClawTaskEventType { Connecting, Started, Progress, Finished, Aborted, Error }

public sealed class OpenClawTaskEvent
{
    public OpenClawTaskEventType Type { get; init; }
    public string Text { get; init; } = "";
    public string? RunId { get; init; }
    public int? MessageSeq { get; init; }
}

public sealed partial class OpenClawManager : ObservableObject
{
    public static OpenClawManager Instance { get; } = new();

    [ObservableProperty]
    private OpenClawStatus _status = OpenClawStatus.Unknown;

    [ObservableProperty]
    private bool _isStartingGateway;

    // 用户口述“开启/关闭大虾”的 agent 会话开关；仅保存在当前客户端进程内。
    // 它不等同于首页 OpenClaw gateway 进程运行状态。
    [ObservableProperty]
    private bool _isAgentSessionActive;

    [ObservableProperty]
    private string _agentSessionKey = MakeAgentSessionKey();

    private readonly System.Timers.Timer _checkTimer;
    private CancellationTokenSource? _activeGatewayCts;
    private Guid? _activeGatewayRequestId;
    private string? _activeGatewayRunId;
    private DateTime _lastModelAuthPromptAtUtc = DateTime.MinValue;

    private static readonly string OpenClawHome =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".openclaw");

    private static readonly string ConfigFilePath =
        Path.Combine(OpenClawHome, "openclaw.json");

    private OpenClawManager()
    {
        // 周期探活仅用于让首页状态灯与后端上报字段保持大致新鲜；
        // 真正调用 OpenClaw 的路径（发送/中断）都会当场重新解析，不依赖这里的节拍。
        // 曾为 15s：高频探活叠加子进程 spawn 在系统资源紧张时会放大整机负载。
        _checkTimer = new System.Timers.Timer(60_000);
        _checkTimer.Elapsed += async (_, _) => await RefreshAsync();
        _checkTimer.AutoReset = true;
        _checkTimer.Start();

        _ = RefreshAsync();
    }

    public string? StatusString => Status switch
    {
        OpenClawStatus.NotInstalled => "not_installed",
        OpenClawStatus.InstalledServiceDown => "service_down",
        OpenClawStatus.Ready => "installed",
        _ => null
    };

    public bool AgentSessionActiveForRequest => IsAgentSessionActive;

    public void HandleSessionTipCode(string code)
    {
        switch (code)
        {
            case "OPENCLAW_SESSION_STARTED":
                if (!IsAgentSessionActive)
                    ResetAgentSessionKey();
                IsAgentSessionActive = true;
                break;
            case "OPENCLAW_NEW_SESSION_STARTED":
                ResetAgentSessionKey();
                IsAgentSessionActive = true;
                break;
            case "OPENCLAW_ALREADY_ACTIVE":
                IsAgentSessionActive = true;
                break;
            case "OPENCLAW_SESSION_ENDED":
            case "OPENCLAW_NOT_INSTALLED":
            case "OPENCLAW_SERVICE_DOWN":
                IsAgentSessionActive = false;
                break;
        }
    }

    public event Action<OpenClawTaskEvent>? TaskEvent;

    public async Task RefreshAsync()
    {
        var installed = await IsInstalledAsync();
        if (!installed)
        {
            Status = OpenClawStatus.NotInstalled;
            IsAgentSessionActive = false;
            return;
        }

        var running = await IsGatewayRunningAsync();
        Status = running ? OpenClawStatus.Ready : OpenClawStatus.InstalledServiceDown;
        if (Status != OpenClawStatus.Ready)
            IsAgentSessionActive = false;
    }

    public async Task InstallAsync()
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoExit -Command \"irm https://openclaw.ai/install.ps1 | iex\"",
            UseShellExecute = true
        };
        Process.Start(psi);

        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(15_000);
            var wasNotInstalled = Status == OpenClawStatus.NotInstalled;
            await RefreshAsync();
            if (wasNotInstalled && Status != OpenClawStatus.NotInstalled)
            {
                EnsureGatewayModeConfigured();
                break;
            }
        }
    }

    public async Task UninstallAsync()
    {
        RunInTerminal("openclaw gateway stop --json & openclaw uninstall --all --yes --non-interactive & npm rm -g openclaw 2>nul & echo --- OpenClaw uninstalled ---");

        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(3_000);
            await RefreshAsync();
            if (Status == OpenClawStatus.NotInstalled) break;
        }
    }

    public async Task StartGatewayAsync()
    {
        if (IsStartingGateway) return;
        IsStartingGateway = true;

        try
        {
            if (await IsGatewayRunningAsync())
            {
                await RefreshAsync();
                await PromptForMissingModelAuthAsync();
                return;
            }

            EnsureGatewayModeConfigured();
            var binaryPath = await ResolveBinaryPathSlowAsync();
            if (string.IsNullOrEmpty(binaryPath))
            {
                await RefreshAsync();
                return;
            }

            using var startDoc = await RunOpenClawJsonAsync(
                binaryPath,
                new[] { "gateway", "start", "--json" },
                TimeSpan.FromSeconds(20));

            if (await WaitForGatewayReadyAsync(TimeSpan.FromSeconds(30)))
            {
                await RefreshAsync();
                await PromptForMissingModelAuthAsync();
                return;
            }

            if (ShouldInstallGateway(startDoc?.RootElement) || GatewayLogContainsModeError())
            {
                EnsureGatewayModeConfigured();
                await InstallGatewayServiceAsync(binaryPath);
            }
            else
            {
                await RestartGatewayServiceAsync(binaryPath);
            }

            if (!await WaitForGatewayReadyAsync(TimeSpan.FromSeconds(45)))
                RunInTerminal("openclaw gateway install --force --json & openclaw gateway restart --json & openclaw gateway status --json --require-rpc");

            await RefreshAsync();
            await PromptForMissingModelAuthAsync();
        }
        finally
        {
            IsStartingGateway = false;
        }
    }

    public async Task StopGatewayAsync()
    {
        IsAgentSessionActive = false;
        ResetAgentSessionKey();
        RunInTerminal("openclaw gateway stop --json");
        await Task.Delay(3_000);
        await RefreshAsync();
    }

    public void SendToOpenClaw(
        string text,
        string? selectedText = null,
        List<ClipboardContextItem>? clipboardItems = null,
        Action<string>? onComplete = null)
    {
        var message = BuildOpenClawMessage(text, selectedText, clipboardItems);
        var attachments = BuildOpenClawAttachments(clipboardItems);
        _ = SendViaGatewayAsync(message, attachments, onComplete);
    }

    public void SendCommandToOpenClaw(string text, Action<string>? onComplete = null)
    {
        var trimmed = text.Trim();
        if (string.IsNullOrEmpty(trimmed)) return;

        if (IsAbortCommand(trimmed))
        {
            _ = AbortOpenClawTaskAsync(onComplete);
        }
        else if (trimmed.StartsWith("/"))
        {
            _ = SendViaGatewayAsync(trimmed, null, onComplete);
        }
        else if (IsInteractiveCommand(trimmed))
        {
            RunInTerminal(trimmed);
        }
        else
        {
            RunInTerminal($"openclaw {trimmed}");
        }
    }

    public Dictionary<string, string> DiagnosticSnapshot()
    {
        var credential = ReadGatewayCredential();
        var binaryPath = FastResolveBinaryPath() ?? "";
        return new Dictionary<string, string>
        {
            ["configExists"] = Directory.Exists(OpenClawHome) ? "true" : "false",
            ["binaryFound"] = string.IsNullOrEmpty(binaryPath) ? "false" : "true",
            ["binaryPath"] = string.IsNullOrEmpty(binaryPath) ? "not_found" : binaryPath,
            ["credentialMode"] = credential?.Mode ?? "missing",
            ["credentialExists"] = credential == null ? "false" : "true",
            ["gatewayURL"] = ApiConfig.OpenClaw.GatewayBase,
            ["status"] = StatusString ?? "unknown",
            ["agentSessionActive"] = AgentSessionActiveForRequest ? "true" : "false",
            ["agentSessionKey"] = AgentSessionKey
        };
    }

    private static async Task<bool> IsInstalledAsync()
    {
        if (!Directory.Exists(OpenClawHome)) return false;
        return await ResolveBinaryPathSlowAsync() != null;
    }

    private static async Task<bool> IsGatewayRunningAsync()
    {
        var binaryPath = await ResolveBinaryPathSlowAsync();
        if (string.IsNullOrEmpty(binaryPath)) return false;
        using var doc = await RunOpenClawJsonAsync(
            binaryPath,
            new[] { "gateway", "status", "--json", "--require-rpc" },
            TimeSpan.FromSeconds(12));
        if (doc == null) return false;
        var root = doc.RootElement;
        return root.TryGetProperty("rpc", out var rpc)
            && rpc.TryGetProperty("ok", out var ok)
            && ok.ValueKind == JsonValueKind.True;
    }

    private async Task<bool> WaitForGatewayReadyAsync(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (await IsGatewayRunningAsync())
                return true;
            await Task.Delay(3_000);
        }
        return false;
    }

    private static async Task InstallGatewayServiceAsync(string binaryPath)
    {
        using var installDoc = await RunOpenClawJsonAsync(
            binaryPath,
            new[] { "gateway", "install", "--force", "--json" },
            TimeSpan.FromSeconds(45));
        if (installDoc == null)
        {
            using var _ = await RunOpenClawJsonAsync(
                binaryPath,
                new[] { "gateway", "install", "--json" },
                TimeSpan.FromSeconds(45));
        }
        await RestartGatewayServiceAsync(binaryPath);
    }

    private static async Task RestartGatewayServiceAsync(string binaryPath)
    {
        using var restartDoc = await RunOpenClawJsonAsync(
            binaryPath,
            new[] { "gateway", "restart", "--json" },
            TimeSpan.FromSeconds(30));
        if (restartDoc == null)
        {
            using var _ = await RunOpenClawJsonAsync(
                binaryPath,
                new[] { "gateway", "start", "--json" },
                TimeSpan.FromSeconds(30));
        }
    }

    private static bool ShouldInstallGateway(JsonElement? root)
    {
        if (root == null) return false;

        if (root.Value.TryGetProperty("result", out var result)
            && string.Equals(result.GetString(), "not-loaded", StringComparison.OrdinalIgnoreCase))
            return true;

        if (root.Value.TryGetProperty("message", out var message)
            && (message.GetString() ?? "").Contains("service missing", StringComparison.OrdinalIgnoreCase))
            return true;

        if (root.Value.TryGetProperty("service", out var service))
        {
            if (service.TryGetProperty("loaded", out var loaded) && loaded.ValueKind == JsonValueKind.False)
            {
                var notLoadedText = service.TryGetProperty("notLoadedText", out var text)
                    ? text.GetString()
                    : "";
                if (string.Equals(notLoadedText, "missing", StringComparison.OrdinalIgnoreCase))
                    return true;
            }

            if (HasMissingGatewayUnit(service))
                return true;
        }

        if (HasMissingGatewayUnit(root.Value))
            return true;

        return false;
    }

    private static bool HasMissingGatewayUnit(JsonElement root)
    {
        return root.TryGetProperty("runtime", out var runtime)
            && runtime.TryGetProperty("missingUnit", out var missingUnit)
            && missingUnit.ValueKind == JsonValueKind.True;
    }

    private async Task PromptForMissingModelAuthAsync()
    {
        var binaryPath = await ResolveBinaryPathSlowAsync();
        if (string.IsNullOrEmpty(binaryPath)) return;
        if (!await IsOpenAiModelAuthMissingAsync(binaryPath)) return;

        var now = DateTime.UtcNow;
        if (now - _lastModelAuthPromptAtUtc < TimeSpan.FromMinutes(5)) return;
        _lastModelAuthPromptAtUtc = now;

        RunInTerminal("openclaw models auth login --provider openai || openclaw models auth add");
    }

    private static async Task<bool> IsOpenAiModelAuthMissingAsync(string binaryPath)
    {
        using var doc = await RunOpenClawJsonAsync(
            binaryPath,
            new[] { "models", "status", "--json" },
            TimeSpan.FromSeconds(12));
        if (doc == null) return false;

        var root = doc.RootElement;
        if (!ModelUsesOpenAi(root)) return false;
        if (!root.TryGetProperty("auth", out var auth)) return false;

        if (auth.TryGetProperty("missingProvidersInUse", out var missingProviders)
            && missingProviders.ValueKind == JsonValueKind.Array)
        {
            foreach (var provider in missingProviders.EnumerateArray())
            {
                if (string.Equals(provider.GetString(), "openai", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }

        if (auth.TryGetProperty("runtimeAuthRoutes", out var routes)
            && routes.ValueKind == JsonValueKind.Array)
        {
            foreach (var route in routes.EnumerateArray())
            {
                if (!route.TryGetProperty("provider", out var provider)
                    || !string.Equals(provider.GetString(), "openai", StringComparison.OrdinalIgnoreCase))
                    continue;

                if (route.TryGetProperty("status", out var status)
                    && string.Equals(status.GetString(), "missing", StringComparison.OrdinalIgnoreCase))
                    return true;

                if (route.TryGetProperty("effective", out var effective)
                    && effective.TryGetProperty("kind", out var kind)
                    && string.Equals(kind.GetString(), "missing", StringComparison.OrdinalIgnoreCase))
                    return true;
            }
        }

        return false;
    }

    private static bool ModelUsesOpenAi(JsonElement root)
    {
        return JsonStringStartsWith(root, "defaultModel", "openai/")
            || JsonStringStartsWith(root, "resolvedDefault", "openai/");
    }

    private static bool JsonStringStartsWith(JsonElement root, string propertyName, string prefix)
    {
        return root.TryGetProperty(propertyName, out var value)
            && value.ValueKind == JsonValueKind.String
            && (value.GetString() ?? "").StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }

    private GatewayCredential? ReadGatewayCredential()
    {
        if (!File.Exists(ConfigFilePath)) return null;

        try
        {
            var json = File.ReadAllText(ConfigFilePath);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            if (!root.TryGetProperty("gateway", out var gw)) return null;
            if (!gw.TryGetProperty("auth", out var auth)) return null;

            var mode = auth.TryGetProperty("mode", out var modeEl)
                ? modeEl.GetString() ?? "token"
                : "token";

            if (mode == "password"
                && auth.TryGetProperty("password", out var pwEl))
            {
                var pw = pwEl.GetString();
                if (!string.IsNullOrEmpty(pw))
                    return new GatewayCredential("password", pw);
            }

            if (auth.TryGetProperty("token", out var tokenEl))
            {
                var token = tokenEl.GetString();
                if (!string.IsNullOrEmpty(token))
                    return new GatewayCredential("token", token);
            }

            return null;
        }
        catch
        {
            return null;
        }
    }

    private async Task SendViaGatewayAsync(
        string message,
        List<Dictionary<string, object>>? attachments,
        Action<string>? onComplete)
    {
        _activeGatewayCts?.Cancel();
        _activeGatewayCts?.Dispose();
        _activeGatewayCts = new CancellationTokenSource();
        var requestId = Guid.NewGuid();
        var sessionKey = AgentSessionKey;
        _activeGatewayRequestId = requestId;
        _activeGatewayRunId = null;
        TaskEvent?.Invoke(new OpenClawTaskEvent
        {
            Type = OpenClawTaskEventType.Connecting,
            Text = "OpenClaw 已启动，正在连接任务..."
        });

        var binaryPath = await ResolveBinaryPathSlowAsync();
        if (string.IsNullOrEmpty(binaryPath))
        {
            Debug.WriteLine("[OpenClaw] No openclaw binary found");
            ClearGatewayTask(requestId);
            TaskEvent?.Invoke(new OpenClawTaskEvent
            {
                Type = OpenClawTaskEventType.Error,
                Text = "未找到 OpenClaw 命令，请确认 OpenClaw 已正确安装。"
            });
            return;
        }

        try
        {
            await OpenClawGatewayClient.Instance.SendAsync(
                message,
                attachments,
                binaryPath,
                sessionKey,
                evt =>
                {
                    if (_activeGatewayRequestId != requestId) return;
                    switch (evt.Type)
                    {
                        case GatewayAgentEvent.EventType.Started:
                            _activeGatewayRunId = evt.RunId;
                            TaskEvent?.Invoke(new OpenClawTaskEvent
                            {
                                Type = OpenClawTaskEventType.Started,
                                RunId = evt.RunId,
                                MessageSeq = evt.MessageSeq,
                                Text = "任务已开始，正在等待 OpenClaw 返回执行过程..."
                            });
                            break;
                        case GatewayAgentEvent.EventType.Text:
                            TaskEvent?.Invoke(new OpenClawTaskEvent
                            {
                                Type = OpenClawTaskEventType.Progress,
                                Text = evt.Accumulated
                            });
                            break;
                        case GatewayAgentEvent.EventType.Done:
                            TaskEvent?.Invoke(new OpenClawTaskEvent
                            {
                                Type = OpenClawTaskEventType.Finished,
                                Text = string.IsNullOrWhiteSpace(evt.Content) ? "（OpenClaw 未返回内容）" : evt.Content
                            });
                            onComplete?.Invoke(evt.Content);
                            break;
                        case GatewayAgentEvent.EventType.Error:
                            TaskEvent?.Invoke(new OpenClawTaskEvent
                            {
                                Type = OpenClawTaskEventType.Error,
                                Text = evt.Content
                            });
                            break;
                    }
                },
                _activeGatewayCts.Token);
            ClearGatewayTask(requestId);
        }
        catch (OperationCanceledException)
        {
            ClearGatewayTask(requestId);
        }
        catch (Exception ex)
        {
            ClearGatewayTask(requestId);
            TaskEvent?.Invoke(new OpenClawTaskEvent
            {
                Type = OpenClawTaskEventType.Error,
                Text = $"Gateway 请求失败：{ex.Message}\n请确认 gateway 已启动。"
            });
        }
    }

    private async Task AbortOpenClawTaskAsync(Action<string>? onComplete)
    {
        var binaryPath = await ResolveBinaryPathSlowAsync();
        if (string.IsNullOrEmpty(binaryPath))
        {
            const string message = "未找到 OpenClaw 命令，请确认 OpenClaw 已正确安装。";
            TaskEvent?.Invoke(new OpenClawTaskEvent { Type = OpenClawTaskEventType.Error, Text = message });
            onComplete?.Invoke(message);
            return;
        }

        try
        {
            var message = await OpenClawGatewayClient.Instance.AbortActiveSessionAsync(
                binaryPath,
                AgentSessionKey,
                _activeGatewayRunId);
            _activeGatewayCts?.Cancel();
            _activeGatewayCts?.Dispose();
            _activeGatewayCts = null;
            _activeGatewayRequestId = null;
            _activeGatewayRunId = null;
            TaskEvent?.Invoke(new OpenClawTaskEvent { Type = OpenClawTaskEventType.Aborted, Text = message });
            onComplete?.Invoke(message);
        }
        catch (Exception ex)
        {
            var message = $"OpenClaw 中断失败：{ex.Message}";
            TaskEvent?.Invoke(new OpenClawTaskEvent { Type = OpenClawTaskEventType.Error, Text = message });
            onComplete?.Invoke(message);
        }
    }

    public void AbortCurrentOpenClawTask()
    {
        _ = AbortOpenClawTaskAsync(null);
    }

    private void ClearGatewayTask(Guid requestId)
    {
        if (_activeGatewayRequestId != requestId) return;
        _activeGatewayCts?.Dispose();
        _activeGatewayCts = null;
        _activeGatewayRequestId = null;
        _activeGatewayRunId = null;
    }

    private static string MakeAgentSessionKey() => $"voiceinput:{Guid.NewGuid():N}";

    private void ResetAgentSessionKey()
    {
        var oldKey = AgentSessionKey;
        AgentSessionKey = MakeAgentSessionKey();
        _activeGatewayRunId = null;
        _ = CleanupSessionAsync(oldKey);
    }

    private async Task CleanupSessionAsync(string key)
    {
        var binaryPath = await ResolveBinaryPathSlowAsync();
        if (string.IsNullOrEmpty(binaryPath)) return;
        try
        {
            await OpenClawGatewayClient.Instance.DeleteSessionAsync(binaryPath, key);
        }
        catch
        {
            // best effort
        }
    }

    private static string BuildOpenClawMessage(
        string instruction,
        string? selectedText,
        List<ClipboardContextItem>? clipboardItems)
    {
        var blocks = new List<string>();

        if (!string.IsNullOrWhiteSpace(selectedText))
            blocks.Add($"[当前选中的文本]\n---\n{selectedText.Trim()}\n---");

        var clipboardTexts = clipboardItems?
            .Where(item => item.Kind == "text" && !string.IsNullOrWhiteSpace(item.Text))
            .Select(item => item.Text!.Trim())
            .ToList() ?? new List<string>();
        if (clipboardTexts.Count > 0)
            blocks.Add($"[剪贴板文本]\n---\n{string.Join("\n\n---\n\n", clipboardTexts)}\n---");

        var imageCount = clipboardItems?
            .Count(item => item.Kind == "image" && !string.IsNullOrWhiteSpace(item.DataUrl)) ?? 0;
        if (imageCount > 0)
            blocks.Add($"[剪贴板图片]\n已随本次请求附加 {imageCount} 张图片。");

        if (blocks.Count == 0) return instruction;
        blocks.Add(instruction);
        return string.Join("\n\n", blocks);
    }

    private static List<Dictionary<string, object>> BuildOpenClawAttachments(List<ClipboardContextItem>? clipboardItems)
    {
        var attachments = new List<Dictionary<string, object>>();
        if (clipboardItems is not { Count: > 0 }) return attachments;

        var index = 1;
        foreach (var item in clipboardItems)
        {
            if (item.Kind != "image" || string.IsNullOrWhiteSpace(item.DataUrl))
                continue;

            var mimeType = string.IsNullOrWhiteSpace(item.MimeType) ? "image/png" : item.MimeType!;
            attachments.Add(new Dictionary<string, object>
            {
                ["type"] = "image",
                ["mimeType"] = mimeType,
                ["fileName"] = $"clipboard-{index}.{(mimeType == "image/jpeg" ? "jpg" : "png")}",
                ["content"] = item.DataUrl!
            });
            index += 1;
        }
        return attachments;
    }

    private static bool IsInteractiveCommand(string command)
    {
        var patterns = new[]
        {
            "models auth add", "models auth setup-token", "models auth paste-token",
            "onboard", "configure", "setup",
            "models set ", "models set-image ", "models scan",
            "config set ", "config unset ",
            "channels login", "channels add"
        };

        var lower = command.ToLowerInvariant();
        foreach (var p in patterns)
        {
            if (lower.Contains(p)) return true;
        }
        return false;
    }

    private static bool IsAbortCommand(string command)
    {
        var lower = command.ToLowerInvariant();
        return lower is "stop" or "/stop" or "abort" or "/abort" or "cancel" or "/cancel";
    }

    private void EnsureGatewayModeConfigured()
    {
        if (!File.Exists(ConfigFilePath)) return;

        try
        {
            var json = File.ReadAllText(ConfigFilePath);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            var gateway = root.TryGetProperty("gateway", out var gw) ? gw : default;

            if (gateway.ValueKind == JsonValueKind.Undefined
                || !gateway.TryGetProperty("mode", out _))
            {
                RunSilent("openclaw config set gateway.mode local");
            }

        }
        catch
        {
            // config unreadable; skip
        }
    }

    private bool GatewayLogContainsModeError()
    {
        var logPath = Path.Combine(OpenClawHome, "logs", "gateway.err.log");
        if (!File.Exists(logPath)) return false;

        try
        {
            var content = File.ReadAllText(logPath);
            return content.Contains("gateway.mode=local (current: unset)");
        }
        catch
        {
            return false;
        }
    }

    // openclaw 二进制路径缓存。安装路径极少变化，每次使用前仅做 File.Exists 快速校验，
    // 失效（卸载/移动）时自动清空并由下一次慢速解析回填。
    private static string? _cachedBinaryPath;
    private static readonly object ResolveLock = new();
    private static Task<string?>? _slowResolveTask;

    /// <summary>快速解析（零子进程）：缓存 → 常见安装路径扫描。适用于同步调用点。</summary>
    private static string? FastResolveBinaryPath()
    {
        var cached = _cachedBinaryPath;
        if (cached != null && File.Exists(cached)) return cached;
        _cachedBinaryPath = null;

        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new[]
        {
            Path.Combine(userProfile, ".openclaw", "bin", "openclaw.exe"),
            Path.Combine(userProfile, ".local", "bin", "openclaw.exe"),
            Path.Combine(userProfile, "AppData", "Roaming", "npm", "openclaw.cmd"),
            Path.Combine(userProfile, ".volta", "bin", "openclaw.exe"),
            Path.Combine(userProfile, ".npm-global", "openclaw.cmd"),
        };

        foreach (var path in candidates)
        {
            if (File.Exists(path))
            {
                _cachedBinaryPath = path;
                return path;
            }
        }

        return null;
    }

    /// <summary>
    /// 完整解析：快速路径未命中时，在线程池上跑一次 `where openclaw` 兜底非常规安装位置。
    /// 子进程 spawn + WaitForExit 绝不允许在 UI 线程同步执行；并发调用合并为一个子进程。
    /// </summary>
    private static Task<string?> ResolveBinaryPathSlowAsync()
    {
        if (FastResolveBinaryPath() is { } fast)
            return Task.FromResult<string?>(fast);

        lock (ResolveLock)
        {
            _slowResolveTask ??= Task.Run(() =>
            {
                try
                {
                    var path = WhichBinary("openclaw");
                    if (path != null) _cachedBinaryPath = path;
                    return path;
                }
                finally
                {
                    lock (ResolveLock) { _slowResolveTask = null; }
                }
            });
            return _slowResolveTask;
        }
    }

    private static string? WhichBinary(string name)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/c where {name}",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var proc = Process.Start(psi);
            if (proc == null) return null;

            var output = proc.StandardOutput.ReadToEnd().Trim();
            proc.WaitForExit();

            if (proc.ExitCode != 0 || string.IsNullOrEmpty(output)) return null;

            var firstLine = output.Split('\n')[0].Trim();
            return File.Exists(firstLine) ? firstLine : null;
        }
        catch
        {
            return null;
        }
    }

    private static async Task<JsonDocument?> RunOpenClawJsonAsync(
        string binaryPath,
        IReadOnlyList<string> arguments,
        TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        var psi = CreateProcessStartInfo(binaryPath, arguments);

        try
        {
            using var proc = Process.Start(psi);
            if (proc == null) return null;

            var outputTask = proc.StandardOutput.ReadToEndAsync(cts.Token);
            await proc.WaitForExitAsync(cts.Token);

            var output = (await outputTask).Trim();
            return string.IsNullOrWhiteSpace(output) ? null : JsonDocument.Parse(output);
        }
        catch
        {
            return null;
        }
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

    private static string BuildPowerShellCommand(string binaryPath, IEnumerable<string> arguments)
    {
        var args = string.Join(", ", arguments.Select(PsQuote));
        var script = "$ErrorActionPreference='Stop'; "
            + "& " + PsQuote(binaryPath) + " @(" + args + "); "
            + "exit $LASTEXITCODE";
        return Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
    }

    private static string PsQuote(string value) => "'" + value.Replace("'", "''") + "'";

    private static void RunSilent(string command)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/c {command}",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[OpenClaw] RunSilent failed: {ex.Message}");
        }
    }

    private static void RunInTerminal(string command)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/k {command}",
                UseShellExecute = true
            };
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[OpenClaw] RunInTerminal failed: {ex.Message}");
        }
    }

    private record GatewayCredential(string Mode, string Value);
}
