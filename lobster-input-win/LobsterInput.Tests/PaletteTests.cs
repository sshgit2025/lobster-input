using System.Windows.Media;
using LobsterInput.Services;
using Xunit;

namespace LobsterInput.Tests;

public sealed class PaletteTests
{
    public static TheoryData<AppTheme, AppAccent, string, string, string, string> AccentSpecRows => new()
    {
        { AppTheme.Light, AppAccent.Mono, "#FF18181B", "#0F18181B", "#FFFFFFFF", "#2E18181B" },
        { AppTheme.Light, AppAccent.Sand, "#FF9C7D5B", "#1A9C7D5B", "#FFFFFFFF", "#389C7D5B" },
        { AppTheme.Light, AppAccent.Blue, "#FF2563EB", "#142563EB", "#FFFFFFFF", "#402563EB" },
        { AppTheme.Light, AppAccent.Orange, "#FFEA580C", "#14EA580C", "#FFFFFFFF", "#40EA580C" },
        { AppTheme.Light, AppAccent.Red, "#FFDC2626", "#14DC2626", "#FFFFFFFF", "#40DC2626" },
        { AppTheme.Light, AppAccent.Green, "#FF15803D", "#1415803D", "#FFFFFFFF", "#4015803D" },
        { AppTheme.Light, AppAccent.Purple, "#FF7C3AED", "#147C3AED", "#FFFFFFFF", "#407C3AED" },
        { AppTheme.Dark, AppAccent.Mono, "#FFFAFAFA", "#14FAFAFA", "#FF0E0E10", "#33FAFAFA" },
        { AppTheme.Dark, AppAccent.Sand, "#FFD4BA94", "#1FD4BA94", "#FF1A140D", "#47D4BA94" },
        { AppTheme.Dark, AppAccent.Blue, "#FF3B82F6", "#243B82F6", "#FF0E0E10", "#4D3B82F6" },
        { AppTheme.Dark, AppAccent.Orange, "#FFFB923C", "#24FB923C", "#FF0E0E10", "#4DFB923C" },
        { AppTheme.Dark, AppAccent.Red, "#FFF87171", "#24F87171", "#FF0E0E10", "#4DF87171" },
        { AppTheme.Dark, AppAccent.Green, "#FF4ADE80", "#244ADE80", "#FF0E0E10", "#4D4ADE80" },
        { AppTheme.Dark, AppAccent.Purple, "#FFA78BFA", "#24A78BFA", "#FF0E0E10", "#4DA78BFA" },
    };

    public static TheoryData<AppTheme, string, string, string, string> StateSpecRows => new()
    {
        { AppTheme.Light, "#FF16A34A", "#FFD97706", "#FFDC2626", "#FF2563EB" },
        { AppTheme.Dark, "#FF22C55E", "#FFF59E0B", "#FFEF4444", "#FF3B82F6" },
    };

    [Theory]
    [MemberData(nameof(AccentSpecRows))]
    public void AccentPaletteMatchesSpec(AppTheme theme, AppAccent accent, string accentHex, string softHex, string fgHex, string ringHex)
    {
        var palette = AccentPalette.For(theme, accent);

        Assert.Equal(accentHex, Hex(palette.Accent));
        Assert.Equal(softHex, Hex(palette.AccentSoft));
        Assert.Equal(fgHex, Hex(palette.AccentFg));
        Assert.Equal(ringHex, Hex(palette.AccentRing));
    }

    [Fact]
    public void SandNeutralOverridesOnlyApplyToSandAccent()
    {
        Assert.Null(AccentPalette.SandNeutralOverride(AppTheme.Light, AppAccent.Blue));

        var lightSand = AccentPalette.SandNeutralOverride(AppTheme.Light, AppAccent.Sand);
        var darkSand = AccentPalette.SandNeutralOverride(AppTheme.Dark, AppAccent.Sand);

        Assert.NotNull(lightSand);
        Assert.NotNull(darkSand);
        Assert.Equal("#FFF4EFE7", Hex(lightSand.Value.Bg));
        Assert.Equal("#FF2C2620", Hex(lightSand.Value.Fg));
        Assert.Equal("#FF14110D", Hex(darkSand.Value.Bg));
        Assert.Equal("#FFF1EBE0", Hex(darkSand.Value.Fg));
    }

    [Theory]
    [MemberData(nameof(StateSpecRows))]
    public void StatePaletteMatchesSpec(AppTheme theme, string successHex, string warningHex, string dangerHex, string infoHex)
    {
        var palette = AccentPalette.StateFor(theme);

        Assert.Equal(successHex, Hex(palette.Success));
        Assert.Equal(warningHex, Hex(palette.Warning));
        Assert.Equal(dangerHex, Hex(palette.Danger));
        Assert.Equal(infoHex, Hex(palette.Info));
    }

    private static string Hex(Color color) => color.ToString();
}
