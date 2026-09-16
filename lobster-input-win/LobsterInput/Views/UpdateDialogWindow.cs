using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Effects;
using LobsterInput.Helpers;
using LobsterInput.Services;

namespace LobsterInput.Views;

public sealed class UpdateDialogWindow : Window
{
    private readonly UpdateService _updater;
    private readonly Action<string>? _setStatus;
    private readonly TextBlock _titleText;
    private readonly TextBlock _bodyText;
    private readonly TextBlock _currentVersionText;
    private readonly TextBlock _newVersionText;
    private readonly TextBlock _releaseNotesTitle;
    private readonly FrameworkElement _releaseNotesBox;
    private readonly TextBlock _releaseNotesText;
    private readonly ProgressBar _progressBar;
    private readonly TextBlock _progressText;
    private readonly Button _primaryButton;
    private readonly Button _secondaryButton;

    public UpdateDialogWindow(UpdateService updater, Action<string>? setStatus = null)
    {
        _updater = updater;
        _setStatus = setStatus;

        Title = L10n.UpdateDialogTitle;
        Width = 460;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;

        var content = BuildContent();
        Content = content;

        _titleText = (TextBlock)content.FindName("TitleText")!;
        _bodyText = (TextBlock)content.FindName("BodyText")!;
        _currentVersionText = (TextBlock)content.FindName("CurrentVersionText")!;
        _newVersionText = (TextBlock)content.FindName("NewVersionText")!;
        _releaseNotesTitle = (TextBlock)content.FindName("ReleaseNotesTitle")!;
        _releaseNotesBox = (FrameworkElement)content.FindName("ReleaseNotesBorder")!;
        _releaseNotesText = (TextBlock)content.FindName("ReleaseNotesText")!;
        _progressBar = (ProgressBar)content.FindName("ProgressBar")!;
        _progressText = (TextBlock)content.FindName("ProgressText")!;
        _primaryButton = (Button)content.FindName("PrimaryButton")!;
        _secondaryButton = (Button)content.FindName("SecondaryButton")!;

        _primaryButton.Click += PrimaryButton_Click;
        _secondaryButton.Click += (_, _) => Close();
        _updater.PropertyChanged += Updater_PropertyChanged;
        Closed += (_, _) => _updater.PropertyChanged -= Updater_PropertyChanged;

        ApplyState();
    }

    private FrameworkElement BuildContent()
    {
        var border = new Border
        {
            Name = "RootBorder",
            Background = Brush("BgCardBrush", Brushes.White),
            BorderBrush = Brush("BorderDimBrush", Brushes.Gainsboro),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(24),
            Effect = new DropShadowEffect
            {
                Color = Colors.Black,
                ShadowDepth = 8,
                BlurRadius = 26,
                Opacity = 0.16
            }
        };
        border.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState == MouseButtonState.Pressed)
                TryDragMove();
        };

        var nameScope = new NameScope();
        NameScope.SetNameScope(border, nameScope);

        var stack = new StackPanel { Orientation = Orientation.Vertical };
        border.Child = stack;

        var header = new Grid { Margin = new Thickness(0, 0, 0, 18) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        stack.Children.Add(header);

        var iconWrap = new Border
        {
            Width = 42,
            Height = 42,
            CornerRadius = new CornerRadius(21),
            Background = new SolidColorBrush(Color.FromArgb(24, 156, 125, 91)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(60, 156, 125, 91)),
            BorderThickness = new Thickness(1),
            Child = new TextBlock
            {
                Text = "\uE895",
                FontFamily = Font("IconFont"),
                FontSize = 18,
                Foreground = Brush("NeonGreenBrush", Brushes.SaddleBrown),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        Grid.SetColumn(iconWrap, 0);
        header.Children.Add(iconWrap);

        var heading = new StackPanel
        {
            Orientation = Orientation.Vertical,
            Margin = new Thickness(14, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(heading, 1);
        header.Children.Add(heading);

        var title = new TextBlock
        {
            Name = "TitleText",
            FontFamily = Font("AppFont"),
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("TextBrightBrush", Brushes.Black)
        };
        nameScope.RegisterName(title.Name, title);
        heading.Children.Add(title);

        var body = new TextBlock
        {
            Name = "BodyText",
            FontFamily = Font("AppFont"),
            FontSize = 13,
            LineHeight = 19,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("TextDimBrush", Brushes.DimGray),
            Margin = new Thickness(0, 8, 0, 0)
        };
        nameScope.RegisterName(body.Name, body);
        stack.Children.Add(body);

        var versionGrid = new Grid { Margin = new Thickness(0, 18, 0, 0) };
        versionGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        versionGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        versionGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        stack.Children.Add(versionGrid);

        var currentVersion = BuildVersionCell("CurrentVersionText", nameScope);
        Grid.SetColumn(currentVersion, 0);
        versionGrid.Children.Add(currentVersion);

        var newVersion = BuildVersionCell("NewVersionText", nameScope);
        Grid.SetColumn(newVersion, 2);
        versionGrid.Children.Add(newVersion);

        var releaseTitle = new TextBlock
        {
            Name = "ReleaseNotesTitle",
            Text = L10n.UpdateDialogReleaseNotes,
            FontFamily = Font("AppFont"),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("TextDimBrush", Brushes.DimGray),
            Margin = new Thickness(0, 18, 0, 8)
        };
        nameScope.RegisterName(releaseTitle.Name, releaseTitle);
        stack.Children.Add(releaseTitle);

        var releaseBorder = new Border
        {
            Name = "ReleaseNotesBorder",
            Background = Brush("BgInputBrush", Brushes.White),
            BorderBrush = Brush("BorderDimBrush", Brushes.Gainsboro),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 9, 12, 9),
            MaxHeight = 110
        };
        nameScope.RegisterName(releaseBorder.Name, releaseBorder);
        stack.Children.Add(releaseBorder);

        var releaseScroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Style = TryFindResource("CyberScrollViewer") as Style
        };
        releaseBorder.Child = releaseScroll;

        var releaseText = new TextBlock
        {
            Name = "ReleaseNotesText",
            FontFamily = Font("AppFont"),
            FontSize = 12,
            LineHeight = 18,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("TextDimBrush", Brushes.DimGray)
        };
        nameScope.RegisterName(releaseText.Name, releaseText);
        releaseScroll.Content = releaseText;

        var progress = new ProgressBar
        {
            Name = "ProgressBar",
            Height = 8,
            Minimum = 0,
            Maximum = 100,
            Margin = new Thickness(0, 20, 0, 0),
            Foreground = Brush("NeonGreenBrush", Brushes.SaddleBrown),
            Background = Brush("BgInputBrush", Brushes.White),
            Visibility = Visibility.Collapsed
        };
        nameScope.RegisterName(progress.Name, progress);
        stack.Children.Add(progress);

        var progressText = new TextBlock
        {
            Name = "ProgressText",
            FontFamily = Font("AppFont"),
            FontSize = 12,
            Foreground = Brush("TextGhostBrush", Brushes.Gray),
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 8, 0, 0),
            Visibility = Visibility.Collapsed
        };
        nameScope.RegisterName(progressText.Name, progressText);
        stack.Children.Add(progressText);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 22, 0, 0)
        };
        stack.Children.Add(buttons);

        var secondary = new Button
        {
            Name = "SecondaryButton",
            MinWidth = 84,
            Height = 34,
            Content = L10n.UpdateDialogLater,
            Style = TryFindResource("CyberButtonSecondary") as Style,
            Margin = new Thickness(0, 0, 10, 0)
        };
        nameScope.RegisterName(secondary.Name, secondary);
        buttons.Children.Add(secondary);

        var primary = new Button
        {
            Name = "PrimaryButton",
            MinWidth = 104,
            Height = 34,
            Content = L10n.UpdateDialogInstallNow,
            Style = TryFindResource("CyberButtonPrimary") as Style
        };
        nameScope.RegisterName(primary.Name, primary);
        buttons.Children.Add(primary);

        return border;
    }

    private Border BuildVersionCell(string textName, INameScope scope)
    {
        var text = new TextBlock
        {
            Name = textName,
            FontFamily = Font("AppFont"),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("TextDimBrush", Brushes.DimGray),
            TextWrapping = TextWrapping.Wrap
        };
        scope.RegisterName(text.Name, text);

        return new Border
        {
            Background = Brush("BgInputBrush", Brushes.White),
            BorderBrush = Brush("BorderDimBrush", Brushes.Gainsboro),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 10, 12, 10),
            Child = text
        };
    }

    private void ApplyState()
    {
        var state = _updater.State;
        _progressBar.Visibility = state == UpdateState.Downloading ? Visibility.Visible : Visibility.Collapsed;
        _progressText.Visibility = state == UpdateState.Downloading ? Visibility.Visible : Visibility.Collapsed;

        _currentVersionText.Text = $"{L10n.UpdateDialogCurrentVersion}\n{_updater.CurrentVersion}";
        _newVersionText.Text = $"{L10n.UpdateDialogNewVersion}\n{_updater.AvailableUpdate?.Version ?? "--"}";

        var notes = _updater.AvailableUpdate?.ReleaseNotes?.Trim() ?? "";
        var hasNotes = !string.IsNullOrWhiteSpace(notes);
        _releaseNotesTitle.Visibility = hasNotes ? Visibility.Visible : Visibility.Collapsed;
        _releaseNotesBox.Visibility = hasNotes ? Visibility.Visible : Visibility.Collapsed;
        _releaseNotesText.Text = notes;

        switch (state)
        {
            case UpdateState.Checking:
                _titleText.Text = L10n.UpdateDialogCheckingTitle;
                _bodyText.Text = L10n.MenuChecking;
                _primaryButton.Content = L10n.UpdateDialogClose;
                _secondaryButton.Visibility = Visibility.Collapsed;
                _primaryButton.IsEnabled = false;
                break;
            case UpdateState.UpdateAvailable:
                _titleText.Text = L10n.UpdateDialogAvailableTitle;
                _bodyText.Text = L10n.UpdateDialogAvailableDesc;
                _primaryButton.Content = L10n.UpdateDialogInstallNow;
                _secondaryButton.Content = L10n.UpdateDialogLater;
                _secondaryButton.Visibility = Visibility.Visible;
                _primaryButton.IsEnabled = true;
                _secondaryButton.IsEnabled = true;
                break;
            case UpdateState.ReadyToInstall:
                _titleText.Text = L10n.UpdateDialogReadyTitle;
                _bodyText.Text = L10n.UpdateDialogReadyDesc;
                _primaryButton.Content = L10n.UpdateDialogRestartInstall;
                _secondaryButton.Content = L10n.UpdateDialogLater;
                _secondaryButton.Visibility = Visibility.Visible;
                _primaryButton.IsEnabled = true;
                _secondaryButton.IsEnabled = true;
                break;
            case UpdateState.Downloading:
                _titleText.Text = L10n.UpdateDialogDownloadingTitle;
                _bodyText.Text = L10n.UpdateDialogDownloadingDesc;
                _primaryButton.Content = L10n.UpdateDialogRestarting;
                _primaryButton.IsEnabled = false;
                _secondaryButton.IsEnabled = false;
                UpdateProgress();
                break;
            case UpdateState.NoUpdate:
                _titleText.Text = L10n.UpdateDialogNoUpdateTitle;
                _bodyText.Text = L10n.UpdateDialogNoUpdateDesc;
                _primaryButton.Content = L10n.UpdateDialogClose;
                _secondaryButton.Visibility = Visibility.Collapsed;
                _primaryButton.IsEnabled = true;
                break;
            case UpdateState.Error:
                _titleText.Text = L10n.UpdateDialogErrorTitle;
                _bodyText.Text = ErrorMessage(_updater.LastErrorMessage);
                _primaryButton.Content = L10n.UpdateDialogClose;
                _secondaryButton.Visibility = Visibility.Collapsed;
                _primaryButton.IsEnabled = true;
                break;
        }
    }

    private async void PrimaryButton_Click(object sender, RoutedEventArgs e)
    {
        if (_updater.State is not (UpdateState.UpdateAvailable or UpdateState.ReadyToInstall))
        {
            Close();
            return;
        }

        _primaryButton.IsEnabled = false;
        _secondaryButton.IsEnabled = false;
        _setStatus?.Invoke(L10n.MenuDownloading);

        await _updater.DownloadAndInstallAsync();

        if (_updater.State == UpdateState.Error)
        {
            _setStatus?.Invoke(L10n.MenuCheckUpdate);
            ApplyState();
        }
    }

    private void Updater_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => Updater_PropertyChanged(sender, e));
            return;
        }

        if (e.PropertyName == nameof(UpdateService.DownloadProgress))
            UpdateProgress();
        else
            ApplyState();
    }

    private void UpdateProgress()
    {
        var percent = Math.Clamp((int)Math.Round(_updater.DownloadProgress * 100), 0, 100);
        _progressBar.Value = percent;
        _progressText.Text = L10n.UpdateDialogProgress(percent);
    }

    private static string ErrorMessage(string? message)
    {
        return message switch
        {
            "VELOPACK_NOT_INSTALLED" => L10n.UpdateUnavailableDevBuild,
            "NO_UPDATE_READY" or "NO_UPDATE_ASSET" => L10n.UpdateNoReadyPackage,
            null or "" => L10n.UpdateUnknownError,
            _ => L10n.UpdateFailed(message)
        };
    }

    private Brush Brush(string key, Brush fallback) =>
        TryFindResource(key) as Brush ?? fallback;

    private FontFamily Font(string key) =>
        TryFindResource(key) as FontFamily ?? new FontFamily("Segoe UI");

    private void TryDragMove()
    {
        try { DragMove(); }
        catch { }
    }
}
