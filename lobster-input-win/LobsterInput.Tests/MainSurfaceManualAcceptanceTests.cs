using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Views;
using LobsterInput.Views.Onboarding;
using Xunit;

namespace LobsterInput.Tests;

public sealed class MainSurfaceManualAcceptanceTests
{
    private static readonly (string Name, Func<FrameworkElement> Create, int Width, int Height)[] Surfaces =
    [
        ("home", () => new HomeView(), 860, 682),
        ("dictionary", CreateDictionaryBaseline, 860, 682),
        ("persona", CreatePersonaBaseline, 860, 682),
        ("history", CreateHistoryBaseline, 860, 682),
        ("settings", () => new SettingsView(), 860, 682),
        ("auth", () => new AuthWindow(), 680, 680),
        ("invite-code", () => new InviteCodeWindow("visual@example.com"), 680, 680),
        ("onboarding", () => new OnboardingWindow(), 680, 680),
        ("my-invite-codes", CreateInviteCodesBaseline, 860, 682),
        ("agreement", CreateAgreementBaseline, 860, 682)
    ];

    [Fact]
    public void CapturesLightAndDarkVisualBaselines()
    {
        WpfTestHost.Run(() =>
        {
            var outputDir = System.IO.Path.Combine(RepoRoot(), "design", "baselines", "002");
            System.IO.Directory.CreateDirectory(outputDir);

            foreach (var theme in new[] { AppTheme.Light, AppTheme.Dark })
            {
                ThemeManager.Instance.Theme = theme;
                ThemeManager.Instance.Accent = AppAccent.Sand;

                foreach (var surface in Surfaces)
                {
                    var element = surface.Create();
                    var bitmap = Capture(surface.Name, element, surface.Width, surface.Height);
                    var file = System.IO.Path.Combine(outputDir, $"{surface.Name}-{theme.ToString().ToLowerInvariant()}-sand.png");

                    Save(bitmap, file);

                    Assert.True(System.IO.File.Exists(file));
                    Assert.True(new System.IO.FileInfo(file).Length > 10_000, $"{file} should contain a real screenshot.");
                    Assert.True(HasVisualVariation(bitmap), $"{file} should not be blank.");
                }
            }
        });
    }

    [Fact]
    public void FocusableSurfacesExposeKeyboardReachableControls()
    {
        WpfTestHost.Run(() =>
        {
            foreach (var surface in Surfaces)
            {
                var element = surface.Create();
                using var host = ShowOffscreen(surface.Name, element, surface.Width, surface.Height);
                var focusable = Descendants(host.Root)
                    .OfType<UIElement>()
                    .Where(IsFocusableCandidate)
                    .ToList();

                Assert.NotEmpty(focusable);

                foreach (var item in focusable)
                {
                    item.Focus();
                    Assert.True(
                        item.IsKeyboardFocusWithin || ReferenceEquals(Keyboard.FocusedElement, item),
                        $"{surface.Name}: {NameOf(item)} should accept keyboard focus.");
                }
            }
        });
    }

    [Fact]
    public void MouseClickableChromeAndStepDotsAreKeyboardReachable()
    {
        WpfTestHost.Run(() =>
        {
            var surfaces = new FrameworkElement[]
            {
                new MainWindow(),
                new SettingsView(),
                new OnboardingView(),
                CreatePersonaBaseline(),
                CreateHistoryBaseline()
            };

            foreach (var surface in surfaces)
            {
                using var host = ShowOffscreen(surface.GetType().Name, surface, 1080, 720);
                var mouseOnly = Descendants(host.Root)
                    .OfType<FrameworkElement>()
                    .Where(e => e.Cursor == Cursors.Hand)
                    .Where(e => e is not ButtonBase)
                    .Where(e => e.IsVisible)
                    .ToList();

                foreach (var element in mouseOnly)
                {
                    Assert.True(element.Focusable, $"{surface.GetType().Name}: {NameOf(element)} uses hand cursor and must be focusable.");
                    element.Focus();
                    Assert.True(
                        element.IsKeyboardFocusWithin || ReferenceEquals(Keyboard.FocusedElement, element),
                        $"{surface.GetType().Name}: {NameOf(element)} should accept keyboard focus.");
                }
            }
        });
    }

    private static RenderTargetBitmap Capture(string name, FrameworkElement element, int width, int height)
    {
        var loadedElement = element is Window window
            ? window.Content as FrameworkElement
            : element;
        var target = PrepareForRendering(name, element, width, height);
        target.UpdateLayout();

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(target);
        RaiseUnloaded(loadedElement);
        return bitmap;
    }

    private static FrameworkElement PrepareForRendering(string name, FrameworkElement element, int width, int height)
    {
        var size = new Size(width, height);

        if (element is Window window)
        {
            var content = window.Content as FrameworkElement;
            window.Content = null;
            var windowRoot = CreateWindowShell(window.Title, content, width, height);
            RaiseLoaded(content);
            windowRoot.Measure(size);
            windowRoot.Arrange(new Rect(size));
            windowRoot.UpdateLayout();
            return windowRoot;
        }

        var root = new Grid
        {
            Width = width,
            Height = height,
            Background = Application.Current.TryFindResource("DsBgBrush") as Brush ?? Brushes.White
        };
        root.Children.Add(element);
        RaiseLoaded(element);
        root.Measure(size);
        root.Arrange(new Rect(size));
        root.UpdateLayout();
        return root;
    }

    private static Grid CreateWindowShell(string title, FrameworkElement? content, int width, int height)
    {
        var root = new Grid
        {
            Width = width,
            Height = height,
            Background = Application.Current.TryFindResource("DsBgBrush") as Brush ?? Brushes.White
        };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(38) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var titleBar = new Grid
        {
            Background = Application.Current.TryFindResource("DsBgSunkenBrush") as Brush ?? Brushes.White
        };
        titleBar.Children.Add(new TextBlock
        {
            Text = title,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12,
            Foreground = Application.Current.TryFindResource("DsFgMutedBrush") as Brush ?? Brushes.Gray
        });
        root.Children.Add(titleBar);

        if (content != null)
        {
            Grid.SetRow(content, 1);
            root.Children.Add(content);
        }

        return root;
    }

    private static void RaiseLoaded(FrameworkElement? element)
    {
        element?.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent));
    }

    private static void RaiseUnloaded(FrameworkElement? element)
    {
        element?.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
    }

    private static FrameworkElement CreateAgreementBaseline()
    {
        var view = new AgreementView
        {
            Title = "Terms"
        };
        ((TextBlock)view.FindName("TitleText")).Text = "Terms";
        typeof(AgreementView)
            .GetMethod("ShowContent", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, ["# Terms\n\nThis local baseline content verifies the agreement surface typography, scrolling area, and footer action without depending on network availability."]);
        return view;
    }

    private static FrameworkElement CreateInviteCodesBaseline()
    {
        var view = new MyInviteCodesView();
        typeof(MyInviteCodesView)
            .GetField("_codes", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .SetValue(view, new List<LobsterInput.Models.InviteCodeItem>
            {
                new() { Code = "ABCD-EFGH", IsUsed = false },
                new() { Code = "USED-CODE", IsUsed = true, UsedBy = "friend@example.com" }
            });
        typeof(MyInviteCodesView)
            .GetMethod("RefreshLabels", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, []);
        typeof(MyInviteCodesView)
            .GetMethod("RebuildList", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, []);
        return view;
    }

    private static FrameworkElement CreateDictionaryBaseline()
    {
        var view = new DictionaryView();
        view.Loaded += (_, _) => ApplyDictionaryBaseline(view);
        ApplyDictionaryBaseline(view);
        return view;
    }

    private static void ApplyDictionaryBaseline(DictionaryView view)
    {
        typeof(DictionaryView)
            .GetMethod("RefreshLabels", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, []);
        ((TextBlock)view.FindName("LoadingText")).Visibility = Visibility.Collapsed;
        ((Panel)view.FindName("EmptyPanel")).Visibility = Visibility.Collapsed;
        ((TextBlock)view.FindName("ErrorText")).Visibility = Visibility.Collapsed;
        ((TextBox)view.FindName("SearchInput")).Text = "";
        ((Button)view.FindName("ClearSearchBtn")).Visibility = Visibility.Collapsed;
        ((ItemsControl)view.FindName("WordsList")).Visibility = Visibility.Visible;
        ((ItemsControl)view.FindName("WordsList")).ItemsSource = new List<LobsterInput.Models.HotWordItem>
        {
            new() { Id = "1", Word = "ClaudeCode" },
            new() { Id = "2", Word = "unity" },
            new() { Id = "3", Word = "vibe coding" },
            new() { Id = "4", Word = "Codex" },
            new() { Id = "5", Word = "Claude Code" },
            new() { Id = "6", Word = "Obsidian" }
        };
        ((Panel)view.FindName("PaginationPanel")).Visibility = Visibility.Collapsed;
    }

    private static FrameworkElement CreatePersonaBaseline()
    {
        var view = new PersonaView();
        view.Loaded += (_, _) => ApplyPersonaBaseline(view);
        ApplyPersonaBaseline(view);
        return view;
    }

    private static void ApplyPersonaBaseline(PersonaView view)
    {
        typeof(PersonaView)
            .GetMethod("RefreshLabels", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, []);
        ((TextBlock)view.FindName("LoadingText")).Visibility = Visibility.Collapsed;
        ((Panel)view.FindName("EmptyPanel")).Visibility = Visibility.Collapsed;
        ((ScrollViewer)view.FindName("PersonaScroll")).Visibility = Visibility.Visible;
        ((ItemsControl)view.FindName("PersonaList")).ItemsSource = new[]
        {
            new
            {
                Name = "Default",
                Description = "General purpose writing and transcription profile.",
                IsActive = true,
                IsUserPersona = false,
                CanRunActivationAction = true,
                ActiveStateText = "Active",
                ActivateButtonText = "Activate",
                DeactivateButtonText = "Deactivate",
                HasPromptSummary = false,
                TranscribeEnabled = false,
                RewriteEnabled = false,
                IntentEnabled = false,
                Item = new object()
            },
            new
            {
                Name = "Coding",
                Description = "Keeps technical terms, product names, and command phrasing precise.",
                IsActive = false,
                IsUserPersona = true,
                CanRunActivationAction = true,
                ActiveStateText = "Inactive",
                ActivateButtonText = "Activate",
                DeactivateButtonText = "Deactivate",
                HasPromptSummary = true,
                TranscribeEnabled = true,
                RewriteEnabled = true,
                IntentEnabled = false,
                Item = new object()
            }
        };
    }

    private static FrameworkElement CreateHistoryBaseline()
    {
        var view = new HistoryView();
        view.Loaded += (_, _) => ApplyHistoryBaseline(view);
        ApplyHistoryBaseline(view);
        return view;
    }

    private static void ApplyHistoryBaseline(HistoryView view)
    {
        typeof(HistoryView)
            .GetMethod("RefreshLabels", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, []);
        typeof(HistoryView)
            .GetMethod("RefreshRetentionSelection", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, []);

        var expandedIds = (HashSet<string>)typeof(HistoryView)
            .GetField("_expandedIds", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .GetValue(view)!;
        expandedIds.Add("expanded");

        ((TextBlock)view.FindName("EmptyText")).Visibility = Visibility.Collapsed;
        ((TextBlock)view.FindName("RecordCountText")).Text = L10n.RecCount(3);
        var list = (ItemsControl)view.FindName("HistoryList");
        list.Items.Clear();
        list.Items.Add(BuildHistoryItem(view, new RecordingHistory
        {
            Id = "expanded",
            CreatedAt = new DateTime(2026, 5, 16, 21, 40, 0, DateTimeKind.Utc),
            Operation = "transcribe",
            Status = RecordingStatus.Success,
            AudioFilePath = SampleAudioPath(),
            Transcript = "这里有很多这种非常大的 card，也就是词典的视觉问题。不是在这个 change 里里面去修复吗？",
            Result = "这里有很多这种非常大的 card，也就是词典的视觉问题。不是在这个 change 里里面去修复吗？",
            ProcessingDuration = 2.3
        }));
        list.Items.Add(BuildHistoryItem(view, new RecordingHistory
        {
            Id = "collapsed",
            CreatedAt = new DateTime(2026, 5, 16, 20, 53, 0, DateTimeKind.Utc),
            Operation = "rewrite",
            Status = RecordingStatus.Success,
            AudioFilePath = SampleAudioPath(),
            Transcript = "如果这套东西开发完了，是不是这套框架就可以抽离出来以后做别的游戏的话也可以拿出来用？",
            Result = "如果这套东西开发完了，这套框架是不是就可以抽离出来，之后做别的游戏也继续复用？",
            ProcessingDuration = 3.5
        }));
        list.Items.Add(BuildHistoryItem(view, new RecordingHistory
        {
            Id = "failed",
            CreatedAt = new DateTime(2026, 5, 16, 20, 48, 0, DateTimeKind.Utc),
            Operation = "transcribe",
            Status = RecordingStatus.Failed,
            ErrorMessage = "音频识别失败，请重试。"
        }));
    }

    private static UIElement BuildHistoryItem(HistoryView view, RecordingHistory record)
    {
        return (UIElement)typeof(HistoryView)
            .GetMethod("BuildHistoryItem", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
            .Invoke(view, [record])!;
    }

    private static string SampleAudioPath()
    {
        var path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "lobster-history-baseline.wav");
        if (!System.IO.File.Exists(path))
            System.IO.File.WriteAllBytes(path, [0, 0, 0, 0]);
        return path;
    }

    private static OffscreenHost ShowOffscreen(string title, FrameworkElement element, int width, int height)
    {
        var window = element as Window ?? new Window
        {
            Content = element,
            Background = Application.Current.TryFindResource("DsBgBrush") as Brush ?? Brushes.White,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize
        };

        window.Title = title;
        window.Width = width;
        window.Height = height;
        window.Left = -20_000;
        window.Top = -20_000;
        window.ShowInTaskbar = false;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Show();
        window.UpdateLayout();

        window.UpdateLayout();

        return new OffscreenHost(window, window);
    }

    private static bool IsFocusableCandidate(UIElement element) =>
        element.Focusable &&
        element.IsVisible &&
        element.IsEnabled &&
        element is not Window &&
        element is not ScrollViewer;

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;

            foreach (var descendant in Descendants(child))
                yield return descendant;
        }
    }

    private static bool HasVisualVariation(BitmapSource bitmap)
    {
        var stride = bitmap.PixelWidth * 4;
        var pixels = new byte[stride * bitmap.PixelHeight];
        bitmap.CopyPixels(pixels, stride, 0);

        var samples = new HashSet<int>();
        for (var y = 0; y < bitmap.PixelHeight; y += 24)
        {
            for (var x = 0; x < bitmap.PixelWidth; x += 24)
            {
                var index = y * stride + x * 4;
                var color = pixels[index] |
                            (pixels[index + 1] << 8) |
                            (pixels[index + 2] << 16) |
                            (pixels[index + 3] << 24);
                samples.Add(color);
            }
        }

        return samples.Count > 3;
    }

    private static void Save(BitmapSource bitmap, string path)
    {
        using var stream = System.IO.File.Create(path);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        encoder.Save(stream);
    }

    private static string NameOf(object element) =>
        element is FrameworkElement { Name: { Length: > 0 } name }
            ? name
            : element.GetType().Name;

    private static string RepoRoot() =>
        System.IO.Path.GetFullPath(System.IO.Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));

    private sealed class OffscreenHost(Window window, FrameworkElement root) : IDisposable
    {
        public FrameworkElement Root { get; } = root;

        public void Dispose()
        {
            if (window is AppStageWindow stage)
            {
                stage.CloseForTransition();
                return;
            }

            if (window is MainWindow)
            {
                window.RaiseEvent(new RoutedEventArgs(FrameworkElement.UnloadedEvent));
                window.Hide();
                return;
            }

            window.Close();
        }
    }
}
