using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Stores;

namespace LobsterInput.Views;

public sealed class PersonaEditWindow : Window
{
    private readonly PersonaItem? _item;
    private readonly TextBox _nameBox = new();
    private readonly TextBox _descBox = new();
    private readonly CheckBox _transcribeToggle = new();
    private readonly CheckBox _rewriteToggle = new();
    private readonly CheckBox _intentToggle = new();
    private readonly TextBox _transcribeBox = new();
    private readonly TextBox _rewriteBox = new();
    private readonly TextBox _intentBox = new();
    private readonly Button _saveButton = new();

    public PersonaEditWindow(PersonaItem? item)
    {
        _item = item;
        Title = item == null ? L10n.PersonaNewPersona : L10n.Save;
        Width = 620;
        Height = 680;
        MinWidth = 540;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Background = Brush("BgDeepBrush");
        Foreground = Brush("TextBrightBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");
        WindowInteropTools.AttachWindowFramePreferences(this);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new StackPanel { Margin = new Thickness(32, 28, 32, 22) };
        header.MouseLeftButtonDown += OnDragRegionMouseLeftButtonDown;
        header.Children.Add(new TextBlock
        {
            Text = Title,
            FontSize = 20,
            FontWeight = FontWeights.Bold,
            Foreground = Brush("NeonGreenBrush")
        });
        header.Children.Add(new TextBlock
        {
            Text = L10n.PersonaPageDesc,
            FontSize = 12,
            Foreground = Brush("TextGhostBrush"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0)
        });
        root.Children.Add(header);

        var scroll = new ScrollViewer
        {
            Style = (Style)Application.Current.FindResource("CyberScrollViewer"),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        };
        Grid.SetRow(scroll, 1);
        var body = new StackPanel { Margin = new Thickness(32, 0, 32, 8) };
        body.Children.Add(Field(L10n.PersonaNameLabel, _nameBox, PersonaConstants.NameMaxLength, false, 42));
        body.Children.Add(Field(L10n.PersonaDescLabel, _descBox, PersonaConstants.DescMaxLength, false, 42));
        body.Children.Add(ModuleCard(L10n.PersonaTranscribeTitle, L10n.PersonaTranscribeDesc, _transcribeToggle, _transcribeBox));
        body.Children.Add(ModuleCard(L10n.PersonaRewriteTitle, L10n.PersonaRewriteDesc, _rewriteToggle, _rewriteBox));
        body.Children.Add(ModuleCard(L10n.PersonaIntentTitle, L10n.PersonaIntentDesc, _intentToggle, _intentBox));
        scroll.Content = body;
        root.Children.Add(scroll);

        var actionsBar = new Border
        {
            Background = Brush("BgDeepBrush"),
            Padding = new Thickness(32, 16, 32, 32)
        };
        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        var cancel = new Button
        {
            Content = L10n.Cancel,
            Style = (Style)Application.Current.FindResource("DsButtonDefaultStyle"),
            Padding = new Thickness(16, 0, 16, 0),
            Margin = new Thickness(0, 0, 10, 0)
        };
        cancel.Click += (_, _) => Close();
        _saveButton.Content = L10n.Save;
        _saveButton.Style = (Style)Application.Current.FindResource("DsButtonPrimaryStyle");
        _saveButton.Padding = new Thickness(18, 0, 18, 0);
        _saveButton.Click += async (_, _) => await SaveAsync();
        actions.Children.Add(cancel);
        actions.Children.Add(_saveButton);
        actionsBar.Child = actions;
        Grid.SetRow(actionsBar, 2);
        root.Children.Add(actionsBar);

        Content = root;
        Loaded += (_, _) => LoadValues();
    }

    private void OnDragRegionMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left || e.ButtonState != MouseButtonState.Pressed)
            return;

        DragMove();
    }

    private void LoadValues()
    {
        _nameBox.Text = _item?.Name ?? "";
        _descBox.Text = _item?.Description ?? "";
        var prompts = _item?.Prompts ?? new PersonaPrompts();
        _transcribeToggle.IsChecked = prompts.TranscribeEnabled;
        _transcribeBox.Text = prompts.TranscribePrompt ?? "";
        _rewriteToggle.IsChecked = prompts.RewriteEnabled;
        _rewriteBox.Text = prompts.RewritePrompt ?? "";
        _intentToggle.IsChecked = prompts.IntentEnabled;
        _intentBox.Text = prompts.IntentHint ?? "";
        _nameBox.Focus();
    }

    private UIElement Field(string label, TextBox box, int maxLength, bool multiLine, double height)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
        stack.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush("TextGhostBrush"),
            Margin = new Thickness(0, 0, 0, 6)
        });
        box.Style = (Style)Application.Current.FindResource("CyberTextBox");
        box.MaxLength = maxLength;
        box.Height = height;
        box.TextWrapping = multiLine ? TextWrapping.Wrap : TextWrapping.NoWrap;
        box.AcceptsReturn = multiLine;
        stack.Children.Add(box);
        return stack;
    }

    private UIElement ModuleCard(string title, string desc, CheckBox toggle, TextBox box)
    {
        toggle.VerticalAlignment = VerticalAlignment.Center;
        toggle.HorizontalAlignment = HorizontalAlignment.Right;

        var card = new Border
        {
            Style = (Style)Application.Current.FindResource("CyberCard"),
            Margin = new Thickness(0, 0, 0, 16),
            Padding = new Thickness(20, 16, 20, 16)
        };
        var stack = new StackPanel();
        var head = new Grid();
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 15,
            FontWeight = FontWeights.Bold,
            Foreground = Brush("TextBrightBrush")
        });
        Grid.SetColumn(toggle, 1);
        head.Children.Add(toggle);
        stack.Children.Add(head);
        stack.Children.Add(new TextBlock
        {
            Text = desc,
            FontSize = 12,
            Foreground = Brush("TextGhostBrush"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 5, 0, 10)
        });
        box.Style = (Style)Application.Current.FindResource("CyberTextBox");
        box.MaxLength = PersonaConstants.PromptMaxLength;
        box.MinHeight = 108;
        box.MaxHeight = 180;
        box.AcceptsReturn = true;
        box.TextWrapping = TextWrapping.Wrap;
        box.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        stack.Children.Add(box);
        card.Child = stack;
        return card;
    }

    private async Task SaveAsync()
    {
        var name = _nameBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(name)) return;

        _saveButton.IsEnabled = false;
        var prompts = new PersonaPrompts
        {
            TranscribeEnabled = _transcribeToggle.IsChecked == true,
            TranscribePrompt = TrimmedNull(_transcribeBox.Text),
            RewriteEnabled = _rewriteToggle.IsChecked == true,
            RewritePrompt = TrimmedNull(_rewriteBox.Text),
            IntentEnabled = _intentToggle.IsChecked == true,
            IntentHint = TrimmedNull(_intentBox.Text)
        };

        var ok = _item == null
            ? await PersonaStore.Instance.CreateAsync(name, TrimmedNull(_descBox.Text), prompts) != null
            : await PersonaStore.Instance.UpdateAsync(_item.Id, name, TrimmedNull(_descBox.Text), prompts);

        if (ok)
        {
            DialogResult = true;
            Close();
            return;
        }

        MessageBox.Show(PersonaStore.Instance.ErrorMessage ?? L10n.FeedbackFailure, L10n.AppNameFull);
        _saveButton.IsEnabled = true;
    }

    private static string? TrimmedNull(string value)
    {
        var trimmed = value.Trim();
        return string.IsNullOrWhiteSpace(trimmed) ? null : trimmed;
    }

    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);
}
