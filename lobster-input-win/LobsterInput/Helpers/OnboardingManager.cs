using System.IO;
using System.Text.Json;
using LobsterInput.Stores;

namespace LobsterInput.Helpers;

public static class OnboardingManager
{
    private const string KeyPrefix = "onboarding_completed_";

    private static readonly string SettingsDir = AppPaths.AppDataDir;

    private static readonly string SettingsPath = Path.Combine(SettingsDir, "onboarding.json");

    public static bool IsCompleted
    {
        get => ReadFlag();
        set => WriteFlag(value);
    }

    public static void MarkCompleted()
    {
        IsCompleted = true;
    }

    public static void Reset()
    {
        IsCompleted = false;
    }

    private static bool ReadFlag()
    {
        try
        {
            if (!File.Exists(SettingsPath))
                return false;

            var json = File.ReadAllText(SettingsPath);
            var data = JsonSerializer.Deserialize<Dictionary<string, bool>>(json);
            if (data == null) return false;

            var key = StorageKey();
            if (key != null && data.TryGetValue(key, out var current))
                return current;

            return false;
        }
        catch
        {
            return false;
        }
    }

    private static void WriteFlag(bool value)
    {
        try
        {
            var key = StorageKey();
            if (key == null) return;

            var data = ReadData();
            data[key] = value;
            WriteData(data);
        }
        catch
        {
            // best-effort persistence
        }
    }

    private static string? StorageKey()
    {
        var email = AuthStore.Instance.Email;
        if (string.IsNullOrWhiteSpace(email)) return null;
        var raw = $"{email.Trim().ToLowerInvariant()}_{DeviceIdHelper.GetDeviceId()}";
        return KeyPrefix + Djb2Hash(raw);
    }

    private static Dictionary<string, bool> ReadData()
    {
        if (!File.Exists(SettingsPath)) return new Dictionary<string, bool>();
        var json = File.ReadAllText(SettingsPath);
        return JsonSerializer.Deserialize<Dictionary<string, bool>>(json)
               ?? new Dictionary<string, bool>();
    }

    private static void WriteData(Dictionary<string, bool> data)
    {
        Directory.CreateDirectory(SettingsDir);
        var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(SettingsPath, json);
    }

    private static string Djb2Hash(string value)
    {
        ulong hash = 5381;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(value))
            hash = ((hash << 5) + hash) + b;
        return hash.ToString("x");
    }
}
