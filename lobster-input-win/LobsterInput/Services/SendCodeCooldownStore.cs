using System;
using System.IO;
using System.Text.Json;

namespace LobsterInput.Services;

/// <summary>
/// 验证码发送冷却持久化：记录最近一次发码的邮箱与到期时间戳，
/// 退出 APP 重进后仍可依据剩余秒数恢复倒计时，避免人为绕过发送间隔限制。
/// </summary>
public static class SendCodeCooldownStore
{
    private static readonly string SettingsPath = Path.Combine(
        AppPaths.AppDataDir, "send_code_cooldown.json");

    private sealed class Record
    {
        public string Email { get; set; } = "";
        public long ExpiresAtUnix { get; set; }
    }

    /// <summary>记录一次成功发码，写入邮箱与冷却到期时间戳。</summary>
    public static void Mark(string email, int cooldownSeconds)
    {
        try
        {
            var dir = Path.GetDirectoryName(SettingsPath)!;
            Directory.CreateDirectory(dir);
            var record = new Record
            {
                Email = email,
                ExpiresAtUnix = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + cooldownSeconds,
            };
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(record));
        }
        catch
        {
            // 持久化失败不影响主流程
        }
    }

    /// <summary>返回指定邮箱当前剩余的发码冷却秒数（0 表示可再次发送）。</summary>
    public static int RemainingSeconds(string email)
    {
        try
        {
            if (string.IsNullOrEmpty(email) || !File.Exists(SettingsPath)) return 0;
            var record = JsonSerializer.Deserialize<Record>(File.ReadAllText(SettingsPath));
            if (record is null || !string.Equals(record.Email, email, StringComparison.OrdinalIgnoreCase))
                return 0;
            var remaining = record.ExpiresAtUnix - DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            return remaining > 0 ? (int)remaining : 0;
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>若最近发码邮箱仍在冷却期内，返回该邮箱，用于登录页预填并恢复倒计时。</summary>
    public static string? PendingEmail()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return null;
            var record = JsonSerializer.Deserialize<Record>(File.ReadAllText(SettingsPath));
            if (record is null) return null;
            var remaining = record.ExpiresAtUnix - DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            return remaining > 0 ? record.Email : null;
        }
        catch
        {
            return null;
        }
    }
}
