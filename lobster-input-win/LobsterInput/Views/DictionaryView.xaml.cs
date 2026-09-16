using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;

namespace LobsterInput.Views;

public partial class DictionaryView : UserControl
{
    private readonly DictionaryStore _store = DictionaryStore.Instance;
    private CancellationTokenSource? _searchCts;
    private bool _suppressSearchEvent;

    public string EditTooltip => L10n.EditHotword;
    public string DeleteTooltip => L10n.Delete;

    public DictionaryView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        _store.PropertyChanged += OnStoreChanged;
        LanguageManager.Instance.PropertyChanged += OnStoreChanged;
        ThemeManager.Instance.PropertyChanged += OnStoreChanged;
        RefreshLabels();
        await _store.LoadAsync();
        RefreshList();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _store.PropertyChanged -= OnStoreChanged;
        LanguageManager.Instance.PropertyChanged -= OnStoreChanged;
        ThemeManager.Instance.PropertyChanged -= OnStoreChanged;
        _searchCts?.Cancel();
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            RefreshLabels();
            RefreshList();
        });
    }

    private void RefreshLabels()
    {
        DictionaryPageTitle.Text = L10n.PageDict;
        DescText.Text = L10n.DictDesc;
        AddButton.Content = L10n.Add;
        NewWordInput.Tag = L10n.DictPlaceholder;
        SearchInput.Tag = L10n.DictSearchPlaceholder;
        ClearSearchBtn.Content = "\uE711";
        ClearSearchBtn.ToolTip = L10n.Cancel;
        LoadingText.Text = L10n.Loading;
        EmptyText.Text = L10n.DictEmpty;
        EmptyDescriptionText.Text = L10n.DictDesc;
    }

    private void RefreshList()
    {
        LoadingText.Visibility = _store.IsLoading ? Visibility.Visible : Visibility.Collapsed;

        if (!_store.IsLoading && _store.HotWords.Count == 0)
        {
            EmptyText.Text = string.IsNullOrWhiteSpace(_store.SearchText)
                ? L10n.DictEmpty
                : L10n.DictNoResult;
            EmptyPanel.Visibility = Visibility.Visible;
            WordsList.Visibility = Visibility.Collapsed;
        }
        else
        {
            EmptyPanel.Visibility = Visibility.Collapsed;
            WordsList.Visibility = _store.IsLoading ? Visibility.Collapsed : Visibility.Visible;
        }

        WordsList.ItemsSource = null;
        WordsList.ItemsSource = _store.HotWords;

        if (_store.ErrorMessage != null)
        {
            ErrorText.Text = _store.ErrorMessage;
            ErrorText.Visibility = Visibility.Visible;
        }
        else
        {
            ErrorText.Visibility = Visibility.Collapsed;
        }

        PageInfoText.Text = L10n.DictPageInfo(_store.CurrentPage, _store.TotalPages);
        PaginationPanel.Visibility = _store.TotalPages > 1 ? Visibility.Visible : Visibility.Collapsed;
        PrevPageBtn.IsEnabled = _store.HasPrev && !_store.IsLoading;
        NextPageBtn.IsEnabled = _store.HasNext && !_store.IsLoading;
        ClearSearchBtn.Visibility = string.IsNullOrWhiteSpace(SearchInput.Text)
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void OnNewWordKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
            _ = AddWordAsync();
    }

    private void OnAddClick(object sender, RoutedEventArgs e)
    {
        var dialog = new HotWordEditWindow(null) { Owner = Window.GetWindow(this) };
        dialog.ShowDialog();
    }

    private async void OnSearchTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressSearchEvent) return;

        _store.SearchText = SearchInput.Text.Trim();
        _searchCts?.Cancel();
        _searchCts = new CancellationTokenSource();
        var token = _searchCts.Token;

        try
        {
            await Task.Delay(300, token);
            if (!token.IsCancellationRequested)
                await _store.SearchAsync();
        }
        catch (TaskCanceledException)
        {
        }
    }

    private async Task AddWordAsync()
    {
        var word = NewWordInput.Text.Trim();
        if (string.IsNullOrEmpty(word)) return;
        if (word.Length > DictionaryStore.MaxWordLength) return;

        AddButton.IsEnabled = false;
        var ok = await _store.AddAsync(word);
        if (ok) NewWordInput.Text = "";
        AddButton.IsEnabled = true;
    }

    private void OnClearSearchClick(object sender, RoutedEventArgs e)
    {
        _suppressSearchEvent = true;
        SearchInput.Text = "";
        _suppressSearchEvent = false;
        _store.SearchText = "";
        _ = _store.SearchAsync();
    }

    private async void OnPrevPageClick(object sender, RoutedEventArgs e)
    {
        await _store.PrevPageAsync();
    }

    private async void OnNextPageClick(object sender, RoutedEventArgs e)
    {
        await _store.NextPageAsync();
    }

    private void OnEditClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not HotWordItem item) return;

        var dialog = new HotWordEditWindow(item) { Owner = Window.GetWindow(this) };
        dialog.ShowDialog();
    }

    private async void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not HotWordItem item) return;

        var msg = L10n.ConfirmDeleteHotword(item.Word);
        var result = AppConfirmDialog.Show(
            Window.GetWindow(this),
            L10n.Delete,
            msg,
            L10n.Delete);
        if (result == AppConfirmDialogResult.Primary)
            await _store.DeleteAsync(item.Id);
    }
}

public class EditHotWordDialog : Window
{
    public string ResultWord { get; private set; } = "";
    private readonly TextBox _input;

    public EditHotWordDialog(string currentWord)
    {
        Title = L10n.EditHotword;
        Width = 360;
        Height = 160;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        Background = BrushFor("BgDeepBrush", System.Windows.Media.Color.FromRgb(0xF4, 0xEF, 0xE7));

        var sp = new StackPanel { Margin = new Thickness(20) };

        _input = new TextBox
        {
            Text = currentWord,
            FontSize = 14,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            Background = BrushFor("BgCardBrush", System.Windows.Media.Color.FromRgb(0xFB, 0xF8, 0xF2)),
            Foreground = BrushFor("TextBrightBrush", System.Windows.Media.Color.FromRgb(0x2C, 0x26, 0x1F)),
            BorderBrush = BrushFor("BorderDimBrush", System.Windows.Media.Color.FromArgb(0x2E, 0x5C, 0x45, 0x29)),
            Padding = new Thickness(8, 6, 8, 6),
            MaxLength = DictionaryStore.MaxWordLength
        };
        sp.Children.Add(_input);

        var btnPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 12, 0, 0)
        };

        var cancelBtn = new Button
        {
            Content = L10n.Cancel,
            Padding = new Thickness(16, 6, 16, 6),
            Background = System.Windows.Media.Brushes.Transparent,
            Foreground = BrushFor("TextDimBrush", System.Windows.Media.Color.FromRgb(0x6B, 0x5F, 0x50)),
            BorderThickness = new Thickness(0),
            Cursor = System.Windows.Input.Cursors.Hand
        };
        cancelBtn.Click += (_, _) => DialogResult = false;

        var saveBtn = new Button
        {
            Content = L10n.Save,
            Padding = new Thickness(16, 6, 16, 6),
            Margin = new Thickness(8, 0, 0, 0),
            Background = BrushFor("ActiveTabBgBrush", System.Windows.Media.Color.FromArgb(0x1A, 0x9C, 0x7D, 0x5B)),
            Foreground = BrushFor("NeonCyanBrush", System.Windows.Media.Color.FromRgb(0x9C, 0x7D, 0x5B)),
            BorderBrush = BrushFor("NeonCyanBrush", System.Windows.Media.Color.FromRgb(0x9C, 0x7D, 0x5B)),
            BorderThickness = new Thickness(1),
            Cursor = System.Windows.Input.Cursors.Hand
        };
        saveBtn.Click += (_, _) =>
        {
            ResultWord = _input.Text;
            DialogResult = true;
        };

        btnPanel.Children.Add(cancelBtn);
        btnPanel.Children.Add(saveBtn);
        sp.Children.Add(btnPanel);

        Content = sp;
    }

    private static System.Windows.Media.Brush BrushFor(string key, System.Windows.Media.Color fallback)
    {
        return Application.Current.TryFindResource(key) as System.Windows.Media.Brush
               ?? new System.Windows.Media.SolidColorBrush(fallback);
    }
}
