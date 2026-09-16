using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;
using LobsterInput.Views.Overlays;
using Markdig;

namespace LobsterInput.Views;

public partial class HistoryView : UserControl
{
    private readonly HistoryStore _store = HistoryStore.Instance;
    private readonly HashSet<string> _expandedIds = new();
    private const double ActionIconButtonSize = 22.5;
    private const double ActionIconFontSize = 9.75;
    private const double DetailActionIconButtonSize = 18;
    private const double DetailActionIconFontSize = 9;
    private bool _suppressRetentionEvents;
    private static readonly MarkdownPipeline MarkdownPipeline =
        new MarkdownPipelineBuilder().UseAdvancedExtensions().Build();

    private FontFamily AppFont =>
        TryFindResource("AppFont") as FontFamily ?? SystemFonts.MessageFontFamily;

    public HistoryView()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        _store.PropertyChanged += OnStoreChanged;
        LanguageManager.Instance.PropertyChanged += OnStoreChanged;
        ThemeManager.Instance.PropertyChanged += OnStoreChanged;
        RefreshLabels();
        RefreshRetentionSelection();
        RefreshList();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _store.PropertyChanged -= OnStoreChanged;
        LanguageManager.Instance.PropertyChanged -= OnStoreChanged;
        ThemeManager.Instance.PropertyChanged -= OnStoreChanged;
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(() =>
        {
            RefreshLabels();
            RefreshRetentionSelection();
            RefreshList();
        });
    }

    private void RefreshLabels()
    {
        EmptyText.Text = L10n.NoRecords;
        PageTitle.Text = L10n.PageHistory;
        RecordCountText.Text = L10n.RecCount(_store.TotalCount);
        RetentionTitle.Text = L10n.HistorySaveTitle;
        RetentionSubtitle.Text = L10n.HistorySaveSubtitle;
        PopulateRetentionCombo();
        PrivacyNote.Text = L10n.HistoryPrivacyTitle;
        PrivacyDesc.Text = L10n.HistoryPrivacySubtitle;
    }

    private void PopulateRetentionCombo()
    {
        _suppressRetentionEvents = true;
        RetentionCombo.Items.Clear();
        AddRetentionOption(RetentionPolicy.Forever, L10n.HistoryRetentionForever);
        AddRetentionOption(RetentionPolicy.ThirtyDays, L10n.HistoryRetention30Days);
        AddRetentionOption(RetentionPolicy.SevenDays, L10n.HistoryRetention7Days);
        AddRetentionOption(RetentionPolicy.OneDay, L10n.HistoryRetention1Day);
        AddRetentionOption(RetentionPolicy.Never, L10n.HistoryRetentionNever);
        _suppressRetentionEvents = false;
    }

    private void AddRetentionOption(RetentionPolicy policy, string label)
    {
        RetentionCombo.Items.Add(new ComboBoxItem
        {
            Content = label,
            Tag = policy
        });
    }

    private void RefreshRetentionSelection()
    {
        _suppressRetentionEvents = true;
        for (var i = 0; i < RetentionCombo.Items.Count; i++)
        {
            if (RetentionCombo.Items[i] is ComboBoxItem item &&
                item.Tag is RetentionPolicy policy &&
                policy == _store.RetentionPolicy)
            {
                RetentionCombo.SelectedIndex = i;
                break;
            }
        }
        _suppressRetentionEvents = false;
    }

    private void RefreshList()
    {
        // Records 是「已加载页」，TotalCount 是磁盘上的真实总数。
        var records = _store.Records;
        EmptyText.Visibility = _store.TotalCount == 0
            ? Visibility.Visible : Visibility.Collapsed;
        RecordCountText.Text = L10n.RecCount(_store.TotalCount);

        HistoryList.Items.Clear();
        foreach (var rec in records)
            HistoryList.Items.Add(BuildHistoryItem(rec));

        LoadMoreButton.Visibility = _store.HasMore ? Visibility.Visible : Visibility.Collapsed;
    }

    private UIElement BuildHistoryItem(RecordingHistory rec)
    {
        bool expanded = _expandedIds.Contains(rec.Id);

        var border = new Border
        {
            Background = Brushes.Transparent,
            BorderBrush = BrushFor("DsLineBrush", Color.FromArgb(0x2E, 0x5C, 0x45, 0x29)),
            BorderThickness = new Thickness(0, 0, 0, 1),
            CornerRadius = new CornerRadius(0),
            Padding = new Thickness(0, 14, 0, 14),
            Margin = new Thickness(0),
            Cursor = Cursors.Hand,
            Focusable = true
        };

        var mainStack = new StackPanel();

        var headerGrid = new Grid();
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Auto) });

        var statusDot = BuildStatusDot(rec);
        Grid.SetColumn(statusDot, 0);

        var opLabel = new TextBlock
        {
            Text = rec.OperationDisplayName,
            FontSize = 12,
            FontFamily = AppFont,
            FontWeight = FontWeights.Medium,
            Foreground = BrushFor("TextBrightBrush", Color.FromRgb(0x2C, 0x26, 0x1F)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 0, 0)
        };
        Grid.SetColumn(opLabel, 1);

        var duration = new TextBlock
        {
            Text = rec.ProcessingDuration.HasValue
                ? $"{rec.ProcessingDuration.Value:0.0}s"
                : "",
            FontSize = 11,
            FontFamily = AppFont,
            Foreground = BrushFor("TextGhostBrush", Color.FromRgb(0xA8, 0x9C, 0x87)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(10, 0, 0, 0)
        };
        Grid.SetColumn(duration, 2);

        var timestamp = new TextBlock
        {
            Text = rec.CreatedAt.ToLocalTime().ToString("HH:mm:ss"),
            FontSize = 11,
            FontFamily = AppFont,
            Foreground = BrushFor("TextGhostBrush", Color.FromRgb(0xA8, 0x9C, 0x87)),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8, 0, 0, 0)
        };
        Grid.SetColumn(timestamp, 3);

        var actionPanel = BuildHeaderActionPanel(rec);
        Grid.SetColumn(actionPanel, 5);

        headerGrid.Children.Add(statusDot);
        headerGrid.Children.Add(opLabel);
        headerGrid.Children.Add(duration);
        headerGrid.Children.Add(timestamp);
        headerGrid.Children.Add(actionPanel);

        mainStack.Children.Add(headerGrid);

        var bodyGrid = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        bodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bodyGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var bodyStack = new StackPanel { Margin = new Thickness(0, 0, 32, 0) };

        if (!expanded)
        {
            var previewText = CollapsedPreviewText(rec);
            if (!string.IsNullOrEmpty(previewText))
            {
                var preview = new TextBlock
                {
                    Text = Truncate(previewText, 130),
                    FontSize = 13,
                    FontFamily = AppFont,
                    Foreground = rec.Status == RecordingStatus.Failed
                        ? BrushFor("NeonRedBrush", Color.FromRgb(0xDC, 0x26, 0x26))
                        : BrushFor("TextDimBrush", Color.FromRgb(0x6B, 0x5F, 0x50)),
                    LineHeight = 20,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    TextWrapping = TextWrapping.NoWrap
                };
                bodyStack.Children.Add(preview);
            }
        }
        else
        {
            if (!string.IsNullOrEmpty(rec.Transcript))
            {
                bodyStack.Children.Add(BuildDetailHeader(L10n.LabelTranscript, rec.Transcript));
                bodyStack.Children.Add(new TextBlock
                {
                    Text = rec.Transcript,
                    FontSize = 12, FontFamily = AppFont,
                    Foreground = BrushFor("TextBrightBrush", Color.FromRgb(0x2C, 0x26, 0x1F)),
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 2, 0, 10)
                });
            }

            if (!string.IsNullOrEmpty(rec.Result))
            {
                bodyStack.Children.Add(BuildDetailHeader(L10n.LabelResult, null));
                bodyStack.Children.Add(BuildResultElement(rec));
            }

            if (!string.IsNullOrEmpty(rec.ErrorMessage))
            {
                bodyStack.Children.Add(BuildDetailHeader(L10n.StatusFail, null));
                bodyStack.Children.Add(new TextBlock
                {
                    Text = rec.ErrorMessage,
                    FontSize = 11, FontFamily = AppFont,
                    Foreground = BrushFor("NeonRedBrush", Color.FromRgb(0xDC, 0x26, 0x26)),
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 0, 0, 6)
                });
            }
        }

        Grid.SetColumn(bodyStack, 0);
        bodyGrid.Children.Add(bodyStack);

        if (rec.Status is not RecordingStatus.Processing and not RecordingStatus.Pending)
        {
            var deleteButton = CreateActionButton(
                L10n.Delete,
                "NeonRedBrush",
                Color.FromRgb(0xDC, 0x26, 0x26));
            deleteButton.Tag = rec.Id;
            deleteButton.Click += OnDeleteClick;
            deleteButton.VerticalAlignment = VerticalAlignment.Bottom;
            deleteButton.Margin = new Thickness(0, 0, -4, -4);
            Grid.SetColumn(deleteButton, 1);
            bodyGrid.Children.Add(deleteButton);
        }

        mainStack.Children.Add(bodyGrid);

        border.Child = mainStack;
        border.Tag = rec.Id;
        border.MouseLeftButtonDown += OnItemClick;
        border.KeyDown += OnItemKeyDown;

        return border;
    }

    private UIElement BuildStatusDot(RecordingHistory rec)
    {
        var styleKey = rec.Status == RecordingStatus.Failed
            ? "DsStatusDotDangerStyle"
            : "DsStatusDotSuccessStyle";

        if (rec.Status is RecordingStatus.Pending or RecordingStatus.Processing)
            styleKey = "DsStatusDotStyle";

        return new Ellipse
        {
            Style = Application.Current.TryFindResource(styleKey) as Style,
            VerticalAlignment = VerticalAlignment.Center,
            ToolTip = rec.Status switch
            {
                RecordingStatus.Failed => string.IsNullOrWhiteSpace(rec.ErrorMessage) ? L10n.StatusFail : rec.ErrorMessage,
                RecordingStatus.Pending => L10n.StatusPending,
                RecordingStatus.Processing => L10n.StatusProc,
                _ => L10n.StatusOk
            }
        };
    }

    private UIElement BuildHeaderActionPanel(RecordingHistory rec)
    {
        var actionPanel = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };

        AddCopyButtonIf(
            actionPanel,
            rec.Status == RecordingStatus.Success && !string.IsNullOrWhiteSpace(rec.Result),
            L10n.LabelResult,
            "NeonCyanBrush",
            Color.FromRgb(0x9C, 0x7D, 0x5B),
            rec.Result);

        AddActionButtonIf(
            actionPanel,
            CanRetry(rec),
            L10n.Retry,
            "NeonCyanBrush",
            Color.FromRgb(0x9C, 0x7D, 0x5B),
            rec.Id,
            OnRetryClick);

        AddActionButtonIf(
            actionPanel,
            rec.AudioFileExists,
            L10n.BtnPlayAudio,
            "TextGhostBrush",
            Color.FromRgb(0xA8, 0x9C, 0x87),
            rec.Id,
            OnPlayAudioClick);

        return actionPanel;
    }

    private void AddCopyButtonIf(
        Panel panel,
        bool condition,
        string label,
        string brushKey,
        Color fallback,
        string? text)
    {
        if (!condition || string.IsNullOrWhiteSpace(text)) return;

        var button = CreateActionButton($"{L10n.BtnCopy} {label}", brushKey, fallback);
        button.Tag = text;
        button.Click += OnCopyTextClick;
        button.Margin = new Thickness(panel.Children.Count == 0 ? 0 : 6, 0, 0, 0);
        panel.Children.Add(button);
    }

    private void AddActionButtonIf(
        Panel panel,
        bool condition,
        string text,
        string brushKey,
        Color fallback,
        string tag,
        RoutedEventHandler handler)
    {
        if (!condition) return;
        var button = CreateActionButton(text, brushKey, fallback);
        button.Tag = tag;
        button.Click += handler;
        button.Margin = new Thickness(panel.Children.Count == 0 ? 0 : 6, 0, 0, 0);
        panel.Children.Add(button);
    }

    private static bool CanRetry(RecordingHistory rec) =>
        (rec.Status is RecordingStatus.Success or RecordingStatus.Failed) &&
        rec.Retryable &&
        rec.AudioFileExists;

    private static string? CollapsedPreviewText(RecordingHistory rec)
    {
        return rec.Status switch
        {
            RecordingStatus.Pending or RecordingStatus.Processing => L10n.Processing,
            RecordingStatus.Failed => string.IsNullOrWhiteSpace(rec.ErrorMessage)
                ? L10n.RecognizeFailed
                : rec.ErrorMessage,
            RecordingStatus.Success => !string.IsNullOrWhiteSpace(rec.Result)
                ? (rec.ResultIsMarkdown ? L10n.LabelResult : rec.Result)
                : rec.Transcript,
            _ => null
        };
    }

    private Button CreateActionButton(string text, string brushKey, Color fallback)
    {
        var isDanger = brushKey == "NeonRedBrush";
        var button = new Button
        {
            Content = IconForAction(text),
            ToolTip = text,
            Width = ActionIconButtonSize,
            Height = ActionIconButtonSize,
            FontSize = ActionIconFontSize,
            FontFamily = Application.Current.TryFindResource("IconFont") as FontFamily
                ?? new FontFamily("Segoe MDL2 Assets"),
            Style = Application.Current.TryFindResource(isDanger ? "DsIconDangerHoverButtonStyle" : "DsIconButtonStyle") as Style,
            Padding = new Thickness(0),
            Cursor = Cursors.Hand
        };

        return button;
    }

    private UIElement BuildDetailHeader(string label, string? copyText)
    {
        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 0, 0, 2)
        };

        var title = new TextBlock
        {
            Text = label,
            FontSize = 10,
            FontFamily = AppFont,
            Foreground = BrushFor("TextGhostBrush", Color.FromRgb(0xA8, 0x9C, 0x87)),
            VerticalAlignment = VerticalAlignment.Center
        };
        header.Children.Add(title);

        if (!string.IsNullOrWhiteSpace(copyText))
        {
            var copyButton = CreateActionButton(
                L10n.BtnCopy + " " + label,
                "NeonCyanBrush",
                Color.FromRgb(0x9C, 0x7D, 0x5B));
            copyButton.Width = DetailActionIconButtonSize;
            copyButton.Height = DetailActionIconButtonSize;
            copyButton.FontSize = DetailActionIconFontSize;
            copyButton.Margin = new Thickness(6, -4, 0, -4);
            copyButton.Tag = copyText;
            copyButton.Click += OnCopyTextClick;
            header.Children.Add(copyButton);
        }

        return header;
    }

    private static string IconForAction(string text)
    {
        if (text.Contains(L10n.BtnCopy, StringComparison.OrdinalIgnoreCase))
            return "\uE8C8";
        if (text.Equals(L10n.Retry, StringComparison.OrdinalIgnoreCase))
            return "\uE72C";
        if (text.Equals(L10n.BtnPlayAudio, StringComparison.OrdinalIgnoreCase))
            return "\uE768";
        if (text.Equals(L10n.Delete, StringComparison.OrdinalIgnoreCase))
            return "\uE74D";
        if (text.Equals(L10n.BtnViewInOverlay, StringComparison.OrdinalIgnoreCase))
            return "\uE8A7";
        return "\uE10F";
    }

    private UIElement BuildResultElement(RecordingHistory rec)
    {
        if (rec.ResultIsMarkdown && !string.IsNullOrEmpty(rec.Result))
        {
            var doc = Markdig.Wpf.Markdown.ToFlowDocument(rec.Result, MarkdownPipeline);
            doc.PagePadding = new Thickness(0);
            MarkdownTheme.Apply(doc, this, 12);
            var stack = new StackPanel { Margin = new Thickness(0, 2, 0, 8) };
            stack.Children.Add(new RichTextBox
            {
                Document = doc,
                IsReadOnly = true,
                Background = Brushes.Transparent,
                BorderThickness = new Thickness(0),
                Foreground = BrushFor("TextDimBrush", Color.FromRgb(0x6B, 0x5F, 0x50)),
                FontFamily = AppFont,
                FontSize = 12,
                MaxHeight = 280
            });

            var overlayBtn = CreateActionButton(
                L10n.BtnViewInOverlay, "NeonCyanBrush", Color.FromRgb(0x9C, 0x7D, 0x5B));
            overlayBtn.HorizontalAlignment = HorizontalAlignment.Right;
            overlayBtn.Margin = new Thickness(0, 6, 0, 0);
            overlayBtn.Click += (_, e) =>
            {
                e.Handled = true;
                new ResultOverlay().ShowMarkdown(rec.Result, pinned: true);
            };
            stack.Children.Add(overlayBtn);
            return stack;
        }

        return new TextBlock
        {
            Text = rec.Result,
            FontSize = 12, FontFamily = AppFont,
            Foreground = BrushFor("TextDimBrush", Color.FromRgb(0x6B, 0x5F, 0x50)),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 2, 0, 8)
        };
    }

    private Brush BrushFor(string key, Color fallback)
    {
        return TryFindResource(key) as Brush ?? new SolidColorBrush(fallback);
    }

    private void OnItemClick(object sender, MouseButtonEventArgs e)
    {
        if (IsEventFromButton(e))
            return;

        if (sender is FrameworkElement fe && fe.Tag is string id)
        {
            if (_expandedIds.Contains(id))
                _expandedIds.Remove(id);
            else
                _expandedIds.Add(id);
            RefreshList();
        }
    }

    private void OnItemKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Enter or Key.Space)) return;
        if (sender is not FrameworkElement fe || fe.Tag is not string id) return;

        e.Handled = true;
        if (_expandedIds.Contains(id))
            _expandedIds.Remove(id);
        else
            _expandedIds.Add(id);
        RefreshList();
    }

    private static bool IsEventFromButton(RoutedEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject current)
            return false;

        while (current != null)
        {
            if (current is Button)
                return true;

            current = VisualTreeHelper.GetParent(current);
        }

        return false;
    }

    private void OnRetryClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is not Button btn || btn.Tag is not string id) return;

        var rec = _store.Records.FirstOrDefault(r => r.Id == id);
        if (rec?.AudioFileExists != true) return;

        _store.Update(id, RecordingStatus.Processing, error: null);
        _ = HotKeyHandler.Instance.ProcessRecordAsync(
            rec.Id, rec.Operation, rec.AudioFilePath, rec.SelectedText);
    }

    private void OnCopyTextClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is not Button btn || btn.Tag is not string text) return;
        try
        {
            ClipboardService.SetText(text);
            btn.Content = "\uE73E";
            btn.ToolTip = L10n.BtnCopied;
            btn.Foreground = BrushFor("DsSuccessBrush", Color.FromRgb(0x16, 0xA3, 0x4A));
        }
        catch
        {
            // Clipboard can be locked by another process.
        }
    }

    private void OnDeleteAudioClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is Button btn && btn.Tag is string id)
            _store.DeleteAudioFile(id);
    }

    private void OnPlayAudioClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is not Button btn || btn.Tag is not string id) return;

        var rec = _store.Records.FirstOrDefault(r => r.Id == id);
        if (rec?.AudioFileExists != true || string.IsNullOrWhiteSpace(rec.AudioFilePath)) return;

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = rec.AudioFilePath,
                UseShellExecute = true
            });
        }
        catch
        {
            // The file may have been removed or Windows may not have a registered player.
        }
    }

    private void OnDeleteClick(object sender, RoutedEventArgs e)
    {
        e.Handled = true;
        if (sender is not Button btn || btn.Tag is not string id) return;

        var rec = _store.Records.FirstOrDefault(r => r.Id == id);
        if (rec == null) return;

        if (rec.AudioFileExists)
        {
            var result = AppConfirmDialog.Show(
                Window.GetWindow(this),
                L10n.DeleteConfirm,
                $"{L10n.DeleteRecordAndAudio}\n\n{L10n.DeleteRecordOnly}",
                L10n.DeleteRecordAndAudio,
                L10n.DeleteRecordOnly);
            if (result == AppConfirmDialogResult.Primary)
                _store.Delete(id, deleteAudio: true);
            else if (result == AppConfirmDialogResult.Secondary)
                _store.Delete(id, deleteAudio: false);
        }
        else
        {
            _store.Delete(id);
        }
    }

    private void OnRetentionChanged(object sender, RoutedEventArgs e)
    {
        if (_suppressRetentionEvents) return;

        if (RetentionCombo.SelectedItem is ComboBoxItem item &&
            item.Tag is RetentionPolicy policy)
        {
            _store.RetentionPolicy = policy;
        }
    }

    private void OnLoadMoreClick(object sender, RoutedEventArgs e)
    {
        _store.LoadMore();
        RefreshList();
    }

    private static string GetOperationIcon(string operation) => operation switch
    {
        "transcribe" => "\uE720",
        "rewrite" => "\uE70F",
        "agent" => "\uE99A",
        _ => "\uE8BD"
    };

    private static string Truncate(string text, int maxLen)
    {
        if (text.Length <= maxLen) return text;
        return text[..maxLen] + "...";
    }
}
