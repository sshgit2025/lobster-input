using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;

namespace LobsterInput.Views;

public partial class MyInviteCodesView : UserControl
{
    private List<InviteCodeItem> _codes = new();
    private string? _error;
    private readonly HashSet<string> _copiedCodes = new();

    public MyInviteCodesView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        LanguageManager.Instance.PropertyChanged += OnLangChanged;
        ThemeManager.Instance.PropertyChanged += OnLangChanged;
        RefreshLabels();
        await LoadCodesAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        LanguageManager.Instance.PropertyChanged -= OnLangChanged;
        ThemeManager.Instance.PropertyChanged -= OnLangChanged;
    }

    private void OnLangChanged(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            RefreshLabels();
            RebuildList();
        });
    }

    private void RefreshLabels()
    {
        TitleText.Text = L10n.MyInviteCodesTitle;
        DescText.Text = L10n.MyInviteCodesDesc;
        LoadingText.Text = L10n.Loading;
    }

    private async Task LoadCodesAsync()
    {
        _error = null;
        LoadingText.Visibility = Visibility.Visible;
        ErrorText.Visibility = Visibility.Collapsed;

        try
        {
            _codes = await ApiClient.Instance.FetchMyInviteCodesAsync();
        }
        catch (ApiException ex)
        {
            _error = ex.Message;
        }
        catch (Exception ex)
        {
            _error = ex.Message;
        }

        LoadingText.Visibility = Visibility.Collapsed;

        if (_error != null)
        {
            ErrorText.Text = _error;
            ErrorText.Visibility = Visibility.Visible;
        }

        RebuildList();
    }

    private void RebuildList()
    {
        CodesList.Items.Clear();
        foreach (var code in _codes)
            CodesList.Items.Add(BuildCodeItem(code));
    }

    private UIElement BuildCodeItem(InviteCodeItem code)
    {
        var border = new Border
        {
            Background = BrushFor("DsBgElevBrush", Color.FromRgb(0xFB, 0xF8, 0xF2)),
            BorderBrush = BrushFor("DsLineBrush", Color.FromArgb(0x2E, 0x5C, 0x45, 0x29)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16, 12, 16, 12),
            Margin = new Thickness(0, 0, 0, 10)
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });

        var infoStack = new StackPanel();

        var codeText = new TextBlock
        {
            Text = code.Code,
            FontSize = 15,
            FontWeight = FontWeights.Bold,
            FontFamily = new FontFamily("Consolas"),
            Foreground = code.IsUsed
                ? BrushFor("DsFgSubtleBrush", Color.FromRgb(0xA8, 0x9C, 0x87))
                : BrushFor("DsAccentBrush", Color.FromRgb(0x9C, 0x7D, 0x5B)),
            Margin = new Thickness(0, 0, 0, 2)
        };
        infoStack.Children.Add(codeText);

        var statusBrush = code.IsUsed
            ? BrushFor("DsFgSubtleBrush", Color.FromRgb(0xA8, 0x9C, 0x87))
            : BrushFor("DsSuccessBrush", Color.FromRgb(0x16, 0xA3, 0x4A));
        var statusText = code.IsUsed ? L10n.MyInviteCodeUsed : L10n.MyInviteCodeUnused;

        var statusRow = new StackPanel { Orientation = Orientation.Horizontal };
        statusRow.Children.Add(new Ellipse
        {
            Width = 6, Height = 6,
            Fill = statusBrush,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 5, 0)
        });
        statusRow.Children.Add(new TextBlock
        {
            Text = statusText,
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            Foreground = statusBrush
        });
        infoStack.Children.Add(statusRow);

        if (code.IsUsed && !string.IsNullOrEmpty(code.UsedBy))
        {
            var usedByText = new TextBlock
            {
                Text = $"{L10n.MyInviteCodeUsedBy}: {code.UsedBy}",
                FontSize = 10,
                FontFamily = new FontFamily("Consolas"),
                Foreground = BrushFor("DsFgSubtleBrush", Color.FromRgb(0xA8, 0x9C, 0x87)),
                Margin = new Thickness(0, 2, 0, 0)
            };
            infoStack.Children.Add(usedByText);
        }

        Grid.SetColumn(infoStack, 0);
        grid.Children.Add(infoStack);

        if (!code.IsUsed)
        {
            bool copied = _copiedCodes.Contains(code.Code);
            var copyBtn = new Button
            {
                Content = copied ? L10n.MyInviteCodeCopied : L10n.BtnCopy,
                FontSize = 11,
                FontFamily = new FontFamily("Consolas"),
                Style = TryFindResource("DsButtonDefaultStyle") as Style,
                Foreground = copied
                    ? BrushFor("DsFgSubtleBrush", Color.FromRgb(0xA8, 0x9C, 0x87))
                    : BrushFor("DsAccentBrush", Color.FromRgb(0x9C, 0x7D, 0x5B)),
                Padding = new Thickness(10, 4, 10, 4),
                Cursor = Cursors.Hand,
                VerticalAlignment = VerticalAlignment.Center,
                Tag = code.Code
            };
            copyBtn.Click += OnCopyClick;
            Grid.SetColumn(copyBtn, 2);
            grid.Children.Add(copyBtn);
        }

        border.Child = grid;
        return border;
    }

    private Brush BrushFor(string key, Color fallback)
    {
        return TryFindResource(key) as Brush ?? new SolidColorBrush(fallback);
    }

    private async void OnCopyClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button btn || btn.Tag is not string code) return;

        ClipboardService.SetText(code);
        _copiedCodes.Add(code);
        RebuildList();

        await Task.Delay(2000);
        _copiedCodes.Remove(code);
        Dispatcher.Invoke(RebuildList);
    }
}
