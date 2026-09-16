using System.IO;
using System.Text.Json;
using LobsterInput.Services;
using Xunit;

namespace LobsterInput.Tests;

public sealed class ThemeManagerTests
{
    [Fact]
    public void ModeRemainsBidirectionallyCompatible()
    {
        WpfTestHost.Run(() =>
        {
            var manager = NewManager();
            var changes = new List<string>();
            manager.PropertyChanged += (_, e) => changes.Add(e.PropertyName!);

            manager.Mode = AppThemeMode.SandDark;

            Assert.Equal(AppTheme.Dark, manager.Theme);
            Assert.Equal(AppAccent.Sand, manager.Accent);
            Assert.Equal(AppThemeMode.SandDark, manager.Mode);
            Assert.Contains(nameof(ThemeManager.Theme), changes);
            Assert.Contains(nameof(ThemeManager.Accent), changes);
            Assert.Contains(nameof(ThemeManager.Mode), changes);

            changes.Clear();
            manager.Accent = AppAccent.Blue;

            Assert.Equal(AppAccent.Blue, manager.Accent);
            Assert.Equal(AppThemeMode.SandDark, manager.Mode);
            Assert.Contains(nameof(ThemeManager.Accent), changes);
            Assert.Contains(nameof(ThemeManager.Mode), changes);

            manager.Mode = AppThemeMode.SandLight;

            Assert.Equal(AppTheme.Light, manager.Theme);
            Assert.Equal(AppAccent.Blue, manager.Accent);
        });
    }

    [Fact]
    public void ModeGetterProjectsEveryThemeAccentCombination()
    {
        WpfTestHost.Run(() =>
        {
            var manager = NewManager();

            foreach (AppTheme theme in Enum.GetValues<AppTheme>())
            {
                foreach (AppAccent accent in Enum.GetValues<AppAccent>())
                {
                    manager.Theme = theme;
                    manager.Accent = accent;

                    var expectedMode = theme == AppTheme.Dark
                        ? AppThemeMode.SandDark
                        : AppThemeMode.SandLight;
                    Assert.Equal(expectedMode, manager.Mode);
                }
            }
        });
    }

    [Fact]
    public void LegacyThemeFileIsMigratedToNewShape()
    {
        var path = NewThemePath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{\"mode\":\"SandDark\"}");

        var manager = new ThemeManager(path);

        Assert.Equal(AppTheme.Dark, manager.Theme);
        Assert.Equal(AppAccent.Sand, manager.Accent);

        using var doc = JsonDocument.Parse(File.ReadAllText(path));
        Assert.Equal("dark", doc.RootElement.GetProperty("theme").GetString());
        Assert.Equal("sand", doc.RootElement.GetProperty("accent").GetString());
    }

    [Fact]
    public void NewThemeShapeAndMissingFileLoadCorrectly()
    {
        var path = NewThemePath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{\"theme\":\"light\",\"accent\":\"purple\"}");

        var manager = new ThemeManager(path);

        Assert.Equal(AppTheme.Light, manager.Theme);
        Assert.Equal(AppAccent.Purple, manager.Accent);

        var missing = new ThemeManager(NewThemePath());

        Assert.Equal(AppTheme.Light, missing.Theme);
        Assert.Equal(AppAccent.Sand, missing.Accent);
    }

    [Fact]
    public void InvalidThemeJsonFallsBackToDefaultWithoutRewriting()
    {
        var path = NewThemePath();
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "{not valid json");

        var manager = new ThemeManager(path);

        Assert.Equal(AppTheme.Light, manager.Theme);
        Assert.Equal(AppAccent.Sand, manager.Accent);
        Assert.Equal("{not valid json", File.ReadAllText(path));
    }

    private static ThemeManager NewManager() => new(NewThemePath());

    private static string NewThemePath() =>
        Path.Combine(Path.GetTempPath(), "LobsterInput.Tests", Guid.NewGuid().ToString("N"), "theme.json");
}
