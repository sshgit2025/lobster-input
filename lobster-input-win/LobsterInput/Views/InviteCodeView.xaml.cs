using System.Windows.Controls;
using System.Windows;
using LobsterInput.Helpers;
using LobsterInput.ViewModels;

namespace LobsterInput.Views;

public partial class InviteCodeView : UserControl
{
    public InviteCodeView()
    {
        InitializeComponent();
        DataContext = new InviteCodeViewModel();
        ApplyLocalization();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    public InviteCodeViewModel ViewModel => (InviteCodeViewModel)DataContext;

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
        PageSubtitle.Text = L10n.InvitePageSubtitle;
        PageTitle.Text = L10n.InvitePageTitle;
        WelcomeHeading.Text = L10n.InviteWelcomeHeading;
        BodyLine1.Text = L10n.InviteBodyLine1;
        BodyLine2.Text = L10n.InviteBodyLine2;
        InviteCodeBox.Tag = L10n.InviteCodePlaceholder;
        SubmitBtnText.Text = L10n.InviteSubmitBtn;
        BackBtn.Content = L10n.InviteBackBtn;
    }
}
