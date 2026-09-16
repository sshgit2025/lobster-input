using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Documents;
using LobsterInput.Config;
using LobsterInput.Helpers;
using Markdig;

namespace LobsterInput.Views;

public partial class AgreementView : Window
{
    private static readonly HttpClient Http = new();

    private string _agreementType = "terms";
    private string _lang = "en";

    public AgreementView()
    {
        InitializeComponent();
        WindowInteropTools.AttachWindowFramePreferences(this);
        ApplyLocalization();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        LanguageManager.Instance.PropertyChanged += OnLanguageManagerChanged;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        LanguageManager.Instance.PropertyChanged -= OnLanguageManagerChanged;
    }

    private void OnLanguageManagerChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        Dispatcher.Invoke(ApplyLocalization);
    }

    private void ApplyLocalization()
    {
        LoadingText.Text = L10n.AgreementLoading;
        ErrorText.Text = L10n.AgreementLoadFailed;
        RetryBtn.Content = L10n.Retry;
        CloseBtn.Content = L10n.AgreementClose;
    }

    public void LoadAgreement(string type, string lang)
    {
        _agreementType = type;
        _lang = lang;

        Title = type == "terms" ? L10n.AgreementTerms : L10n.AgreementPrivacy;
        TitleText.Text = Title;

        _ = FetchAndRenderAsync();
    }

    private async Task FetchAndRenderAsync()
    {
        ShowLoading();

        try
        {
            var url = $"{ApiConfig.Agreements.Get}?type={_agreementType}&lang={_lang}";

            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.TryAddWithoutValidation("X-App-Variant", ApiConfig.AppVariant);
            request.Headers.TryAddWithoutValidation("X-Client-Platform", "windows");

            var response = await Http.SendAsync(request);
            response.EnsureSuccessStatusCode();

            var bytes = await response.Content.ReadAsByteArrayAsync();
            var result = JsonSerializer.Deserialize<AgreementResponse>(bytes);

            if (result?.Content is { Length: > 0 } markdown)
            {
                ShowContent(markdown);
            }
            else
            {
                ShowError();
            }
        }
        catch
        {
            ShowError();
        }
    }

    private void ShowLoading()
    {
        LoadingPanel.Visibility = Visibility.Visible;
        ErrorPanel.Visibility = Visibility.Collapsed;
        ContentViewer.Visibility = Visibility.Collapsed;
    }

    private void ShowError()
    {
        LoadingPanel.Visibility = Visibility.Collapsed;
        ErrorPanel.Visibility = Visibility.Visible;
        ContentViewer.Visibility = Visibility.Collapsed;
        ErrorText.Text = L10n.AgreementLoadFailed;
    }

    private void ShowContent(string markdown)
    {
        LoadingPanel.Visibility = Visibility.Collapsed;
        ErrorPanel.Visibility = Visibility.Collapsed;
        ContentViewer.Visibility = Visibility.Visible;

        var pipeline = new MarkdownPipelineBuilder()
            .UseAdvancedExtensions()
            .Build();

        var doc = Markdig.Wpf.Markdown.ToFlowDocument(markdown, pipeline);
        doc.PagePadding = new Thickness(8);
        MarkdownTheme.Apply(doc, this);
        ContentViewer.Document = doc;
    }

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }

    private void RetryBtn_Click(object sender, RoutedEventArgs e)
    {
        _ = FetchAndRenderAsync();
    }

    private class AgreementResponse
    {
        [JsonPropertyName("content")]
        public string Content { get; set; } = "";
    }
}
