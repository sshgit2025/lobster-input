using System.Reflection;
using LobsterInput.Models;

namespace LobsterInput.Services;

/// <summary>
/// 客户端日志上报服务（单例）。
/// 将运行日志批量上报至后端，用于远程排查问题。
/// 仅在用户已登录时上报，未登录时日志只写本地缓冲区，登录后一次性刷新。
/// HTTP 上报由 ApiClient 统一处理，本类不持有任何 HttpClient。
/// </summary>
public sealed class LogReporterService
{
    public static LogReporterService Instance { get; } = new();

    private readonly object _lock = new();
    private readonly List<LogEntry> _buffer = [];
    private const int MaxBuffer = 200;

    private LogReporterService() { }

    public void Log(string level, string tag, string message,
        Dictionary<string, string>? extra = null)
    {
        var entry = new LogEntry
        {
            Level = level,
            Tag = tag,
            Message = message,
            Extra = extra,
            Timestamp = DateTime.UtcNow.ToString("o")
        };

        lock (_lock)
        {
            _buffer.Add(entry);
            if (_buffer.Count > MaxBuffer)
                _buffer.RemoveRange(0, _buffer.Count - MaxBuffer);
        }
    }

    public void Info(string tag, string message,
        Dictionary<string, string>? extra = null)
        => Log("info", tag, message, extra);

    public void Warn(string tag, string message,
        Dictionary<string, string>? extra = null)
        => Log("warn", tag, message, extra);

    public void Error(string tag, string message,
        Dictionary<string, string>? extra = null)
        => Log("error", tag, message, extra);

    public async Task ReportSnapshotAsync(string reason)
    {
        CollectSnapshot(reason);
        await FlushAsync();
    }

    public void CollectSnapshot(string reason)
    {
        var extra = new Dictionary<string, string>
        {
            ["appVersion"] = AppVersion(),
            ["osVersion"] = OsVersion(),
        };

        Log("info", "Snapshot", $"[{reason}] status snapshot", extra);
    }

    public async Task FlushAsync()
    {
        List<LogEntry> entries;
        lock (_lock)
        {
            if (_buffer.Count == 0) return;
            entries = new List<LogEntry>(_buffer);
            _buffer.Clear();
        }

        if (string.IsNullOrEmpty(Stores.AuthStore.Instance.Token))
        {
            Restore(entries);
            return;
        }

        var body = new LogReportBody
        {
            AppVersion = AppVersion(),
            OsVersion = OsVersion(),
            Entries = entries
        };

        try
        {
            await ApiClient.Instance.UploadLogsAsync(body);
        }
        catch
        {
            Restore(entries);
        }
    }

    private void Restore(List<LogEntry> entries)
    {
        lock (_lock)
        {
            _buffer.InsertRange(0, entries);
            if (_buffer.Count > MaxBuffer)
                _buffer.RemoveRange(MaxBuffer, _buffer.Count - MaxBuffer);
        }
    }

    private static string AppVersion()
    {
        var asm = Assembly.GetEntryAssembly();
        var ver = asm?.GetName().Version;
        return ver is not null ? ver.ToString(3) : "unknown";
    }

    private static string OsVersion()
    {
        var v = Environment.OSVersion.Version;
        return $"{v.Major}.{v.Minor}.{v.Build}";
    }
}
