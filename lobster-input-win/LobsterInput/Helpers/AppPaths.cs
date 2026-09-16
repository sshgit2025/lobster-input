namespace LobsterInput.Helpers;

public static class AppPaths
{
    public static string AppDataDir { get; } = BuildDataDir(
        Environment.SpecialFolder.ApplicationData,
        "APPDATA");

    public static string LocalAppDataDir { get; } = BuildDataDir(
        Environment.SpecialFolder.LocalApplicationData,
        "LOCALAPPDATA");

    private static string BuildDataDir(Environment.SpecialFolder folder, string envVar)
    {
        var baseDir = Environment.GetFolderPath(folder);

        if (string.IsNullOrWhiteSpace(baseDir))
            baseDir = Environment.GetEnvironmentVariable(envVar);

        if (string.IsNullOrWhiteSpace(baseDir))
        {
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!string.IsNullOrWhiteSpace(userProfile))
            {
                baseDir = envVar == "LOCALAPPDATA"
                    ? Path.Combine(userProfile, "AppData", "Local")
                    : Path.Combine(userProfile, "AppData", "Roaming");
            }
        }

        if (string.IsNullOrWhiteSpace(baseDir))
            baseDir = Path.Combine(Path.GetTempPath(), "LobsterInput");

        var appDir = Path.Combine(baseDir, "LobsterInput");
        Directory.CreateDirectory(appDir);
        return appDir;
    }
}
