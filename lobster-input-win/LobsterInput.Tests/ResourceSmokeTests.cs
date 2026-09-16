using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Shell;
using LobsterInput.Services;
using Xunit;
using File = System.IO.File;
using IOPath = System.IO.Path;

namespace LobsterInput.Tests;

public sealed class ResourceSmokeTests
{
    private static readonly string[] LegacyKeys =
    [
        "BgDeep", "BgDark", "BgPanel", "BgSidebar", "BgCard", "BgInput", "BgHover", "BgActive",
        "AccentColor", "AccentSoft", "AccentRing",
        "DangerColor", "WarningColor", "SuccessColor",
        "NeonGreen", "NeonCyan", "NeonPurple", "NeonRed", "NeonOrange", "NeonYellow",
        "TextBright", "TextDim", "TextGhost", "TextMuted", "BorderDim", "DividerColor",
        "CyberNeonCyanColor", "CyberNeonRedColor",
        "BgDeepBrush", "BgDarkBrush", "BgPanelBrush", "BgSidebarBrush", "BgCardBrush", "BgInputBrush", "BgHoverBrush", "BgActiveBrush",
        "AccentBrush", "AccentSoftBrush", "AccentRingBrush",
        "DangerBrush", "WarningBrush", "SuccessBrush",
        "NeonGreenBrush", "NeonCyanBrush", "NeonPurpleBrush", "NeonRedBrush", "NeonOrangeBrush", "NeonYellowBrush",
        "TextBrightBrush", "TextDimBrush", "TextGhostBrush", "TextMutedBrush", "BorderDimBrush", "DividerBrush",
        "CyberBgPrimary", "CyberTextPrimary", "CyberTextDim", "CyberTextGhost", "CyberNeonCyan", "CyberNeonGreen", "CyberNeonRed", "CyberNeonYellow"
    ];

    [Fact]
    public void DesignSystemResourcesSmoke()
    {
        WpfTestHost.Run(() =>
        {
            AssertTokenMatrix();
            AssertComponentStyles();
            AssertButtonVariantHoverTemplates();
            AssertLayoutShells();
            AssertWindowsChrome();
            AssertWindowsChromeCloseHoverTemplate();
            AssertStoryboards();
            AssertThemeMatrix();
            AssertLegacyAliasSingleSource();
        });

        var cyberTheme = File.ReadAllText(IOPath.Combine(SolutionRoot(), "LobsterInput", "Resources", "CyberTheme.xaml"));
        Assert.DoesNotContain("<Color", cyberTheme);
        Assert.DoesNotContain("<SolidColorBrush", cyberTheme);
    }

    private static void AssertTokenMatrix()
    {
        AssertResource<Color>("DsBgColor");
        AssertResource<SolidColorBrush>("DsBgBrush");
        AssertResource<DropShadowEffect>("DsShadowSmEffect");
        AssertResource<SolidColorBrush>("DsDangerSoftBrush");
        AssertResource<SolidColorBrush>("DsDangerRingBrush");
        AssertResource<SolidColorBrush>("DsDangerActiveBrush");
        AssertResource<CornerRadius>("RadiusMd");
        AssertResource<double>("FontSizePageTitle");
        AssertResource<FontWeight>("FontWeightSemiBold");
        AssertResource<FontFamily>("AppFont");
        AssertResource<Thickness>("Space16");
        AssertResource<IEasingFunction>("EaseStandard");
        AssertResource<Duration>("DurationHover");
    }

    private static void AssertComponentStyles()
    {
        AssertStyle<Button>("DsButtonDefaultStyle");
        AssertStyle<Button>("DsButtonPrimaryStyle");
        AssertStyle<TextBox>("DsInputTextBoxStyle");
        AssertStyle<TextBox>("DsTextAreaStyle");
        AssertStyle<Border>("DsKbdStyle");
        AssertStyle<Border>("DsCardStyle");
        AssertStyle<Border>("DsBadgeStyle");
        AssertStyle<CheckBox>("DsToggleCheckBoxStyle");
        AssertStyle<ComboBox>("DsSelectComboBoxStyle");
        AssertStyle<Button>("DsIconButtonStyle");
        AssertStyle<Button>("DsIconDangerHoverButtonStyle");
        AssertStyle<Ellipse>("DsStatusDotStyle");
        AssertStyle<Border>("DsStatusLightSuccessStyle");
        AssertStyle<DockPanel>("DsSectionHeadStyle");
        AssertStyle<Border>("DsDividerStyle");
        AssertStyle<Border>("DsFocusRingBorderStyle");
        AssertStyle<ScrollBar>("DsScrollBarStyle");
    }

    private static void AssertButtonVariantHoverTemplates()
    {
        var primaryHoverSetters = AssertHoverTriggerSetters(GetTemplate<Button>("DsButtonPrimaryStyle"));
        Assert.DoesNotContain(primaryHoverSetters, IsChromeHoverBackground);
        AssertSetter(primaryHoverSetters, "Chrome", UIElement.OpacityProperty, 0.9);

        var dangerHoverSetters = AssertHoverTriggerSetters(GetTemplate<Button>("DsButtonDangerStyle"));
        AssertSetterResource(dangerHoverSetters, "Chrome", Border.BackgroundProperty, "DsDangerSoftBrush");
        AssertSetterResource(dangerHoverSetters, "Chrome", Border.BorderBrushProperty, "DsDangerRingBrush");
        var dangerPressedSetters = AssertPressedTriggerSetters(GetTemplate<Button>("DsButtonDangerStyle"));
        AssertSetterResource(dangerPressedSetters, "Chrome", Border.BackgroundProperty, "DsDangerActiveBrush");

        var ghostDangerHoverSetters = AssertHoverTriggerSetters(GetTemplate<Button>("DsButtonGhostDangerStyle"));
        AssertSetterResource(ghostDangerHoverSetters, "Chrome", Border.BackgroundProperty, "DsDangerSoftBrush");
        AssertSetterResource(ghostDangerHoverSetters, null, Control.ForegroundProperty, "DsDangerBrush");
        var ghostDangerPressedSetters = AssertPressedTriggerSetters(GetTemplate<Button>("DsButtonGhostDangerStyle"));
        AssertSetterResource(ghostDangerPressedSetters, "Chrome", Border.BackgroundProperty, "DsDangerActiveBrush");
    }

    private static void AssertLayoutShells()
    {
        AssertContentShell("SidebarShellStyle");
        AssertContentShell("PageContainerShellStyle");
        AssertContentShell("ModalShellStyle");
        AssertContentShell("FloaterShellStyle");
        AssertContentShell("RecorderFloaterShellStyle");
        AssertContentShell("ResultFloaterShellStyle");
    }

    private static void AssertWindowsChrome()
    {
        var style = AssertStyle<Window>("WindowsChromeWindowStyle");
        var window = new Window { Style = style, Content = new Grid(), Width = 300, Height = 200 };
        window.ApplyTemplate();

        var minimize = Assert.IsType<Button>(window.Template.FindName("MinimizeButton", window));
        var maximize = Assert.IsType<Button>(window.Template.FindName("MaximizeButton", window));
        var close = Assert.IsType<Button>(window.Template.FindName("CloseButton", window));
        var chrome = WindowChrome.GetWindowChrome(window);

        Assert.NotNull(chrome);
        Assert.Equal(38, chrome.CaptionHeight);
        Assert.Equal(new Thickness(0), chrome.GlassFrameThickness);
        Assert.Equal(NonClientFrameEdges.None, chrome.NonClientFrameEdges);
        Assert.True(WindowChrome.GetIsHitTestVisibleInChrome(minimize));
        Assert.True(WindowChrome.GetIsHitTestVisibleInChrome(maximize));
        Assert.True(WindowChrome.GetIsHitTestVisibleInChrome(close));
    }

    private static void AssertWindowsChromeCloseHoverTemplate()
    {
        var hoverSetters = AssertHoverTriggerSetters(GetTemplate<Button>("WindowsChromeCloseButtonStyle"));

        AssertSetterColor(hoverSetters, "ButtonChrome", Border.BackgroundProperty, Color.FromRgb(0xE8, 0x11, 0x23));
        AssertSetter(hoverSetters, null, Control.ForegroundProperty, Brushes.White);
        Assert.DoesNotContain(hoverSetters, IsButtonChromeHoverBackground);
    }

    private static void AssertStoryboards()
    {
        foreach (var key in new[] { "FadeInStoryboard", "SlideUpStoryboard", "ScaleInStoryboard", "PulseStoryboard", "WaveStoryboard" })
        {
            var storyboard = AssertResource<Storyboard>(key).Clone();
            var target = new Border { Opacity = 0 };
            storyboard.Begin(target);
        }

        var spin = AssertResource<Storyboard>("SpinFullStoryboard").Clone();
        var rotatingTarget = new Border { RenderTransform = new RotateTransform(0) };
        spin.Begin(rotatingTarget);
    }

    private static void AssertThemeMatrix()
    {
        var manager = new ThemeManager(NewThemePath());

        foreach (AppTheme theme in Enum.GetValues<AppTheme>())
        {
            foreach (AppAccent accent in Enum.GetValues<AppAccent>())
            {
                manager.Theme = theme;
                manager.Accent = accent;
                manager.ApplyCurrentTheme();

                var expectedAccent = AccentPalette.For(theme, accent);
                var expectedNeutral = AccentPalette.NeutralFor(theme, accent);

                Assert.Equal(expectedAccent.Accent, AssertResource<Color>("DsAccentColor"));
                Assert.Equal(expectedAccent.Accent, AssertResource<Color>("AccentColor"));
                Assert.Equal(expectedNeutral.Bg, AssertResource<Color>("DsBgColor"));
                Assert.Equal(expectedNeutral.Bg, AssertResource<Color>("BgDeep"));
                Assert.Equal(expectedNeutral.Fg, AssertResource<Color>("TextBright"));
                Assert.Equal(expectedNeutral.Line, AssertResource<Color>("DividerColor"));
                Assert.Equal(expectedAccent.Accent, AssertResource<SolidColorBrush>("AccentBrush").Color);
                Assert.Equal(expectedNeutral.Bg, AssertResource<SolidColorBrush>("BgDeepBrush").Color);

                var expectedDanger = AccentPalette.StateFor(theme).Danger;
                Assert.Equal(Color.FromArgb(0x0F, expectedDanger.R, expectedDanger.G, expectedDanger.B), AssertResource<Color>("DsDangerSoftColor"));
                Assert.Equal(Color.FromArgb(0x33, expectedDanger.R, expectedDanger.G, expectedDanger.B), AssertResource<Color>("DsDangerRingColor"));
                Assert.Equal(Color.FromArgb(0x1F, expectedDanger.R, expectedDanger.G, expectedDanger.B), AssertResource<Color>("DsDangerActiveColor"));
                Assert.Equal(AssertResource<Color>("DsDangerSoftColor"), AssertResource<SolidColorBrush>("DsDangerSoftBrush").Color);
                Assert.Equal(AssertResource<Color>("DsDangerRingColor"), AssertResource<SolidColorBrush>("DsDangerRingBrush").Color);
                Assert.Equal(AssertResource<Color>("DsDangerActiveColor"), AssertResource<SolidColorBrush>("DsDangerActiveBrush").Color);
            }
        }
    }

    private static void AssertLegacyAliasSingleSource()
    {
        var resources = Application.Current.Resources;
        var counts = LegacyKeys.ToDictionary(key => key, _ => 0);

        foreach (var dictionary in resources.MergedDictionaries)
        {
            foreach (var key in dictionary.Keys.Cast<object>().OfType<string>())
            {
                if (counts.ContainsKey(key) && IsColorOrBrush(dictionary[key]))
                    counts[key]++;
            }
        }

        Assert.All(counts, pair => Assert.Equal(1, pair.Value));
    }

    private static T AssertResource<T>(string key)
    {
        var value = Application.Current.TryFindResource(key);
        return Assert.IsAssignableFrom<T>(value);
    }

    private static Style AssertStyle<TTarget>(string key)
    {
        var style = AssertResource<Style>(key);
        Assert.Equal(typeof(TTarget), style.TargetType);
        return style;
    }

    private static ControlTemplate GetTemplate<TTarget>(string styleKey)
        where TTarget : Control
    {
        var style = AssertStyle<TTarget>(styleKey);
        var templateSetter = style.Setters.OfType<Setter>().SingleOrDefault(setter => setter.Property == Control.TemplateProperty);
        Assert.NotNull(templateSetter);
        return Assert.IsType<ControlTemplate>(templateSetter.Value);
    }

    private static IReadOnlyList<Setter> AssertHoverTriggerSetters(ControlTemplate template)
    {
        var trigger = template.Triggers
            .OfType<Trigger>()
            .SingleOrDefault(candidate => candidate.Property == UIElement.IsMouseOverProperty && Equals(candidate.Value, true));

        Assert.NotNull(trigger);
        return trigger.Setters.OfType<Setter>().ToArray();
    }

    private static IReadOnlyList<Setter> AssertPressedTriggerSetters(ControlTemplate template)
    {
        var trigger = template.Triggers
            .OfType<Trigger>()
            .SingleOrDefault(candidate => candidate.Property == ButtonBase.IsPressedProperty && Equals(candidate.Value, true));

        Assert.NotNull(trigger);
        return trigger.Setters.OfType<Setter>().ToArray();
    }

    private static void AssertSetter(IReadOnlyList<Setter> setters, string? targetName, DependencyProperty property, object expectedValue)
    {
        var setter = Assert.Single(setters, candidate => candidate.TargetName == targetName && candidate.Property == property);
        Assert.Equal(expectedValue, setter.Value);
    }

    private static void AssertSetterColor(IReadOnlyList<Setter> setters, string targetName, DependencyProperty property, Color expectedColor)
    {
        var setter = Assert.Single(setters, candidate => candidate.TargetName == targetName && candidate.Property == property);
        Assert.Equal(expectedColor, Assert.IsType<SolidColorBrush>(setter.Value).Color);
    }

    private static void AssertSetterResource(IReadOnlyList<Setter> setters, string? targetName, DependencyProperty property, string expectedResourceKey)
    {
        var setter = Assert.Single(setters, candidate => candidate.TargetName == targetName && candidate.Property == property);
        var resource = Assert.IsType<DynamicResourceExtension>(setter.Value);
        Assert.Equal(expectedResourceKey, resource.ResourceKey);
    }

    private static bool IsChromeHoverBackground(Setter setter) =>
        setter.TargetName == "Chrome" &&
        setter.Property == Border.BackgroundProperty &&
        setter.Value is DynamicResourceExtension { ResourceKey: "DsBgHoverBrush" };

    private static bool IsButtonChromeHoverBackground(Setter setter) =>
        setter.TargetName == "ButtonChrome" &&
        setter.Property == Border.BackgroundProperty &&
        setter.Value is DynamicResourceExtension { ResourceKey: "DsBgHoverBrush" };

    private static void AssertContentShell(string key)
    {
        var style = AssertStyle<ContentControl>(key);
        var control = new ContentControl { Style = style, Content = new Border() };
        control.ApplyTemplate();
        Assert.NotNull(control.Template.FindName("PART_Content", control));
    }

    private static bool IsColorOrBrush(object value) => value is Color or SolidColorBrush;

    private static string NewThemePath() =>
        IOPath.Combine(IOPath.GetTempPath(), "LobsterInput.Tests", Guid.NewGuid().ToString("N"), "theme.json");

    private static string SolutionRoot()
    {
        var dir = new System.IO.DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(IOPath.Combine(dir.FullName, "LobsterInput.sln")))
            dir = dir.Parent;

        return dir?.FullName ?? throw new InvalidOperationException("Could not locate solution root.");
    }
}
