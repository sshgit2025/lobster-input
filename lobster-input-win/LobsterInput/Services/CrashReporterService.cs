using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Threading;
using LobsterInput.Config;
using LobsterInput.Stores;

namespace LobsterInput.Services;

public class CrashReport
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;
    public string AppVersion { get; set; } = "";
    public string OsVersion { get; set; } = "";
    public string? ExceptionType { get; set; }
    public string? Message { get; set; }
    public string? StackTrace { get; set; }
    public bool Reported { get; set; }
}

public sealed class CrashReporterService
{
    private static readonly string ReportsDir = Path.Combine(
        AppPaths.AppDataDir, "CrashReports");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(10) };

    public static CrashReporterService Instance { get; } = new();

    private CrashReporterService()
    {
        Directory.CreateDirectory(ReportsDir);
    }

    public int UnreportedCount => LoadUnreported().Count;

    public void Install()
    {
        AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
        TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;

        if (Application.Current != null)
        {
            Application.Current.DispatcherUnhandledException += OnDispatcherUnhandledException;
        }

        Debug.WriteLine("[CrashReporter] Installed");
    }

    public async Task UploadUnreportedAsync()
    {
        var unreported = LoadUnreported();
        if (unreported.Count == 0) return;

        var token = AuthStore.Instance.Token;
        if (string.IsNullOrEmpty(token)) return;

        foreach (var report in unreported)
        {
            var body = BuildUploadBody(report);
            var json = JsonSerializer.Serialize(body, new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
            });

            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, ApiConfig.Logs.Report);
                request.Content = new StringContent(json, Encoding.UTF8, "application/json");
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                request.Headers.TryAddWithoutValidation("X-App-Variant", ApiConfig.AppVariant);
                request.Headers.TryAddWithoutValidation("X-Client-Platform", "windows");

                using var response = await _http.SendAsync(request);
                if (response.IsSuccessStatusCode)
                {
                    MarkReported(report.Id);
                    Debug.WriteLine($"[CrashReporter] Uploaded: {report.Id}");
                }
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[CrashReporter] Upload failed for {report.Id}: {ex.Message}");
            }
        }
    }

    private void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
    {
        var ex = e.ExceptionObject as Exception;
        SaveCrashReport(ex, "AppDomain.UnhandledException");
    }

    private void OnUnobservedTaskException(object? sender, UnobservedTaskExceptionEventArgs e)
    {
        SaveCrashReport(e.Exception?.InnerException ?? e.Exception, "TaskScheduler.UnobservedTaskException");
        e.SetObserved();
    }

    private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        SaveCrashReport(e.Exception, "Dispatcher.UnhandledException");
        e.Handled = true;
    }

    private void SaveCrashReport(Exception? ex, string source)
    {
        var report = new CrashReport
        {
            AppVersion = GetAppVersion(),
            OsVersion = GetOsVersion(),
            ExceptionType = ex?.GetType().FullName ?? source,
            Message = ex?.Message ?? "Unknown error",
            StackTrace = ex?.ToString()
        };

        WriteReport(report);
        Debug.WriteLine($"[CrashReporter] Saved crash: {report.Id} ({report.ExceptionType})");
    }

    private void WriteReport(CrashReport report)
    {
        try
        {
            var path = Path.Combine(ReportsDir, $"{report.Id}.json");
            var json = JsonSerializer.Serialize(report, JsonOptions);
            File.WriteAllText(path, json);
            PruneOldReports();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[CrashReporter] WriteReport failed: {ex.Message}");
        }
    }

    private List<CrashReport> LoadUnreported()
    {
        return LoadAll().Where(r => !r.Reported).ToList();
    }

    private List<CrashReport> LoadAll()
    {
        if (!Directory.Exists(ReportsDir)) return [];

        var reports = new List<CrashReport>();
        foreach (var file in Directory.GetFiles(ReportsDir, "*.json"))
        {
            try
            {
                var json = File.ReadAllText(file);
                var report = JsonSerializer.Deserialize<CrashReport>(json, JsonOptions);
                if (report != null) reports.Add(report);
            }
            catch
            {
                // skip corrupted files
            }
        }

        return reports.OrderByDescending(r => r.Timestamp).ToList();
    }

    private void MarkReported(string id)
    {
        var path = Path.Combine(ReportsDir, $"{id}.json");
        if (!File.Exists(path)) return;

        try
        {
            var json = File.ReadAllText(path);
            var report = JsonSerializer.Deserialize<CrashReport>(json, JsonOptions);
            if (report == null) return;

            report.Reported = true;
            File.WriteAllText(path, JsonSerializer.Serialize(report, JsonOptions));
        }
        catch
        {
            // best-effort
        }
    }

    private void PruneOldReports()
    {
        try
        {
            var files = Directory.GetFiles(ReportsDir, "*.json")
                .Select(f => new FileInfo(f))
                .OrderBy(f => f.CreationTimeUtc)
                .ToList();

            if (files.Count <= 10) return;

            foreach (var file in files.Take(files.Count - 10))
            {
                file.Delete();
            }
        }
        catch
        {
            // best-effort
        }
    }

    private static object BuildUploadBody(CrashReport report)
    {
        return new
        {
            app_version = report.AppVersion,
            os_version = report.OsVersion,
            entries = new[]
            {
                new
                {
                    level = "fatal",
                    tag = "Crash",
                    message = $"[{report.ExceptionType}] {report.Message}",
                    extra = new Dictionary<string, string>
                    {
                        ["exceptionType"] = report.ExceptionType ?? "",
                        ["stackTrace"] = TruncateStackTrace(report.StackTrace),
                        ["appVersion"] = report.AppVersion,
                        ["osVersion"] = report.OsVersion
                    },
                    timestamp = report.Timestamp.ToString("o")
                }
            }
        };
    }

    private static string TruncateStackTrace(string? stackTrace)
    {
        if (string.IsNullOrEmpty(stackTrace)) return "";
        var lines = stackTrace.Split('\n');
        return string.Join("\n", lines.Take(30));
    }

    private static string GetAppVersion()
    {
        var ver = Assembly.GetEntryAssembly()?.GetName().Version;
        return ver != null ? ver.ToString(3) : "unknown";
    }

    private static string GetOsVersion()
    {
        var v = Environment.OSVersion.Version;
        return $"{v.Major}.{v.Minor}.{v.Build}";
    }
}
