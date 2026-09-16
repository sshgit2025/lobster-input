using System.IO;
using System.Text.Json;

namespace LobsterInput.Services;

public static class TranscribeFastModeStore
{
    private static readonly string SettingsPath = Path.Combine(
        AppPaths.AppDataDir, "transcribe_fast_mode.json");

    public static bool IsEnabled
    {
        get => Load();
        set => Save(value);
    }

    private static bool Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return false;
            using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
            return doc.RootElement.TryGetProperty("enabled", out var val) && val.GetBoolean();
        }
        catch
        {
            return false;
        }
    }

    private static void Save(bool enabled)
    {
        var dir = Path.GetDirectoryName(SettingsPath)!;
        Directory.CreateDirectory(dir);
        File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new { enabled }));
    }
}
