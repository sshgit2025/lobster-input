using Microsoft.Win32;

namespace LobsterInput.Services;

public static class StartupLaunchService
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValueName = "LobsterInput";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            return key?.GetValue(RunValueName) is string value &&
                   !string.IsNullOrWhiteSpace(value);
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
            if (value)
            {
                key.SetValue(RunValueName, BuildLaunchCommand(), RegistryValueKind.String);
            }
            else
            {
                key.DeleteValue(RunValueName, throwOnMissingValue: false);
            }
        }
    }

    private static string BuildLaunchCommand()
    {
        var executablePath = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executablePath))
            return "";

        var updateExePath = ResolveVelopackUpdateExe(executablePath);
        return updateExePath is null
            ? Quote(executablePath)
            : $"{Quote(updateExePath)} start";
    }

    private static string? ResolveVelopackUpdateExe(string executablePath)
    {
        try
        {
            var executableDir = Path.GetDirectoryName(executablePath);
            if (string.IsNullOrWhiteSpace(executableDir))
                return null;

            var currentDir = new DirectoryInfo(executableDir);
            if (!string.Equals(currentDir.Name, "current", StringComparison.OrdinalIgnoreCase))
                return null;

            var updateExe = Path.Combine(currentDir.Parent?.FullName ?? "", "Update.exe");
            return File.Exists(updateExe) ? updateExe : null;
        }
        catch
        {
            return null;
        }
    }

    private static string Quote(string value) => $"\"{value}\"";
}
