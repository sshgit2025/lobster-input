using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Forms = System.Windows.Forms;
using LobsterInput.Helpers;
using LobsterInput.Services;
using LobsterInput.Stores;

namespace LobsterInput.Views;

public sealed class TrayMenuWindow : Window
{
    private const double MenuWidth = 276;
    private readonly Func<Task> _checkForUpdateAsync;
    private readonly Func<Task> _uploadCrashLogsAsync;
    private readonly Action<string?> _selectInputDevice;
    private readonly TextBlock _updateText = new();
    private readonly TextBlock _crashText = new();
    private Border? _crashRow;
    private Border? _personaRow;
    private Popup? _personaFlyout;
    private StackPanel? _personaPanel;

    public TrayMenuWindow(
        Action showMainWindow,
        Action openSettings,
        Func<Task> checkForUpdateAsync,
        Func<Task> uploadCrashLogsAsync,
        Action<string?> selectInputDevice,
        Action quit)
    {
        _checkForUpdateAsync = checkForUpdateAsync;
        _uploadCrashLogsAsync = uploadCrashLogsAsync;
        _selectInputDevice = selectInputDevice;

        Width = MenuWidth;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Background = Brush("DsBgElevBrush");
        Foreground = Brush("DsFgBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        WindowInteropTools.AttachWindowFramePreferences(this);

        Deactivated += (_, _) =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (IsVisible)
                    Close();
            });
        };

        Closed += (_, _) => ClosePersonaFlyout();

        Content = BuildContent(showMainWindow, openSettings, quit);
    }

    public void ShowNearCursor()
    {
        Show();
        UpdateLayout();
        PlaceNearCursor();
        Activate();
    }

    public void SetUpdateStatus(string text, bool isEnabled)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => SetUpdateStatus(text, isEnabled));
            return;
        }

        _updateText.Text = text;
        SetRowEnabled((Border)_updateText.Tag, isEnabled);
    }

    public void SetCrashStatus(string text, bool isEnabled)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.Invoke(() => SetCrashStatus(text, isEnabled));
            return;
        }

        _crashText.Text = text;
        if (_crashRow != null)
            SetRowEnabled(_crashRow, isEnabled);
    }

    public void RefreshCrashCount(int count, bool isUploading)
    {
        if (isUploading)
        {
            SetCrashStatus(L10n.MenuCrashUploading, false);
            return;
        }

        SetCrashStatus(count > 0 ? L10n.MenuCrashUpload(count) : L10n.MenuCrashNoLog, count > 0);
    }

    private UIElement BuildContent(Action showMainWindow, Action openSettings, Action quit)
    {
        var shell = new Border
        {
            Background = Brush("DsBgElevBrush"),
            BorderBrush = Brush("DsLineStrongBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(4),
            SnapsToDevicePixels = true
        };

        var body = new StackPanel();
        body.Children.Add(ActionRow("\uE8A7", L10n.MenuShowMain, showMainWindow));
        body.Children.Add(ActionRow("\uE713", L10n.MenuOpenSettings, openSettings));

        if (AuthStore.Instance.IsLoggedIn)
        {
            _personaRow = PersonaSubmenuRow();
            body.Children.Add(_personaRow);
        }

        body.Children.Add(Separator());
        body.Children.Add(SectionLabel(L10n.MenuMicrophone));
        body.Children.Add(DeviceRow(L10n.MenuDefaultMicrophone, null, !AudioRecorderService.Instance.InputDevices().Any(d => d.IsSelected)));

        foreach (var device in AudioRecorderService.Instance.InputDevices())
            body.Children.Add(DeviceRow(device.Name, device.Id, device.IsSelected));

        body.Children.Add(Separator());

        var updateRow = StatusActionRow("\uE895", _updateText, L10n.MenuCheckUpdate, _checkForUpdateAsync);
        body.Children.Add(updateRow);

        _crashRow = StatusActionRow("\uE7BA", _crashText, CrashText(), _uploadCrashLogsAsync, CrashReporterService.Instance.UnreportedCount > 0);
        body.Children.Add(_crashRow);
        body.Children.Add(Separator());
        body.Children.Add(ActionRow("\uE8BB", L10n.MenuQuit, quit, true, FontWeights.SemiBold));

        if (_personaRow != null)
        {
            foreach (UIElement child in body.Children)
            {
                if (!ReferenceEquals(child, _personaRow))
                    child.MouseEnter += (_, _) => ClosePersonaFlyout();
            }
        }

        shell.Child = body;
        return shell;
    }

    private Border PersonaSubmenuRow()
    {
        var label = new TextBlock
        {
            Text = L10n.MenuPersona,
            FontSize = 12,
            Foreground = Brush("DsFgBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var glyph = new TextBlock
        {
            Text = "\uE77B",
            FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
            FontSize = 12,
            Foreground = Brush("DsFgMutedBrush"),
            VerticalAlignment = VerticalAlignment.Center
        };
        grid.Children.Add(glyph);

        Grid.SetColumn(label, 1);
        grid.Children.Add(label);

        var chevron = new TextBlock
        {
            Text = "\uE76C",
            FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
            FontSize = 10,
            Foreground = Brush("DsFgMutedBrush"),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(chevron, 2);
        grid.Children.Add(chevron);

        var row = RowShell(true);
        row.Child = grid;

        _personaPanel = new StackPanel();
        var flyoutShell = new Border
        {
            Width = 220,
            Background = Brush("DsBgElevBrush"),
            BorderBrush = Brush("DsLineStrongBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(4),
            SnapsToDevicePixels = true,
            Child = new ScrollViewer
            {
                MaxHeight = 320,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = _personaPanel
            }
        };

        _personaFlyout = new Popup
        {
            PlacementTarget = row,
            Placement = PlacementMode.Right,
            VerticalOffset = -5,
            HorizontalOffset = 2,
            AllowsTransparency = true,
            StaysOpen = true,
            Focusable = false,
            Child = flyoutShell
        };

        RebuildPersonaFlyout();

        row.MouseEnter += (_, _) => OpenPersonaFlyout();
        row.MouseLeftButtonUp += (_, e) =>
        {
            e.Handled = true;
            if (_personaFlyout == null) return;
            if (_personaFlyout.IsOpen)
                ClosePersonaFlyout();
            else
                OpenPersonaFlyout();
        };

        _ = RefreshPersonasAsync();
        return row;
    }

    private void OpenPersonaFlyout()
    {
        if (_personaFlyout != null && IsVisible)
            _personaFlyout.IsOpen = true;
    }

    private void ClosePersonaFlyout()
    {
        if (_personaFlyout != null)
            _personaFlyout.IsOpen = false;
    }

    private async Task RefreshPersonasAsync()
    {
        await PersonaStore.Instance.LoadAsync();
        if (IsVisible)
            RebuildPersonaFlyout();
    }

    private void RebuildPersonaFlyout()
    {
        if (_personaPanel == null) return;

        _personaPanel.Children.Clear();

        var personas = PersonaStore.Instance.Personas;
        var hasActive = personas.Any(p => p.IsActive);

        _personaPanel.Children.Add(PersonaOptionRow(
            L10n.MenuPersonaNone,
            !hasActive,
            () => _ = PersonaStore.Instance.DeactivateAllAsync()));
        _personaPanel.Children.Add(Separator());

        if (personas.Count == 0)
        {
            var emptyLabel = new TextBlock
            {
                Text = L10n.MenuPersonaEmpty,
                FontSize = 12,
                Foreground = Brush("DsFgBrush"),
                TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center
            };
            var emptyRow = RowShell(false);
            emptyRow.Child = RowContent("", emptyLabel);
            _personaPanel.Children.Add(emptyRow);
            return;
        }

        foreach (var persona in personas)
        {
            var id = persona.Id;
            _personaPanel.Children.Add(PersonaOptionRow(
                persona.Name,
                persona.IsActive,
                () => _ = PersonaStore.Instance.ActivateAsync(id)));
        }
    }

    private Border PersonaOptionRow(string text, bool isSelected, Action action)
    {
        var label = new TextBlock
        {
            Text = text,
            FontSize = 12,
            Foreground = Brush("DsFgBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };

        var row = RowShell(true);
        row.Child = RowContent(isSelected ? "\uE73E" : "", label, isSelected);
        row.MouseLeftButtonUp += (_, e) =>
        {
            if (!row.IsEnabled) return;

            e.Handled = true;
            Close();
            action();
        };
        return row;
    }

    private Border ActionRow(string icon, string text, Action action, bool isEnabled = true, FontWeight? fontWeight = null)
    {
        var textBlock = new TextBlock();
        textBlock.Text = text;
        textBlock.FontSize = 12;
        textBlock.FontWeight = fontWeight ?? FontWeights.Normal;
        textBlock.Foreground = Brush("DsFgBrush");
        textBlock.TextTrimming = TextTrimming.CharacterEllipsis;
        textBlock.VerticalAlignment = VerticalAlignment.Center;

        var row = RowShell(isEnabled);
        row.Child = RowContent(icon, textBlock);
        row.MouseLeftButtonUp += (_, e) =>
        {
            if (!row.IsEnabled) return;

            e.Handled = true;
            Close();
            action();
        };
        return row;
    }

    private Border StatusActionRow(string icon, TextBlock textBlock, string text, Func<Task> action, bool isEnabled = true)
    {
        textBlock.Text = text;
        textBlock.Tag = null;
        textBlock.FontSize = 12;
        textBlock.Foreground = Brush("DsFgBrush");
        textBlock.TextTrimming = TextTrimming.CharacterEllipsis;
        textBlock.VerticalAlignment = VerticalAlignment.Center;

        var row = RowShell(isEnabled);
        row.Child = RowContent(icon, textBlock);
        textBlock.Tag = row;
        row.MouseLeftButtonUp += async (_, e) =>
        {
            if (!row.IsEnabled) return;

            e.Handled = true;
            SetRowEnabled(row, false);
            try
            {
                await action();
            }
            finally
            {
                if (IsVisible)
                    SetRowEnabled(row, true);
            }
        };
        return row;
    }

    private Border DeviceRow(string text, string? deviceId, bool isSelected)
    {
        var row = RowShell(true);
        var label = new TextBlock
        {
            Text = text,
            FontSize = 12,
            Foreground = Brush("DsFgBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        row.Child = RowContent(isSelected ? "\uE73E" : "", label, isSelected);
        row.MouseLeftButtonUp += (_, e) =>
        {
            if (!row.IsEnabled) return;

            e.Handled = true;
            _selectInputDevice(deviceId);
            Close();
        };
        return row;
    }

    private static Grid RowContent(string icon, TextBlock label, bool accentIcon = false)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(22) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var glyph = new TextBlock
        {
            Text = icon,
            FontFamily = (FontFamily)Application.Current.FindResource("IconFont"),
            FontSize = 12,
            Foreground = accentIcon ? Brush("DsAccentBrush") : Brush("DsFgMutedBrush"),
            VerticalAlignment = VerticalAlignment.Center
        };
        grid.Children.Add(glyph);

        Grid.SetColumn(label, 1);
        grid.Children.Add(label);
        return grid;
    }

    private Border RowShell(bool isEnabled)
    {
        var row = new Border
        {
            Height = 30,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(10, 0, 10, 0),
            Background = Brushes.Transparent,
            Cursor = Cursors.Hand,
            IsEnabled = isEnabled
        };

        row.MouseEnter += (_, _) =>
        {
            if (row.IsEnabled)
                row.Background = Brush("DsBgHoverBrush");
        };
        row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
        SetRowEnabled(row, isEnabled);
        return row;
    }

    private static void SetRowEnabled(Border row, bool isEnabled)
    {
        row.IsEnabled = isEnabled;
        row.Opacity = isEnabled ? 1 : 0.45;
        row.Cursor = isEnabled ? Cursors.Hand : Cursors.Arrow;
        if (!isEnabled)
            row.Background = Brushes.Transparent;
    }

    private static UIElement SectionLabel(string text)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = 11,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("DsFgMutedBrush"),
            Margin = new Thickness(10, 3, 10, 4)
        };
    }

    private static UIElement Separator()
    {
        return new Border
        {
            Height = 1,
            Background = Brush("DsLineBrush"),
            Margin = new Thickness(6, 4, 6, 4)
        };
    }

    private static string CrashText()
    {
        var count = CrashReporterService.Instance.UnreportedCount;
        return count > 0 ? L10n.MenuCrashUpload(count) : L10n.MenuCrashNoLog;
    }

    private void PlaceNearCursor()
    {
        var cursor = Forms.Cursor.Position;
        var screen = Forms.Screen.FromPoint(cursor);
        var cursorDip = FromDevice(new Point(cursor.X, cursor.Y));
        var workDip = FromDevice(screen.WorkingArea);
        var width = ActualWidth > 0 ? ActualWidth : Width;
        var height = ActualHeight > 0 ? ActualHeight : 260;

        var left = cursorDip.X - width + 12;
        left = Math.Clamp(left, workDip.Left + 8, workDip.Right - width - 8);

        var top = cursorDip.Y - height - 8;
        if (top < workDip.Top + 8)
            top = cursorDip.Y + 8;
        top = Math.Clamp(top, workDip.Top + 8, workDip.Bottom - height - 8);

        Left = left;
        Top = top;
    }

    private Point FromDevice(Point point)
    {
        var source = PresentationSource.FromVisual(this);
        return source?.CompositionTarget?.TransformFromDevice.Transform(point) ?? point;
    }

    private Rect FromDevice(System.Drawing.Rectangle rect)
    {
        var topLeft = FromDevice(new Point(rect.Left, rect.Top));
        var bottomRight = FromDevice(new Point(rect.Right, rect.Bottom));
        return new Rect(topLeft, bottomRight);
    }

    private static Brush Brush(string key)
    {
        return (Brush)Application.Current.FindResource(key);
    }
}
