using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LobsterInput.Helpers;
using LobsterInput.Services;

namespace LobsterInput.Views;

public sealed class FeedbackWindow : Window
{
    private readonly TextBox _contentBox = new();
    private readonly TextBox _phoneBox = new();
    private readonly TextBox _emailBox = new();
    private readonly TextBlock _statusText = new();
    private readonly Button _submitButton = new();

    public FeedbackWindow()
    {
        Title = L10n.FeedbackTitle;
        Width = 520;
        Height = 430;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Icon = new BitmapImage(new Uri("pack://application:,,,/LobsterInput;component/Resources/Images/lobster.ico"));
        Background = Brush("BgDeepBrush");
        Foreground = Brush("TextBrightBrush");
        FontFamily = (FontFamily)Application.Current.FindResource("AppFont");

        var root = new Grid { Margin = new Thickness(24) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new StackPanel { Margin = new Thickness(0, 0, 0, 18) };
        header.Children.Add(new TextBlock
        {
            Text = L10n.FeedbackTitle,
            FontSize = 18,
            FontWeight = FontWeights.Bold,
            Foreground = Brush("NeonGreenBrush")
        });
        header.Children.Add(new TextBlock
        {
            Text = L10n.FeedbackWindowDesc,
            FontSize = 12,
            Foreground = Brush("TextGhostBrush"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0)
        });
        root.Children.Add(header);

        _contentBox.Style = (Style)Application.Current.FindResource("CyberTextBox");
        _contentBox.MinHeight = 150;
        _contentBox.AcceptsReturn = true;
        _contentBox.TextWrapping = TextWrapping.Wrap;
        _contentBox.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        _contentBox.ToolTip = L10n.FeedbackPlaceholder;
        Grid.SetRow(_contentBox, 1);
        root.Children.Add(_contentBox);

        _phoneBox.Style = (Style)Application.Current.FindResource("CyberTextBox");
        _phoneBox.Tag = L10n.FeedbackPhonePlaceholder;
        _phoneBox.Margin = new Thickness(0, 12, 0, 0);
        Grid.SetRow(_phoneBox, 2);
        root.Children.Add(_phoneBox);

        _emailBox.Style = (Style)Application.Current.FindResource("CyberTextBox");
        _emailBox.Tag = L10n.FeedbackEmailPlaceholder;
        _emailBox.Margin = new Thickness(0, 10, 0, 0);
        Grid.SetRow(_emailBox, 3);
        root.Children.Add(_emailBox);

        _statusText.Style = (Style)Application.Current.FindResource("CyberCaption");
        _statusText.Margin = new Thickness(0, 10, 0, 0);
        _statusText.Visibility = Visibility.Collapsed;
        Grid.SetRow(_statusText, 4);
        root.Children.Add(_statusText);

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right
        };
        var cancel = new Button
        {
            Content = L10n.Cancel,
            Style = (Style)Application.Current.FindResource("CyberButtonSecondary"),
            Padding = new Thickness(16, 7, 16, 7),
            Margin = new Thickness(0, 0, 10, 0)
        };
        cancel.Click += (_, _) => Close();
        _submitButton.Content = L10n.FeedbackSubmit;
        _submitButton.Style = (Style)Application.Current.FindResource("CyberButtonPrimary");
        _submitButton.Padding = new Thickness(18, 7, 18, 7);
        _submitButton.Click += async (_, _) => await SubmitAsync();
        actions.Children.Add(cancel);
        actions.Children.Add(_submitButton);
        Grid.SetRow(actions, 5);
        root.Children.Add(actions);

        Content = root;
        Loaded += (_, _) => _contentBox.Focus();
    }

    private async Task SubmitAsync()
    {
        var content = _contentBox.Text.Trim();
        if (string.IsNullOrWhiteSpace(content)) return;

        _submitButton.IsEnabled = false;
        _submitButton.Content = L10n.FeedbackSubmitting;
        _statusText.Visibility = Visibility.Collapsed;

        try
        {
            await ApiClient.Instance.SubmitFeedbackAsync(
                content,
                TrimmedNull(_phoneBox.Text),
                TrimmedNull(_emailBox.Text));
            _contentBox.Text = "";
            _phoneBox.Text = "";
            _emailBox.Text = "";
            _statusText.Text = L10n.FeedbackSuccess;
            _statusText.Foreground = Brush("NeonGreenBrush");
            _statusText.Visibility = Visibility.Visible;
        }
        catch
        {
            _statusText.Text = L10n.FeedbackFailure;
            _statusText.Foreground = Brush("NeonRedBrush");
            _statusText.Visibility = Visibility.Visible;
        }
        finally
        {
            _submitButton.IsEnabled = true;
            _submitButton.Content = L10n.FeedbackSubmit;
        }
    }

    private static string? TrimmedNull(string value)
    {
        var trimmed = value.Trim();
        return string.IsNullOrWhiteSpace(trimmed) ? null : trimmed;
    }

    private static Brush Brush(string key) => (Brush)Application.Current.FindResource(key);
}
