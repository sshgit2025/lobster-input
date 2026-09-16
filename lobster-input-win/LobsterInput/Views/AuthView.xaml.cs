using System.Windows;
using System.Windows.Controls;
using LobsterInput.Helpers;
using LobsterInput.ViewModels;

namespace LobsterInput.Views;

public partial class AuthView : UserControl
{
    private bool _suppressLanguageEvent;

    public AuthView()
    {
        InitializeComponent();
        DataContext = new AuthViewModel();
        ApplyLocalization();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    public AuthViewModel ViewModel => (AuthViewModel)DataContext;

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
        TitleText.Text = L10n.AppNameFull;
        SubtitleText.Text = L10n.AuthSubtitle;
        EmailBox.Tag = L10n.EmailPlaceholder;
        CodeBox.Tag = L10n.CodePlaceholder;
        SendCodeBtnText.Text = L10n.SendCode;
        VerifyBtnText.Text = L10n.VerifyAccess;
        ResendBtn.Content = L10n.ResendCode;
        ViewModel.ResendCodeText = L10n.ResendCode;
        TermsLink.Content = L10n.AgreementTerms;
        AndText.Text = L10n.AgreementAnd;
        PrivacyLink.Content = L10n.AgreementPrivacy;
        RefreshLanguageCombo();
    }

    private void RefreshLanguageCombo()
    {
        _suppressLanguageEvent = true;

        if (AuthLanguageCombo.Items.Count == 0)
        {
            foreach (AppLanguage lang in Enum.GetValues<AppLanguage>())
            {
                AuthLanguageCombo.Items.Add(new ComboBoxItem
                {
                    Content = LanguageManager.GetDisplayName(lang),
                    Tag = lang
                });
            }
        }

        var current = LanguageManager.Instance.Current;
        for (var i = 0; i < AuthLanguageCombo.Items.Count; i++)
        {
            if (AuthLanguageCombo.Items[i] is ComboBoxItem item &&
                item.Tag is AppLanguage lang &&
                lang == current)
            {
                AuthLanguageCombo.SelectedIndex = i;
                break;
            }
        }

        _suppressLanguageEvent = false;
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressLanguageEvent) return;
        if (AuthLanguageCombo.SelectedItem is ComboBoxItem item &&
            item.Tag is AppLanguage lang)
        {
            LanguageManager.Instance.Current = lang;
        }
    }

    private void TermsLink_Click(object sender, RoutedEventArgs e)
    {
        var win = new AgreementView();
        win.LoadAgreement("terms", LanguageManager.GetLanguageCode(LanguageManager.Instance.Current));
        win.Owner = Window.GetWindow(this);
        win.ShowDialog();
    }

    private void PrivacyLink_Click(object sender, RoutedEventArgs e)
    {
        var win = new AgreementView();
        win.LoadAgreement("privacy", LanguageManager.GetLanguageCode(LanguageManager.Instance.Current));
        win.Owner = Window.GetWindow(this);
        win.ShowDialog();
    }
}
