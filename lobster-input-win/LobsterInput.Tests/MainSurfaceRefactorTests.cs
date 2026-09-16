using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Media3D;
using System.Windows.Shapes;
using System.Windows.Threading;
using LobsterInput.Controls;
using LobsterInput.Helpers;
using LobsterInput.Localization;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;
using LobsterInput.ViewModels;
using LobsterInput.Views;
using LobsterInput.Views.Onboarding;
using Xunit;

namespace LobsterInput.Tests;

public sealed class MainSurfaceRefactorTests
{
    private static readonly string[] AppearanceKeys =
    [
        "settingsAppearance",
        "settingsTheme",
        "settingsThemeDescription",
        "settingsAccent",
        "settingsAccentDescription",
        "accentSand",
        "accentMono",
        "accentBlue",
        "accentOrange",
        "accentRed",
        "accentGreen",
        "accentPurple"
    ];

    [Fact]
    public void MainWindowUsesDesignChromeAndKeepsContentHost()
    {
        WpfTestHost.Run(() =>
        {
            var window = new MainWindow();
            try
            {
                window.Left = -20_000;
                window.Top = -20_000;
                window.ShowInTaskbar = false;
                window.Show();
                Assert.Equal(1080, window.Width);
                Assert.Equal(720, window.Height);
                Assert.Equal(1080, window.MinWidth);
                Assert.Equal(720, window.MinHeight);
                Assert.Equal(1080, window.MaxWidth);
                Assert.Equal(720, window.MaxHeight);
                Assert.Equal(ResizeMode.NoResize, window.ResizeMode);
                Assert.Same(Application.Current.TryFindResource("WindowsChromeWindowStyle"), window.Style);

                window.ApplyTemplate();

                var minimize = Assert.IsType<Button>(window.Template.FindName("MinimizeButton", window));
                var maximize = Assert.IsType<Button>(window.Template.FindName("MaximizeButton", window));
                var close = Assert.IsType<Button>(window.Template.FindName("CloseButton", window));
                Assert.Same(window, minimize.CommandTarget);
                Assert.Same(window, maximize.CommandTarget);
                Assert.Same(window, close.CommandTarget);

                var contentHost = Assert.IsType<Grid>(window.FindName("ContentHost"));
                contentHost.Children.Clear();
                contentHost.Children.Add(new Border());
                Assert.Single(contentHost.Children);

                Assert.Equal(SystemCommands.MaximizeWindowCommand, maximize.Command);
                Assert.Equal("\uE922", maximize.Content);
                Assert.False(maximize.IsEnabled);

                Assert.True(SystemCommands.MinimizeWindowCommand.CanExecute(null, window));
                SystemCommands.MinimizeWindowCommand.Execute(null, window);
                Assert.Equal(WindowState.Minimized, window.WindowState);
                window.WindowState = WindowState.Normal;
            }
            finally
            {
                window.Hide();
            }
        });
    }

    [Fact]
    public void MainWindowLoadedAfterLoginPopulatesCurrentTab()
    {
        WpfTestHost.Run(() =>
        {
            var auth = AuthStore.Instance;
            var originalToken = auth.Token;
            var originalEmail = auth.Email;
            var originalTier = auth.Tier;
            var testEmail = "main-window-loaded-test@example.com";

            auth.Token = null;
            auth.Email = testEmail;
            auth.Tier = "trial";
            OnboardingManager.Reset();

            var window = new MainWindow();
            try
            {
                var contentHost = Assert.IsType<Grid>(window.FindName("ContentHost"));
                Assert.Empty(contentHost.Children);

                auth.Email = testEmail;
                auth.Token = "test-token";
                OnboardingManager.MarkCompleted();

                window.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));

                Assert.Single(contentHost.Children);
                Assert.IsType<HomeView>(contentHost.Children[0]);
            }
            finally
            {
                window.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
                window.Hide();
                OnboardingManager.Reset();
                auth.Token = originalToken;
                auth.Email = originalEmail;
                auth.Tier = originalTier;
            }
        });
    }

    [Fact]
    public void AppStageWindowUsesFixedDesignChromeAndCloseHideSemantics()
    {
        WpfTestHost.Run(() =>
        {
            var window = new TestStageWindow();
            var closed = false;
            window.Closed += (_, _) => closed = true;

            try
            {
                Assert.Equal(680, window.Width);
                Assert.Equal(680, window.Height);
                Assert.Equal(680, window.MinWidth);
                Assert.Equal(680, window.MinHeight);
                Assert.Equal(ResizeMode.NoResize, window.ResizeMode);

                window.ApplyTemplate();

                Assert.IsType<Button>(window.Template.FindName("MinimizeButton", window));
                Assert.IsType<Button>(window.Template.FindName("MaximizeButton", window));
                Assert.IsType<Button>(window.Template.FindName("CloseButton", window));

                window.Show();
                window.Close();

                Assert.False(closed);
                Assert.Equal(Visibility.Hidden, window.Visibility);

                window.CloseForTransition();

                Assert.True(closed);
            }
            finally
            {
                if (!closed)
                    window.CloseForTransition();
            }
        });
    }

    [Fact]
    public void AccountPopoverUsesOpaqueDesignSystemSurface()
    {
        WpfTestHost.Run(() =>
        {
            var auth = AuthStore.Instance;
            var originalToken = auth.Token;
            var originalEmail = auth.Email;
            var originalTier = auth.Tier;
            var originalCreditsTotal = auth.CreditsTotal;
            var originalCreditsUsed = auth.CreditsUsed;
            var originalCreditsRemaining = auth.CreditsRemaining;
            var originalCreditItems = auth.CreditItems;
            var originalCreditsResetAt = auth.CreditsResetAt;
            var originalShowInviteCodesEnabled = auth.ShowInviteCodesEnabled;

            try
            {
                auth.Token = "test-token";
                auth.Email = "account-popover@example.com";
                auth.Tier = "trial";
                auth.CreditsTotal = 100;
                auth.CreditsUsed = 25;
                auth.CreditsRemaining = 75;
                auth.CreditItems = [];
                auth.CreditsResetAt = "2026-05-27T00:00:00Z";
                auth.ShowInviteCodesEnabled = true;

                var window = new AccountPopoverWindow(() => { }, () => { });

                Assert.Equal(WindowStyle.None, window.WindowStyle);
                Assert.False(window.AllowsTransparency);
                Assert.Same(Application.Current.TryFindResource("DsBgElevBrush"), window.Background);

                var shell = Assert.IsType<Border>(window.Content);
                Assert.Same(Application.Current.TryFindResource("DsBgElevBrush"), shell.Background);
                Assert.Same(Application.Current.TryFindResource("DsLineStrongBrush"), shell.BorderBrush);
                Assert.Equal(new CornerRadius(0), shell.CornerRadius);
                Assert.Null(shell.Effect);

                Assert.Empty(Descendants(shell).OfType<ProgressBar>());
                Assert.DoesNotContain(Descendants(shell).OfType<TextBlock>(), text => text.Text == L10n.AccountCreditsDetailsShow);

                var logout = Descendants(shell).OfType<Button>()
                    .Single(button => Descendants(button)
                        .OfType<TextBlock>()
                        .Any(text => text.Text == L10n.Logout));
                Assert.Same(Application.Current.TryFindResource("DsButtonGhostDangerStyle"), logout.Style);
            }
            finally
            {
                auth.Token = originalToken;
                auth.Email = originalEmail;
                auth.Tier = originalTier;
                auth.CreditsTotal = originalCreditsTotal;
                auth.CreditsUsed = originalCreditsUsed;
                auth.CreditsRemaining = originalCreditsRemaining;
                auth.CreditItems = originalCreditItems;
                auth.CreditsResetAt = originalCreditsResetAt;
                auth.ShowInviteCodesEnabled = originalShowInviteCodesEnabled;
            }
        });
    }

    [Fact]
    public void HomeOpenClawCardUsesTextFirstHeaderAndDangerUninstallIconButton()
    {
        WpfTestHost.Run(() =>
        {
            var view = new HomeView();

            Assert.Null(view.FindName("OpenClawIconText"));

            var uninstall = Assert.IsType<Button>(view.FindName("OpenClawUninstallBtn"));
            Assert.Equal("\uE74D", uninstall.Content);
            Assert.Same(Application.Current.TryFindResource("DsIconDangerHoverButtonStyle"), uninstall.Style);
            Assert.Same(Application.Current.TryFindResource("IconFont"), uninstall.FontFamily);
        });
    }

    [Fact]
    public void OpenClawUninstallConfirmCopyIsLocalized()
    {
        WpfTestHost.Run(() =>
        {
            var original = LanguageManager.Instance.Current;
            try
            {
                foreach (AppLanguage language in Enum.GetValues<AppLanguage>())
                {
                    LanguageManager.Instance.Current = language;
                    AssertResolved(L10n.OpenclawUninstallConfirmTitle, "openclawUninstallConfirmTitle");
                    AssertResolved(L10n.OpenclawUninstallConfirmMessage, "openclawUninstallConfirmMessage");
                    Assert.Contains("OpenClaw", L10n.OpenclawUninstallConfirmMessage);
                }
            }
            finally
            {
                LanguageManager.Instance.Current = original;
            }
        });
    }

    [Fact]
    public void AppConfirmDialogRootPaintsFullWindowSurface()
    {
        WpfTestHost.Run(() =>
        {
            var ctor = typeof(AppConfirmDialog)
                .GetConstructors(System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)
                .Single();
            var dialog = Assert.IsType<AppConfirmDialog>(ctor.Invoke([
                "Title",
                "Message",
                "Primary",
                null,
                "Cancel"
            ]));

            Assert.True(dialog.UseLayoutRounding);
            Assert.True(dialog.SnapsToDevicePixels);

            var root = Assert.IsType<Grid>(dialog.Content);
            Assert.Equal(new Thickness(0), root.Margin);
            Assert.Same(Application.Current.TryFindResource("DsBgBrush"), root.Background);
            Assert.True(root.UseLayoutRounding);
            Assert.True(root.SnapsToDevicePixels);

            var layout = Assert.IsType<Grid>(root.Children.Cast<UIElement>().Single());
            Assert.Equal(new Thickness(28, 24, 28, 22), layout.Margin);
        });
    }

    [Fact]
    public void RealStageWindowsUseDesignStageSize()
    {
        WpfTestHost.Run(() =>
        {
            var windows = new AppStageWindow[]
            {
                new AuthWindow(),
                new InviteCodeWindow("user@example.com"),
                new OnboardingWindow()
            };

            foreach (var window in windows)
            {
                try
                {
                    Assert.Equal(680, window.Width);
                    Assert.Equal(680, window.Height);
                    Assert.Equal(680, window.MinWidth);
                    Assert.Equal(680, window.MinHeight);
                    Assert.Equal(ResizeMode.NoResize, window.ResizeMode);

                    window.ApplyTemplate();
                    var maximize = Assert.IsType<Button>(window.Template.FindName("MaximizeButton", window));
                    Assert.False(maximize.IsEnabled);
                }
                finally
                {
                    window.CloseForTransition();
                }
            }
        });
    }

    [Fact]
    public void SettingsViewModelSelectedAccentWritesThemeManager()
    {
        WpfTestHost.Run(() =>
        {
            ThemeManager.Instance.Theme = AppTheme.Light;
            ThemeManager.Instance.Accent = AppAccent.Sand;

            var vm = new SettingsViewModel();
            var changes = new List<string>();
            vm.PropertyChanged += (_, e) => changes.Add(e.PropertyName!);

            vm.SelectedAccent = AppAccent.Purple;

            Assert.Equal(AppAccent.Purple, ThemeManager.Instance.Accent);
            Assert.Contains(nameof(SettingsViewModel.SelectedAccent), changes);
        });
    }

    [Fact]
    public void SettingsViewModelSelectedAccentReflectsThemeManagerChanges()
    {
        WpfTestHost.Run(() =>
        {
            ThemeManager.Instance.Theme = AppTheme.Light;
            ThemeManager.Instance.Accent = AppAccent.Sand;

            var vm = new SettingsViewModel();
            var changes = new List<string>();
            vm.PropertyChanged += (_, e) => changes.Add(e.PropertyName!);

            ThemeManager.Instance.Accent = AppAccent.Blue;

            Assert.Equal(AppAccent.Blue, vm.SelectedAccent);
            Assert.Contains(nameof(SettingsViewModel.SelectedAccent), changes);
        });
    }

    [Fact]
    public void DictionaryViewUsesSearchEmptyStateAndCompactThreeColumnGrid()
    {
        WpfTestHost.Run(() =>
        {
            var view = new DictionaryView();

            Assert.Equal(34, ((TextBox)view.FindName("SearchInput")).Padding.Left);
            Assert.Equal(0, ((TextBox)view.FindName("SearchInput")).Padding.Top);
            Assert.Equal(0, ((TextBox)view.FindName("SearchInput")).Padding.Bottom);
            Assert.IsType<StackPanel>(view.FindName("EmptyPanel"));
            Assert.Null(view.FindName("EmptyAddButton"));

            var wordsList = Assert.IsType<ItemsControl>(view.FindName("WordsList"));
            var panel = Assert.IsType<ResponsiveGridPanel>(wordsList.ItemsPanel.LoadContent());
            Assert.Equal(3, panel.MaxColumns);
            Assert.Equal(250, panel.MinItemWidth);
        });
    }

    [Fact]
    public void AtomicInputsTogglesAndDangerIconsMatchDesignSystemShape()
    {
        WpfTestHost.Run(() =>
        {
            var inputStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsInputTextBoxStyle"));
            var toggleStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsToggleCheckBoxStyle"));
            var dangerIconStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsIconDangerHoverButtonStyle"));

            var box = new TextBox { Style = inputStyle, Width = 180 };
            using var host = ShowOffscreen(box, 220, 80);
            box.ApplyTemplate();

            var chrome = Assert.IsType<Border>(box.Template.FindName("Chrome", box));
            Assert.Equal((CornerRadius)Application.Current.TryFindResource("RadiusMd"), chrome.CornerRadius);

            var toggle = new CheckBox { Style = toggleStyle };
            using var toggleHost = ShowOffscreen(toggle, 80, 48);
            toggle.ApplyTemplate();
            toggle.UpdateLayout();
            Assert.Equal(40, toggle.Width);
            Assert.Equal(24, toggle.Height);
            Assert.InRange(toggle.ActualWidth, 39.5, 40.5);
            Assert.InRange(toggle.ActualHeight, 23.5, 24.5);
            var track = Assert.IsType<Border>(toggle.Template.FindName("Track", toggle));
            var thumb = Assert.IsType<Ellipse>(toggle.Template.FindName("Thumb", toggle));
            Assert.InRange(track.ActualWidth, 39.5, 40.5);
            Assert.InRange(track.ActualHeight, 23.5, 24.5);
            Assert.Equal(new CornerRadius(12), track.CornerRadius);
            Assert.Equal(18, thumb.Width);
            Assert.Equal(18, thumb.Height);
            Assert.Equal(new Thickness(3), thumb.Margin);

            Assert.Equal(0, Assert.IsType<TranslateTransform>(thumb.RenderTransform).X);
            toggle.IsChecked = true;
            toggle.UpdateLayout();
            Assert.Equal(16, Assert.IsType<TranslateTransform>(thumb.RenderTransform).X);

            var dangerButton = new Button { Style = dangerIconStyle };
            dangerButton.ApplyTemplate();
            Assert.Equal(26, dangerButton.Width);
            Assert.Equal(26, dangerButton.Height);
            Assert.Same(Application.Current.TryFindResource("DsFgSubtleBrush"), dangerButton.Foreground);
        });
    }

    [Fact]
    public void DictionaryDeleteActionIsHoverDangerOnly()
    {
        WpfTestHost.Run(() =>
        {
            var view = new DictionaryView();
            var dangerIconStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsIconDangerHoverButtonStyle"));
            var wordsList = Assert.IsType<ItemsControl>(view.FindName("WordsList"));
            var itemRoot = Assert.IsAssignableFrom<DependencyObject>(wordsList.ItemTemplate.LoadContent());

            var deleteButton = Descendants(itemRoot)
                .OfType<Button>()
                .Single(button => button.Content?.ToString() == "\uE74D");

            Assert.Same(dangerIconStyle, deleteButton.Style);
            Assert.Null(deleteButton.ReadLocalValue(Control.ForegroundProperty) as Brush);
        });
    }

    [Fact]
    public void PersonaViewUsesResponsiveCardGrid()
    {
        WpfTestHost.Run(() =>
        {
            var view = new PersonaView();

            Assert.IsType<StackPanel>(view.FindName("EmptyPanel"));
            Assert.IsType<Button>(view.FindName("EmptyCreateBtn"));

            var personaList = Assert.IsType<ItemsControl>(view.FindName("PersonaList"));
            var panel = Assert.IsType<ResponsiveGridPanel>(personaList.ItemsPanel.LoadContent());
            Assert.Equal(3, panel.MaxColumns);
            Assert.Equal(250, panel.MinItemWidth);
        });
    }

    [Fact]
    public void PersonaViewThreeColumnGridDoesNotClipInRealMainContentWidth()
    {
        WpfTestHost.Run(() =>
        {
            var view = new PersonaView();
            var personaList = Assert.IsType<ItemsControl>(view.FindName("PersonaList"));
            ((TextBlock)view.FindName("LoadingText")).Visibility = Visibility.Collapsed;
            ((Panel)view.FindName("EmptyPanel")).Visibility = Visibility.Collapsed;
            ((ScrollViewer)view.FindName("PersonaScroll")).Visibility = Visibility.Visible;
            using var host = ShowOffscreen(view, 860, 682);

            ((TextBlock)view.FindName("LoadingText")).Visibility = Visibility.Collapsed;
            ((Panel)view.FindName("EmptyPanel")).Visibility = Visibility.Collapsed;
            ((ScrollViewer)view.FindName("PersonaScroll")).Visibility = Visibility.Visible;
            personaList.ItemsSource = Enumerable.Range(1, 6).Select(index => new
            {
                Name = $"Persona {index}",
                Description = "A representative persona card with enough text to exercise wrapping without changing the column width.",
                IsActive = index == 1,
                IsUserPersona = index % 2 == 0,
                HasPromptSummary = true,
                TranscribeEnabled = true,
                RewriteEnabled = index % 2 == 0,
                IntentEnabled = index % 3 == 0,
                Item = new object()
            }).ToArray();

            view.UpdateLayout();

            var panel = Descendants(view).OfType<ResponsiveGridPanel>().Single();
            Assert.Equal(3, panel.MaxColumns);
            Assert.Equal(250, panel.MinItemWidth);
            Assert.True(panel.ActualWidth >= 796 - 1, $"Expected real main content width, got {panel.ActualWidth}.");

            var children = Enumerable.Range(0, VisualTreeHelper.GetChildrenCount(panel))
                .Select(i => Assert.IsAssignableFrom<FrameworkElement>(VisualTreeHelper.GetChild(panel, i)))
                .ToList();

            Assert.Equal(6, children.Count);

            foreach (var child in children)
            {
                var left = child.TransformToAncestor(panel).Transform(new Point()).X;
                Assert.True(left >= -0.5, $"Persona card starts outside panel at {left}.");
                Assert.True(left + child.ActualWidth <= panel.ActualWidth + 0.5,
                    $"Persona card right edge {left + child.ActualWidth} exceeds panel width {panel.ActualWidth}.");
            }
        });
    }

    [Fact]
    public void ResponsiveGridPanelUsesThreeColumnsAtMainWindowPersonaWidth()
    {
        WpfTestHost.Run(() =>
        {
            var panel = new ResponsiveGridPanel
            {
                MaxColumns = 3,
                MinItemWidth = 250,
                ColumnGap = 14,
                RowGap = 14
            };

            for (var i = 0; i < 6; i++)
                panel.Children.Add(new Border { MinHeight = 132 });

            panel.Measure(new Size(796, double.PositiveInfinity));
            panel.Arrange(new Rect(0, 0, 796, panel.DesiredSize.Height));

            var children = panel.Children.OfType<FrameworkElement>().ToList();
            var firstRowY = children[0].TransformToAncestor(panel).Transform(new Point()).Y;

            Assert.All(children.Take(3), child => Assert.Equal(firstRowY, child.TransformToAncestor(panel).Transform(new Point()).Y, 1));
            Assert.True(children[3].TransformToAncestor(panel).Transform(new Point()).Y > firstRowY);
            Assert.All(children, child => Assert.InRange(child.ActualWidth, 255, 257));
            Assert.Equal(796, panel.DesiredSize.Width);
        });
    }

    [Fact]
    public void PersonaCardsSelectToActivateWithoutActivationButtons()
    {
        WpfTestHost.Run(() =>
        {
            var view = new PersonaView();
            var dangerIconStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsIconDangerHoverButtonStyle"));
            var personaList = Assert.IsType<ItemsControl>(view.FindName("PersonaList"));
            var itemRoot = Assert.IsAssignableFrom<DependencyObject>(personaList.ItemTemplate.LoadContent());
            var buttons = Descendants(itemRoot).OfType<Button>().ToList();

            Assert.Equal(2, buttons.Count);
            Assert.DoesNotContain(buttons, button =>
                button.Content?.ToString() == L10n.PersonaActivateBtn ||
                button.Content?.ToString() == L10n.PersonaDeactivateBtn);
            Assert.Contains(buttons, button => ReferenceEquals(button.Style, dangerIconStyle));
        });
    }

    [Fact]
    public void HistoryCollapsedActionsCopyOnlyResultAndHideSuccessStatusText()
    {
        WpfTestHost.Run(() =>
        {
            var view = new HistoryView();
            var item = BuildHistoryItemForTest(view, new RecordingHistory
            {
                Id = "history-success",
                Status = RecordingStatus.Success,
                Operation = "transcribe",
                Transcript = "original text",
                Result = "result text",
                CreatedAt = DateTime.UtcNow
            });

            var buttons = Descendants(item).OfType<Button>().ToList();
            var copyButtons = buttons
                .Where(button => button.ToolTip?.ToString()?.Contains(L10n.BtnCopy, StringComparison.OrdinalIgnoreCase) == true)
                .ToList();
            var deleteButton = buttons.Single(button => button.ToolTip?.ToString() == L10n.Delete);

            Assert.Single(copyButtons);
            Assert.Contains(L10n.LabelResult, copyButtons[0].ToolTip?.ToString());
            Assert.DoesNotContain(Descendants(item).OfType<TextBlock>(), text => text.Text == L10n.StatusOk);
            Assert.Same(Application.Current.TryFindResource("DsIconDangerHoverButtonStyle"), deleteButton.Style);
        });
    }

    [Fact]
    public void SettingsViewModelDisposeReleasesThemeManagerSubscription()
    {
        WpfTestHost.Run(() =>
        {
            ThemeManager.Instance.Theme = AppTheme.Light;
            ThemeManager.Instance.Accent = AppAccent.Sand;

            var vm = new SettingsViewModel();
            var changes = new List<string>();
            vm.PropertyChanged += (_, e) => changes.Add(e.PropertyName!);

            vm.Dispose();
            ThemeManager.Instance.Accent = AppAccent.Green;

            Assert.Equal(AppAccent.Sand, vm.SelectedAccent);
            Assert.DoesNotContain(nameof(SettingsViewModel.SelectedAccent), changes);
        });
    }

    [Fact]
    public void SettingsViewUsesAtomicToggleAndActionStyles()
    {
        WpfTestHost.Run(() =>
        {
            var view = new SettingsView();
            var toggleStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsToggleCheckBoxStyle"));
            var buttonStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsButtonDefaultStyle"));
            var ghostButtonStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsButtonGhostStyle"));
            var iconButtonStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsIconButtonStyle"));
            var primaryButtonStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsButtonPrimaryStyle"));
            var hotkeyButtonStyle = Assert.IsType<Style>(view.TryFindResource("SettingsHotkeyButtonStyle"));
            var clearHotkeyButtonStyle = Assert.IsType<Style>(view.TryFindResource("SettingsClearHotkeyButtonStyle"));
            var detailButtonStyle = Assert.IsType<Style>(view.TryFindResource("SettingsDetailButtonStyle"));

            Assert.Same(ghostButtonStyle, hotkeyButtonStyle.BasedOn);
            Assert.Same(iconButtonStyle, clearHotkeyButtonStyle.BasedOn);
            Assert.Same(buttonStyle, detailButtonStyle.BasedOn);

            foreach (var name in new[]
            {
                "ThemeToggle",
                "FastModeToggle",
                "ScreenshotConfirmToggle",
                "ClipboardToggle",
                "StartupLaunchToggle"
            })
            {
                var toggle = Assert.IsType<CheckBox>(view.FindName(name));
                Assert.Same(toggleStyle, toggle.Style);
            }

            foreach (var name in new[]
            {
                "HkTranscribeBtn",
                "HkRewriteBtn",
                "HkAgentBtn",
                "HkScreenshotBtn"
            })
            {
                var button = Assert.IsType<Button>(view.FindName(name));
                Assert.Same(hotkeyButtonStyle, button.Style);
            }

            foreach (var name in new[]
            {
                "HkTranscribeClearBtn",
                "HkRewriteClearBtn",
                "HkAgentClearBtn",
                "HkScreenshotClearBtn"
            })
            {
                var button = Assert.IsType<Button>(view.FindName(name));
                Assert.Same(clearHotkeyButtonStyle, button.Style);
            }

            var checkUpdate = Assert.IsType<Button>(view.FindName("CheckUpdateBtn"));
            Assert.Same(buttonStyle, checkUpdate.Style);

            var creditDetails = Assert.IsType<Button>(view.FindName("CreditDetailsToggleBtn"));
            Assert.Same(detailButtonStyle, creditDetails.Style);

            var inviteCodes = Assert.IsType<Button>(view.FindName("InviteCodesBtn"));
            Assert.Same(primaryButtonStyle, inviteCodes.Style);
        });
    }

    [Fact]
    public void StageLoadingProgressBarsUseDesignSpinnerStyle()
    {
        WpfTestHost.Run(() =>
        {
            var spinnerStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsIndeterminateSpinnerStyle"));
            var surfaces = new FrameworkElement[]
            {
                new AuthView(),
                new InviteCodeView(),
                new AgreementView()
            };

            foreach (var surface in surfaces)
            {
                var bars = Descendants(surface).OfType<ProgressBar>().ToList();
                Assert.NotEmpty(bars);
                Assert.All(bars, bar => Assert.Same(spinnerStyle, bar.Style));
            }
        });
    }

    [Fact]
    public void SettingsAccentSwatchesUseCurrentThemePalette()
    {
        WpfTestHost.Run(() =>
        {
            ThemeManager.Instance.Theme = AppTheme.Dark;
            ThemeManager.Instance.Accent = AppAccent.Sand;

            var view = new SettingsView();
            try
            {
                view.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));

                var blue = Assert.IsType<Button>(view.FindName("AccentBlueBtn"));
                var sand = Assert.IsType<Button>(view.FindName("AccentSandBtn"));
                var blueBrush = Assert.IsType<SolidColorBrush>(blue.Background);
                var sandForeground = Assert.IsType<SolidColorBrush>(sand.Foreground);

                Assert.Equal(AccentPalette.For(AppTheme.Dark, AppAccent.Blue).Accent, blueBrush.Color);
                Assert.Equal(AccentPalette.For(AppTheme.Dark, AppAccent.Sand).AccentFg, sandForeground.Color);
            }
            finally
            {
                view.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
            }
        });
    }

    [Fact]
    public void DesignScrollViewerStyleUsesCustomScrollBarTemplate()
    {
        WpfTestHost.Run(() =>
        {
            var style = Assert.IsType<Style>(Application.Current.TryFindResource("DsScrollViewerStyle"));
            var viewer = new ScrollViewer
            {
                Style = style,
                Content = new Border { Width = 80, Height = 400 },
                Width = 80,
                Height = 80
            };

            using var host = ShowOffscreen(viewer, 100, 100);
            viewer.ApplyTemplate();
            viewer.UpdateLayout();
            var verticalBar = Assert.IsType<ScrollBar>(viewer.Template.FindName("PART_VerticalScrollBar", viewer));
            var customBarStyle = Assert.IsType<Style>(Application.Current.TryFindResource("DsScrollBarStyle"));

            Assert.Same(customBarStyle, verticalBar.Style);
        });
    }

    [Fact]
    public void AgreementMarkdownDocumentUsesThemeForeground()
    {
        WpfTestHost.Run(() =>
        {
            ThemeManager.Instance.Theme = AppTheme.Dark;
            ThemeManager.Instance.Accent = AppAccent.Sand;
            ThemeManager.Instance.ApplyCurrentTheme();

            var view = new AgreementView();
            try
            {
                typeof(AgreementView)
                    .GetMethod("ShowContent", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                    .Invoke(view, ["# Terms\n\nBody"]);

                var expected = Assert.IsType<SolidColorBrush>(view.TryFindResource("DsFgBrush")).Color;
                var expectedHeading = Assert.IsType<SolidColorBrush>(view.TryFindResource("DsAccentBrush")).Color;
                var actual = Assert.IsType<SolidColorBrush>(view.ContentViewer.Document.Foreground).Color;
                var firstBlock = Assert.IsType<Paragraph>(view.ContentViewer.Document.Blocks.FirstBlock);
                var firstBlockColor = Assert.IsType<SolidColorBrush>(firstBlock.Foreground).Color;

                Assert.Equal(expected, actual);
                Assert.Equal(expectedHeading, firstBlockColor);
            }
            finally
            {
                view.Close();
            }
        });
    }

    [Fact]
    public void AppearanceLocalizationKeysExistForEveryPack()
    {
        var registry = LocalizationRegistry.Default;

        foreach (var language in registry.AvailableLanguages)
        {
            foreach (var key in AppearanceKeys)
            {
                var value = registry.Get(language, key);

                Assert.False(string.IsNullOrWhiteSpace(value));
                Assert.NotEqual(key, value);
            }
        }
    }

    [Fact]
    public void AppearanceL10nStaticPropertiesReturnResolvedText()
    {
        var original = LanguageManager.Instance.Current;

        try
        {
            foreach (var language in LocalizationRegistry.Default.AvailableLanguages)
            {
                LanguageManager.Instance.Current = language;

                AssertResolved(L10n.SettingsAppearance, "settingsAppearance");
                AssertResolved(L10n.SettingsTheme, "settingsTheme");
                AssertResolved(L10n.SettingsThemeDescription, "settingsThemeDescription");
                AssertResolved(L10n.SettingsAccent, "settingsAccent");
                AssertResolved(L10n.SettingsAccentDescription, "settingsAccentDescription");
                AssertResolved(L10n.AccentSand, "accentSand");
                AssertResolved(L10n.AccentMono, "accentMono");
                AssertResolved(L10n.AccentBlue, "accentBlue");
                AssertResolved(L10n.AccentOrange, "accentOrange");
                AssertResolved(L10n.AccentRed, "accentRed");
                AssertResolved(L10n.AccentGreen, "accentGreen");
                AssertResolved(L10n.AccentPurple, "accentPurple");
            }
        }
        finally
        {
            LanguageManager.Instance.Current = original;
        }
    }

    [Fact]
    public void MainStageAndAgreementViewsDispatchLanguageRefreshAndUnsubscribeOnUnload()
    {
        WpfTestHost.Run(() =>
        {
            var original = LanguageManager.Instance.Current;

            try
            {
                LanguageManager.Instance.Current = AppLanguage.En;

                AssertLanguageSubscriptionLifecycle(
                    new MainWindow(),
                    AppLanguage.Zh,
                    AppLanguage.En,
                    view => view.Title,
                    () => L10n.AppNameFull);

                AssertLanguageSubscriptionLifecycle(
                    new AuthView(),
                    AppLanguage.Zh,
                    AppLanguage.En,
                    view => ((TextBlock)view.FindName("SubtitleText")).Text,
                    () => L10n.AuthSubtitle);

                AssertLanguageSubscriptionLifecycle(
                    new InviteCodeView(),
                    AppLanguage.Zh,
                    AppLanguage.En,
                    view => ((TextBlock)view.FindName("PageTitle")).Text,
                    () => L10n.InvitePageTitle);

                AssertLanguageSubscriptionLifecycle(
                    new AgreementView(),
                    AppLanguage.Zh,
                    AppLanguage.En,
                    view => ((Button)view.FindName("CloseBtn")).Content?.ToString() ?? "",
                    () => L10n.AgreementClose);

                AssertLanguageSubscriptionLifecycle(
                    new OnboardingView(),
                    AppLanguage.Zh,
                    AppLanguage.En,
                    view => ((TextBlock)view.FindName("WelcomeTitle")).Text,
                    () => L10n.OnboardingWelcomeTitle);
            }
            finally
            {
                LanguageManager.Instance.Current = original;
            }
        });
    }

    private static void AssertResolved(string value, string key)
    {
        Assert.False(string.IsNullOrWhiteSpace(value));
        Assert.NotEqual(key, value);
    }

    private static OffscreenHost ShowOffscreen(FrameworkElement element, int width, int height)
    {
        var window = new Window
        {
            Content = element,
            Width = width,
            Height = height,
            Left = -20_000,
            Top = -20_000,
            ShowInTaskbar = false,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize
        };
        window.Show();
        window.UpdateLayout();
        return new OffscreenHost(window);
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        var logicalChildren = LogicalTreeHelper.GetChildren(root)
            .OfType<DependencyObject>()
            .ToList();

        if (logicalChildren.Count > 0)
        {
            foreach (var child in logicalChildren)
            {
                yield return child;

                foreach (var descendant in Descendants(child))
                    yield return descendant;
            }

            yield break;
        }

        if (root is not Visual and not Visual3D)
            yield break;

        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var visualChild = VisualTreeHelper.GetChild(root, i);
            yield return visualChild;

            foreach (var descendant in Descendants(visualChild))
                yield return descendant;
        }
    }

    private static DependencyObject BuildHistoryItemForTest(HistoryView view, RecordingHistory record)
    {
        var item = typeof(HistoryView)
            .GetMethod("BuildHistoryItem", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, [record]);

        return Assert.IsAssignableFrom<DependencyObject>(item);
    }

    private static void AssertLanguageSubscriptionLifecycle<TView>(
        TView view,
        AppLanguage loadedLanguage,
        AppLanguage unloadedLanguage,
        Func<TView, string> readRenderedText,
        Func<string> readExpectedText)
        where TView : FrameworkElement
    {
        view.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));

        ChangeLanguageFromBackgroundThread(loadedLanguage);
        var renderedWhileLoaded = readRenderedText(view);
        var expectedWhileLoaded = readExpectedText();

        Assert.Equal(expectedWhileLoaded, renderedWhileLoaded);

        view.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));

        ChangeLanguageFromBackgroundThread(unloadedLanguage);

        Assert.Equal(renderedWhileLoaded, readRenderedText(view));
    }

    private static void ChangeLanguageFromBackgroundThread(AppLanguage language)
    {
        Exception? backgroundError = null;
        var complete = false;

        var thread = new Thread(() =>
        {
            try
            {
                LanguageManager.Instance.Current = language;
            }
            catch (Exception ex)
            {
                backgroundError = ex;
            }
            finally
            {
                complete = true;
            }
        })
        {
            IsBackground = true,
            Name = "LobsterInput.Tests.LanguageChange"
        };

        thread.Start();

        var frame = new DispatcherFrame();
        var timer = new DispatcherTimer(
            TimeSpan.FromMilliseconds(10),
            DispatcherPriority.Background,
            (_, _) =>
            {
                if (complete)
                    frame.Continue = false;
            },
            Dispatcher.CurrentDispatcher);

        Dispatcher.PushFrame(frame);
        timer.Stop();

        if (!thread.Join(TimeSpan.FromSeconds(5)))
            throw new TimeoutException("Timed out waiting for background language change.");

        if (backgroundError != null)
            throw backgroundError;
    }

    private sealed class TestStageWindow : AppStageWindow
    {
        public TestStageWindow()
            : base("Test Stage", 680, 680, new Grid())
        {
        }
    }

    private sealed class OffscreenHost(Window window) : IDisposable
    {
        public FrameworkElement Root { get; } = window;

        public void Dispose()
        {
            window.Close();
        }
    }
}
