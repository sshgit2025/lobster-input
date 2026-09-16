using System.Net.Http;
using System.Net.Http.Headers;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using LobsterInput.Config;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Stores;

namespace LobsterInput.Services;

public sealed class AudioProcessStreamCallbacks
{
    public Func<Task>? OnSearchStart { get; init; }
    public Func<string, Task>? OnSearchDelta { get; init; }
}

public sealed class ApiClient
{
    public static ApiClient Instance { get; } = new();

    private readonly HttpClient _http = new(new SocketsHttpHandler
    {
        PooledConnectionLifetime = TimeSpan.FromMinutes(2),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        ConnectTimeout = TimeSpan.FromSeconds(20),
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli
    })
    {
        Timeout = TimeSpan.FromSeconds(600)
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        Converters = { new ActionTypeConverter() }
    };

    private ApiClient() { }

    // ── Auth ──

    public async Task SendCodeAsync(string email)
    {
        await PostAsync<SendCodeRequest, MessageResponse>(
            ApiConfig.Auth.SendCode,
            new SendCodeRequest(email),
            requiresAuth: false);
    }

    public async Task<AuthResponse> VerifyAsync(string email, string code)
    {
        return await PostAsync<LoginRequest, AuthResponse>(
            ApiConfig.Auth.Verify,
            new LoginRequest(
                email,
                code,
                DeviceIdHelper.GetDeviceId(),
                DeviceIdHelper.GetHardwareFingerprint()),
            requiresAuth: false);
    }

    public async Task<AuthResponse> VerifyInviteAsync(
        string email, string inviteCode,
        string deviceId, string hardwareFingerprint)
    {
        return await PostAsync<VerifyInviteRequest, AuthResponse>(
            ApiConfig.Auth.VerifyInvite,
            new VerifyInviteRequest
            {
                Email = email,
                InviteCode = inviteCode,
                DeviceId = deviceId,
                HardwareFingerprint = hardwareFingerprint
            },
            requiresAuth: false);
    }

    /// 通知服务端注销当前会话（用户主动退出时调用）。
    /// 显式传入 token 而非读取 AuthStore，避免与本地登录态清理产生竞态。
    public async Task LogoutAsync(string token)
    {
        using var request = BuildRequest(ApiConfig.Auth.Logout, HttpMethod.Post, requiresAuth: false);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        await PerformAsync<EmptyResponse>(request);
    }

    public async Task<List<InviteCodeItem>> FetchMyInviteCodesAsync()
    {
        var resp = await GetAsync<MyInviteCodesResponse>(ApiConfig.Auth.InviteCodes);
        return resp.InviteCodes;
    }

    // ── Audio ──

    public async Task<AudioProcessResponse> ProcessAudioAsync(
        string filePath,
        string operation,
        string? selectedText = null,
        List<string>? clipboardHistory = null,
        List<ClipboardContextItem>? clipboardItems = null,
        string? openclawStatus = null,
        bool openclawSessionActive = false,
        bool fastMode = false)
    {
        using var content = BuildMultipartContent(
            filePath, operation, selectedText,
            clipboardHistory, clipboardItems, openclawStatus,
            openclawSessionActive,
            fastMode);

        using var request = BuildRequest(ApiConfig.Audio.Process, HttpMethod.Post);
        request.Content = content;

        return await PerformAsync<AudioProcessResponse>(request);
    }

    public async Task<AudioProcessResponse> ProcessAudioStreamAsync(
        string filePath,
        string operation,
        string? selectedText = null,
        List<string>? clipboardHistory = null,
        List<ClipboardContextItem>? clipboardItems = null,
        string? openclawStatus = null,
        bool openclawSessionActive = false,
        bool fastMode = false,
        AudioProcessStreamCallbacks? streamCallbacks = null)
    {
        using var content = BuildMultipartContent(
            filePath, operation, selectedText,
            clipboardHistory, clipboardItems, openclawStatus,
            openclawSessionActive,
            fastMode);

        using var request = BuildRequest(ApiConfig.Audio.ProcessStream, HttpMethod.Post);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Content = content;

        return await PerformAudioProcessStreamAsync(request, streamCallbacks);
    }

    public async Task<AudioProcessResponse> ProcessRealtimeTextAsync(
        string text,
        string clientAsrText,
        string asrSessionId,
        string operation,
        string? selectedText = null,
        List<string>? clipboardHistory = null,
        List<ClipboardContextItem>? clipboardItems = null,
        string? openclawStatus = null,
        bool openclawSessionActive = false,
        bool fastMode = false,
        string? transcriptLanguage = null)
    {
        var body = new TextProcessRequest
        {
            Operation = operation,
            Text = text,
            ClientAsrText = clientAsrText,
            AsrSessionId = asrSessionId,
            SelectedText = selectedText,
            ClipboardHistory = clipboardHistory,
            ClipboardItems = clipboardItems,
            OpenclawStatus = openclawStatus,
            OpenclawSessionActive = openclawSessionActive,
            FastMode = fastMode,
            TranscriptLanguage = transcriptLanguage
        };
        return await PostAsync<TextProcessRequest, AudioProcessResponse>(
            ApiConfig.AudioV2.ProcessText,
            body,
            connectionClose: true);
    }

    public async Task<AudioProcessResponse> ProcessRealtimeTextStreamAsync(
        string text,
        string clientAsrText,
        string asrSessionId,
        string operation,
        string? selectedText = null,
        List<string>? clipboardHistory = null,
        List<ClipboardContextItem>? clipboardItems = null,
        string? openclawStatus = null,
        bool openclawSessionActive = false,
        bool fastMode = false,
        string? transcriptLanguage = null,
        AudioProcessStreamCallbacks? streamCallbacks = null)
    {
        var body = new TextProcessRequest
        {
            Operation = operation,
            Text = text,
            ClientAsrText = clientAsrText,
            AsrSessionId = asrSessionId,
            SelectedText = selectedText,
            ClipboardHistory = clipboardHistory,
            ClipboardItems = clipboardItems,
            OpenclawStatus = openclawStatus,
            OpenclawSessionActive = openclawSessionActive,
            FastMode = fastMode,
            TranscriptLanguage = transcriptLanguage
        };
        using var request = BuildRequest(ApiConfig.AudioV2.ProcessTextStream, HttpMethod.Post);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));
        request.Content = new StringContent(
            JsonSerializer.Serialize(body, JsonOptions),
            Encoding.UTF8, "application/json");
        return await PerformAudioProcessStreamAsync(request, streamCallbacks);
    }

    // ── Config ──

    public async Task<AppStartupConfig> FetchStartupConfigAsync()
    {
        return await GetAsync<AppStartupConfig>(
            ApiConfig.Config.Startup, requiresAuth: false);
    }

    public async Task<UserPlanInfo> FetchUserPlanInfoAsync()
    {
        return await GetAsync<UserPlanInfo>(ApiConfig.Config.Plan);
    }

    public async Task<RecordingConfigResponse> FetchRecordingConfigAsync()
    {
        return await GetAsync<RecordingConfigResponse>(ApiConfig.Config.Recording);
    }

    // ── Payments ──

    public async Task<PaymentCatalogResponse> FetchPaymentCatalogAsync()
    {
        return await GetAsync<PaymentCatalogResponse>(ApiConfig.Payments.Catalog);
    }

    public async Task<PaymentCheckoutResponse> CreateSubscriptionCheckoutAsync(
        string provider,
        string productCode,
        string paymentMethod,
        string currency,
        string planCode,
        string billingCycle)
    {
        return await PostAsync<CreateSubscriptionCheckoutBody, PaymentCheckoutResponse>(
            ApiConfig.Payments.SubscriptionCheckout,
            new CreateSubscriptionCheckoutBody(
                planCode,
                billingCycle,
                true,
                provider,
                productCode,
                paymentMethod,
                currency,
                "full_price",
                ""));
    }

    /// 取消当前用户订阅自动续费（周期末生效）。
    /// status: cancelled / already_cancelled 均视为成功；apple_managed 表示需在订阅设备的应用商店中管理。
    public async Task<CancelRenewalResponse> CancelSubscriptionRenewalAsync()
    {
        return await PostAsync<EmptyJsonBody, CancelRenewalResponse>(
            ApiConfig.Subscription.CancelRenewal, new EmptyJsonBody());
    }

    public async Task<PaymentCheckoutResponse> CreateCreditsTopupCheckoutAsync(
        string provider,
        string productCode,
        string paymentMethod,
        string currency)
    {
        return await PostAsync<CreateCreditsTopupCheckoutBody, PaymentCheckoutResponse>(
            ApiConfig.Payments.CreditsTopupCheckout,
            new CreateCreditsTopupCheckoutBody(provider, productCode, paymentMethod, currency, ""));
    }

    public async Task SubmitFeedbackAsync(string content, string? phone, string? email)
    {
        await PostAsync<FeedbackSubmitRequest, MessageResponse>(
            ApiConfig.Feedback.Submit,
            new FeedbackSubmitRequest(
                content,
                phone,
                email,
                AppVersion,
                RuntimeInformation.OSDescription));
    }

    // ── HotWords ──

    public async Task<HotWordListResponse> ListHotWordsAsync(
        int page = 1, int pageSize = 50, string search = "")
    {
        var url = $"{ApiConfig.HotWords.List}?page={page}&page_size={pageSize}";
        if (!string.IsNullOrWhiteSpace(search))
            url += $"&search={Uri.EscapeDataString(search)}";
        return await GetAsync<HotWordListResponse>(url);
    }

    public async Task<HotWordItem> CreateHotWordAsync(string word)
    {
        return await PostAsync<HotWordCreateBody, HotWordItem>(
            ApiConfig.HotWords.List, new HotWordCreateBody(word));
    }

    public async Task<HotWordItem> UpdateHotWordAsync(string id, string word)
    {
        return await PutAsync<HotWordUpdateBody, HotWordItem>(
            ApiConfig.HotWords.Item(id), new HotWordUpdateBody(word));
    }

    public async Task DeleteHotWordAsync(string id)
    {
        await DeleteAsync<MessageResponse>(ApiConfig.HotWords.Item(id));
    }

    // ── Personas ──

    public async Task<List<PersonaItem>> ListPersonasAsync()
    {
        var resp = await GetAsync<PersonaListResponse>(ApiConfig.Personas.List);
        return resp.Personas;
    }

    public async Task<PersonaItem> CreatePersonaAsync(
        string name, string? description, PersonaPrompts prompts)
    {
        return await PostAsync<PersonaCreateBody, PersonaItem>(
            ApiConfig.Personas.List,
            new PersonaCreateBody
            {
                Name = name,
                Description = description,
                Prompts = prompts
            });
    }

    public async Task<PersonaItem> UpdatePersonaAsync(
        string id, string? name, string? description, PersonaPrompts? prompts)
    {
        return await PutAsync<PersonaUpdateBody, PersonaItem>(
            ApiConfig.Personas.Item(id),
            new PersonaUpdateBody
            {
                Name = name,
                Description = description,
                Prompts = prompts
            });
    }

    public async Task DeletePersonaAsync(string id)
    {
        await DeleteAsync<MessageResponse>(ApiConfig.Personas.Item(id));
    }

    public async Task<PersonaItem> ActivatePersonaAsync(string id)
    {
        return await PostEmptyAsync<PersonaItem>(ApiConfig.Personas.Activate(id));
    }

    public async Task DeactivateAllPersonasAsync()
    {
        await PostEmptyAsync<MessageResponse>(ApiConfig.Personas.DeactivateAll);
    }

    // ── Logs ──

    /// 上报日志条目（由 LogReporterService 调用，复用统一请求管道）
    public async Task UploadLogsAsync(LogReportBody body)
    {
        await PostAsync<LogReportBody, EmptyResponse>(ApiConfig.Logs.Report, body);
    }

    // ── Private: HTTP verb helpers ──

    private async Task<TResp> GetAsync<TResp>(string url, bool requiresAuth = true)
    {
        using var request = BuildRequest(url, HttpMethod.Get, requiresAuth);
        return await PerformAsync<TResp>(request);
    }

    private async Task<TResp> PostAsync<TBody, TResp>(
        string url,
        TBody body,
        bool requiresAuth = true,
        bool connectionClose = false)
    {
        using var request = BuildRequest(url, HttpMethod.Post, requiresAuth);
        request.Headers.ConnectionClose = connectionClose;
        request.Content = new StringContent(
            JsonSerializer.Serialize(body, JsonOptions),
            Encoding.UTF8, "application/json");
        return await PerformAsync<TResp>(request);
    }

    private async Task<TResp> PostEmptyAsync<TResp>(string url)
    {
        using var request = BuildRequest(url, HttpMethod.Post);
        return await PerformAsync<TResp>(request);
    }

    private async Task<TResp> PutAsync<TBody, TResp>(string url, TBody body)
    {
        using var request = BuildRequest(url, HttpMethod.Put);
        request.Content = new StringContent(
            JsonSerializer.Serialize(body, JsonOptions),
            Encoding.UTF8, "application/json");
        return await PerformAsync<TResp>(request);
    }

    private async Task<TResp> DeleteAsync<TResp>(string url)
    {
        using var request = BuildRequest(url, HttpMethod.Delete);
        return await PerformAsync<TResp>(request);
    }

    // ── Private: request builder ──

    private HttpRequestMessage BuildRequest(
        string url, HttpMethod method, bool requiresAuth = true)
    {
        var request = new HttpRequestMessage(method, url);
        request.Version = HttpVersion.Version11;
        request.VersionPolicy = HttpVersionPolicy.RequestVersionExact;

        if (requiresAuth)
        {
            var token = AuthStore.Instance.Token;
            if (!string.IsNullOrEmpty(token))
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }

        request.Headers.TryAddWithoutValidation("X-App-Variant", ApiConfig.AppVariant);
        request.Headers.TryAddWithoutValidation("X-Client-Platform", "windows");
        request.Headers.TryAddWithoutValidation("X-App-Version", AppVersion);
        request.Headers.TryAddWithoutValidation("X-OS-Version", RuntimeInformation.OSDescription);
        var languageCode = LanguageManager.GetLanguageCode(LanguageManager.Instance.Current);
        request.Headers.TryAddWithoutValidation("Accept-Language", languageCode);
        request.Headers.TryAddWithoutValidation("X-Accept-Language", languageCode);

        return request;
    }

    // ── Private: response handler ──

    private async Task<TResp> PerformAsync<TResp>(HttpRequestMessage request)
    {
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request);
        }
        catch (HttpRequestException ex)
        {
            DebugTrace.LogError("ApiClient.HttpRequest", ex);
            throw new ApiException(0, ex.Message);
        }

        using (response)
        {
            var bytes = await response.Content.ReadAsByteArrayAsync();
            var statusCode = (int)response.StatusCode;

            if (statusCode < 200 || statusCode >= 300)
            {
                var exception = BuildApiException(statusCode, bytes, "Unknown error");
                AuthSessionManager.InvalidateIfRequired(
                    exception,
                    $"{request.Method} {request.RequestUri?.AbsolutePath}");
                throw exception;
            }

            try
            {
                return JsonSerializer.Deserialize<TResp>(bytes, JsonOptions)!;
            }
            catch (JsonException ex)
            {
                throw new ApiException(0, $"JSON deserialization failed: {ex.Message}");
            }
        }
    }

    private async Task<AudioProcessResponse> PerformAudioProcessStreamAsync(
        HttpRequestMessage request,
        AudioProcessStreamCallbacks? streamCallbacks)
    {
        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
        }
        catch (HttpRequestException ex)
        {
            DebugTrace.LogError("ApiClient.HttpStreamRequest", ex);
            throw new ApiException(0, ex.Message);
        }

        using (response)
        {
            var statusCode = (int)response.StatusCode;
            if (statusCode < 200 || statusCode >= 300)
            {
                var bytes = await response.Content.ReadAsByteArrayAsync();
                var exception = BuildApiException(statusCode, bytes, "Stream request failed");
                AuthSessionManager.InvalidateIfRequired(
                    exception,
                    $"{request.Method} {request.RequestUri?.AbsolutePath}");
                throw exception;
            }

            await using var stream = await response.Content.ReadAsStreamAsync();
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var eventName = "";
            var dataLines = new List<string>();
            var searchStreamStarted = false;

            async Task<AudioProcessResponse?> ConsumeEventAsync()
            {
                if (string.IsNullOrEmpty(eventName) && dataLines.Count == 0)
                    return null;

                var currentEvent = eventName;
                var data = string.Join("\n", dataLines);
                eventName = "";
                dataLines.Clear();

                if (currentEvent == "search_start")
                {
                    searchStreamStarted = true;
                    if (streamCallbacks?.OnSearchStart != null)
                        await streamCallbacks.OnSearchStart();
                    return null;
                }
                if (currentEvent == "delta")
                {
                    if (!searchStreamStarted)
                    {
                        DebugTrace.Log("ApiClient", "Ignored stream delta before search_start");
                        return null;
                    }
                    if (streamCallbacks?.OnSearchDelta != null)
                    {
                        try
                        {
                            using var doc = JsonDocument.Parse(data);
                            if (doc.RootElement.TryGetProperty("text", out var textEl))
                            {
                                var text = textEl.GetString();
                                if (!string.IsNullOrEmpty(text))
                                    await streamCallbacks.OnSearchDelta(text);
                            }
                        }
                        catch (JsonException)
                        {
                            // Ignore malformed delta frames; the final frame still carries authoritative data.
                        }
                    }
                    return null;
                }
                if (currentEvent == "final")
                {
                    return DecodeAudioProcessResponse(data, "stream final");
                }
                if (currentEvent == "error")
                {
                    var message = "Stream request failed";
                    try
                    {
                        using var doc = JsonDocument.Parse(data);
                        if (doc.RootElement.TryGetProperty("message", out var msgEl))
                            message = msgEl.GetString() ?? message;
                    }
                    catch (JsonException) { }
                    throw new ApiException(statusCode, message);
                }
                return null;
            }

            while (await reader.ReadLineAsync() is { } line)
            {
                if (line.Length == 0)
                {
                    var final = await ConsumeEventAsync();
                    if (final != null)
                        return final;
                    continue;
                }
                if (line.StartsWith("event:", StringComparison.Ordinal))
                {
                    if (!string.IsNullOrEmpty(eventName) || dataLines.Count > 0)
                    {
                        var final = await ConsumeEventAsync();
                        if (final != null)
                            return final;
                    }
                    eventName = line["event:".Length..].Trim();
                }
                else if (line.StartsWith("data:", StringComparison.Ordinal))
                    dataLines.Add(line["data:".Length..].Trim());
            }

            var trailingFinal = await ConsumeEventAsync();
            if (trailingFinal != null)
                return trailingFinal;
            throw new ApiException(statusCode, "Stream response ended without final event");
        }
    }

    private static AudioProcessResponse DecodeAudioProcessResponse(string data, string context)
    {
        try
        {
            return JsonSerializer.Deserialize<AudioProcessResponse>(data, JsonOptions)
                   ?? throw new JsonException("Empty response");
        }
        catch (JsonException ex)
        {
            var snippet = data.Length <= 1200 ? data : data[..1200];
            DebugTrace.Log("ApiClient", $"{context} decode failed: {ex.Message}; payload={snippet}");
            throw new ApiException(0, $"JSON deserialization failed: {ex.Message}");
        }
    }

    private static ApiErrorResponse? TryParseError(byte[] data)
    {
        try { return JsonSerializer.Deserialize<ApiErrorResponse>(data, JsonOptions); }
        catch { return null; }
    }

    private static ApiException BuildApiException(int statusCode, byte[] bytes, string fallbackMessage)
    {
        var errResp = TryParseError(bytes);
        if (statusCode == 401)
            return new ApiException(statusCode, errResp?.Message ?? "Unauthorized", errResp);
        if (statusCode == 403 && errResp?.Code == "USER_BANNED")
            return new ApiException(statusCode, errResp.Message, errResp);
        return new ApiException(statusCode, errResp?.Message ?? fallbackMessage, errResp);
    }

    // ── Private: multipart builder ──

    private static MultipartFormDataContent BuildMultipartContent(
        string filePath,
        string operation,
        string? selectedText,
        List<string>? clipboardHistory,
        List<ClipboardContextItem>? clipboardItems,
        string? openclawStatus,
        bool openclawSessionActive,
        bool fastMode)
    {
        var content = new MultipartFormDataContent();
        selectedText = SanitizeText(selectedText);
        clipboardHistory = SanitizeTextList(clipboardHistory);
        clipboardItems = SanitizeClipboardItems(clipboardItems);

        DebugTrace.Log(
            "ApiClient.Audio",
            $"operation={operation}, selected={selectedText?.Length ?? 0}, clipboardHistory={clipboardHistory.Count}, clipboardItems={clipboardItems.Count}, fastMode={fastMode}");

        content.Add(new StringContent(operation), "operation");

        if (!string.IsNullOrEmpty(selectedText))
            content.Add(new StringContent(selectedText), "selected_text");

        if (clipboardHistory is { Count: > 0 })
        {
            var json = JsonSerializer.Serialize(clipboardHistory);
            content.Add(new StringContent(json), "clipboard_history");
        }

        if (clipboardItems is { Count: > 0 })
        {
            var json = JsonSerializer.Serialize(clipboardItems);
            content.Add(new StringContent(json), "clipboard_items");
        }

        if (!string.IsNullOrEmpty(openclawStatus))
            content.Add(new StringContent(openclawStatus), "openclaw_status");

        content.Add(new StringContent(openclawSessionActive ? "true" : "false"), "openclaw_session_active");

        if (fastMode)
            content.Add(new StringContent("true"), "fast_mode");

        var fileStream = File.OpenRead(filePath);
        var streamContent = new StreamContent(fileStream);
        streamContent.Headers.ContentType = new MediaTypeHeaderValue(
            MimeTypeFor(filePath));

        var fileName = Path.GetFileName(filePath);
        if (string.IsNullOrEmpty(fileName))
            fileName = "audio.m4a";

        content.Add(streamContent, "file", fileName);

        return content;
    }

    private static string MimeTypeFor(string path)
    {
        return Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".wav" => "audio/wav",
            ".flac" => "audio/flac",
            ".m4a" => "audio/m4a",
            _ => "application/octet-stream"
        };
    }

    private static string AppVersion =>
        Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.0.0";

    private static string? SanitizeText(string? text)
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
