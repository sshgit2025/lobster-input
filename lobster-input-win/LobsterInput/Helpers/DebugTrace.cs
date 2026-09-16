using System.Diagnostics;
using System.IO;

namespace LobsterInput.Helpers;

public static class DebugTrace
{
    private static readonly string LogDir = AppPaths.AppDataDir;

    private static readonly string LogPath = Path.Combine(LogDir, "debug.log");

    private static readonly object Lock = new();

    private const long MaxLogSize = 5 * 1024 * 1024;

    public static void Log(string message)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}";
        Debug.WriteLine(line);

        lock (Lock)
        {
            try
            {
                Directory.CreateDirectory(LogDir);
                RotateIfNeeded();
                File.AppendAllText(LogPath, line + Environment.NewLine);
            }
            catch
            {
                // best-effort file logging
            }
        }
    }

    public static void Log(string tag, string message)
    {
        Log($"[{tag}] {message}");
    }

    public static void LogError(string tag, Exception ex)
    {
        Log($"[{tag}] ERROR: {FormatException(ex)}");
    }

    private static string FormatException(Exception ex)
    {
        var parts = new List<string>();
        for (var current = ex; current != null; current = current.InnerException)
            parts.Add($"{current.GetType().Name}: {current.Message}");
        return string.Join(" <- ", parts);
    }

    private static void RotateIfNeeded()
    {
        try
        {
            if (!File.Exists(LogPath)) return;
            var info = new FileInfo(LogPath);
            if (info.Length <= MaxLogSize) return;

            var backup = LogPath + ".old";
            if (File.Exists(backup))
                File.Delete(backup);
            File.Move(LogPath, backup);
        }
        catch
        {
            // best-effort rotation
        }
    }
}
