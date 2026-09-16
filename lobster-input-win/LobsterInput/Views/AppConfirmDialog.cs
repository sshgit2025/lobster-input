using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LobsterInput.Helpers;

namespace LobsterInput.Views;

public enum AppConfirmDialogResult
{
    None,
    Primary,
    Secondary
}

public sealed class AppConfirmDialog : Window
{
    private AppConfirmDialogResult _result = AppConfirmDialogResult.None;

    private AppConfirmDialog(
        string title,
        string message,
        string primaryText,
        string? secondaryText,
        string cancelText)
    {
        Title = title;
        Width = secondaryText == null ? 360 : 440;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Background = Brush("DsBgBrush");
        Foreground = Brush("DsFgBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        WindowInteropTools.AttachWindowFramePreferences(this);

        var root = new Grid
        {
            Background = Brush("DsBgBrush"),
            SnapsToDevicePixels = true,
            UseLayoutRounding = true
        };
        root.MouseLeftButtonDown += OnDragRegionMouseLeftButtonDown;

        var layout = new Grid
        {
            Margin = new Thickness(28, 24, 28, 22)
        };
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var titleBlock = new TextBlock
        {
            Text = title,
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("DsFgBrush"),
            Margin = new Thickness(0, 0, 0, 10)
        };
        layout.Children.Add(titleBlock);

        var messageBlock = new TextBlock
        {
            Text = message,
            FontSize = 13,
            Foreground = Brush("DsFgMutedBrush"),
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20,
            MaxWidth = secondaryText == null ? 316 : 396
        };
        Grid.SetRow(messageBlock, 1);
        layout.Children.Add(messageBlock);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 22, 0, 0)
        };

        var cancel = CreateButton(cancelText, "DsButtonDefaultStyle");
        cancel.IsCancel = true;
        cancel.Click += (_, _) => CloseWith(AppConfirmDialogResult.None);
        actions.Children.Add(cancel);

        if (!string.IsNullOrWhiteSpace(secondaryText))
        {
            var secondary = CreateButton(secondaryText, "DsButtonDefaultStyle");
            secondary.Margin = new Thickness(10, 0, 0, 0);
            secondary.Click += (_, _) => CloseWith(AppConfirmDialogResult.Secondary);
            actions.Children.Add(secondary);
        }

        var primary = CreateDangerButton(primaryText);
        primary.Margin = new Thickness(10, 0, 0, 0);
        primary.IsDefault = true;
        primary.Click += (_, _) => CloseWith(AppConfirmDialogResult.Primary);
        actions.Children.Add(primary);

        Grid.SetRow(actions, 2);
        layout.Children.Add(actions);
        root.Children.Add(layout);
        Content = root;
    }

    public static AppConfirmDialogResult Show(
        Window? owner,
        string title,
        string message,
        string primaryText,
        string? secondaryText = null,
        string? cancelText = null)
    {
        var dialog = new AppConfirmDialog(
            title,
            message,
            primaryText,
            secondaryText,
            cancelText ?? L10n.Cancel);

        if (owner != null)
            dialog.Owner = owner;

        return dialog.ShowDialog() == true
            ? dialog._result
            : AppConfirmDialogResult.None;
    }

    private static Button CreateButton(string text, string styleKey) =>
        new()
        {
            Content = text,
            MinWidth = 74,
            Height = 36,
            Padding = new Thickness(16, 0, 16, 0),
            Style = (Style)Application.Current.FindResource(styleKey),
            Cursor = Cursors.Hand
        };

    private static Button CreateDangerButton(string text)
    {
        var button = CreateButton(text, "DsButtonDangerStyle");
        button.BorderBrush = Brush("DsDangerRingBrush");
        button.BorderThickness = new Thickness(1);
        button.Background = Brush("DsDangerSoftBrush");
        return button;
    }

    private void CloseWith(AppConfirmDialogResult result)
    {
        _result = result;
        DialogResult = result != AppConfirmDialogResult.None;
    }

    private void OnDragRegionMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || e.ButtonState != MouseButtonState.Pressed)
            return;

        if (e.OriginalSource is DependencyObject source && IsInsideButton(source))
            return;

        DragMove();
    }

    private static bool IsInsideButton(DependencyObject current)
    {
        while (current != null)
        {
            if (current is Button)
                return true;

            current = VisualTreeHelper.GetParent(current);
        }

        return false;
    }

    private static Brush Brush(string key) =>
        Application.Current.TryFindResource(key) as Brush ?? Brushes.Transparent;
}
