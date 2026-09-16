using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Stores;

namespace LobsterInput.Views;

public sealed class HotWordEditWindow : Window
{
    private readonly HotWordItem? _item;
    private readonly TextBox _wordBox = new();
    private readonly TextBlock _countText = new();
    private readonly Button _saveButton = new();

    public HotWordEditWindow(HotWordItem? item)
    {
        _item = item;
        Title = item == null ? L10n.NewHotword : L10n.EditHotword;
        Width = 480;
        Height = 280;
        MinWidth = 420;
        MinHeight = 270;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Background = Brush("BgDeepBrush");
        Foreground = Brush("TextBrightBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        WindowInteropTools.AttachWindowFramePreferences(this);

        var root = new Grid { Margin = new Thickness(32) };
        root.MouseLeftButtonDown += OnDragRegionMouseLeftButtonDown;
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var title = new TextBlock
        {
            Text = Title,
            FontSize = 20,
            FontWeight = FontWeights.Bold,
            Foreground = Brush("NeonGreenBrush"),
            Margin = new Thickness(0, 0, 0, 24)
        };
        root.Children.Add(title);

        var labelRow = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        labelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        labelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetRow(labelRow, 1);
        var label = new TextBlock
        {
            Text = L10n.DictStandardWord,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("TextDimBrush")
        };
        _countText.FontSize = 12;
        _countText.Foreground = Brush("TextGhostBrush");
        Grid.SetColumn(_countText, 1);
        labelRow.Children.Add(label);
        labelRow.Children.Add(_countText);
        root.Children.Add(labelRow);

        _wordBox.Style = (Style)Application.Current.FindResource("CyberTextBox");
        _wordBox.MaxLength = DictionaryStore.MaxWordLength;
        _wordBox.Text = item?.Word ?? "";
        _wordBox.Tag = L10n.DictPlaceholder;
        _wordBox.TextChanged += (_, _) => RefreshState();
        _wordBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && _saveButton.IsEnabled)
                _ = SaveAsync();
        };
        Grid.SetRow(_wordBox, 2);
        root.Children.Add(_wordBox);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 18, 0, 0)
        };
        var cancel = new Button
        {
            Content = L10n.Cancel,
            Style = (Style)Application.Current.FindResource("DsButtonDefaultStyle"),
            Padding = new Thickness(16, 0, 16, 0),
            Margin = new Thickness(0, 0, 10, 0)
        };
        cancel.Click += (_, _) => Close();
        _saveButton.Content = item == null ? L10n.Add : L10n.Save;
        _saveButton.Style = (Style)Application.Current.FindResource("DsButtonPrimaryStyle");
        _saveButton.Padding = new Thickness(18, 0, 18, 0);
        _saveButton.Click += async (_, _) => await SaveAsync();
        actions.Children.Add(cancel);
        actions.Children.Add(_saveButton);
        Grid.SetRow(actions, 4);
        root.Children.Add(actions);

        Content = root;
        Loaded += (_, _) =>
        {
            RefreshState();
            _wordBox.Focus();
            _wordBox.SelectAll();
        };
    }

    private void OnDragRegionMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || e.ButtonState != MouseButtonState.Pressed)
            return;

        DragMove();
    }

    private void RefreshState()
    {
        var trimmed = _wordBox.Text.Trim();
        _countText.Text = L10n.CharCount(trimmed.Length, DictionaryStore.MaxWordLength);
        _countText.Foreground = trimmed.Length > DictionaryStore.MaxWordLength
            ? Brush("NeonRedBrush")
            : Brush("TextGhostBrush");
        _saveButton.IsEnabled = !string.IsNullOrWhiteSpace(trimmed)
                                && trimmed.Length <= DictionaryStore.MaxWordLength;
    }

    private async Task SaveAsync()
    {
        var word = _wordBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(word)) return;

        _saveButton.IsEnabled = false;
        var ok = _item == null
            ? await DictionaryStore.Instance.AddAsync(word)
            : await DictionaryStore.Instance.UpdateAsync(_item.Id, word);

        if (ok)
        {
            DialogResult = true;
            Close();
            return;
        }

        MessageBox.Show(DictionaryStore.Instance.ErrorMessage ?? L10n.FeedbackFailure, L10n.AppNameFull);
        _saveButton.IsEnabled = true;
    }

    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);
}
