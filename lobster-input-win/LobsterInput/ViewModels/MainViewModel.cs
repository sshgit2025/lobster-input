using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using LobsterInput.Services;
using LobsterInput.Stores;

namespace LobsterInput.ViewModels;

public enum SidebarTab
{
    Home,
    Dictionary,
    Persona,
    History,
    Settings
}

public sealed partial class MainViewModel : ObservableObject
{
    [ObservableProperty]
    private SidebarTab _selectedTab = SidebarTab.Home;

    [ObservableProperty]
    private bool _isLoggedIn;

    [ObservableProperty]
    private string _userEmail = "";

    [ObservableProperty]
    private bool _isHomeSelected = true;

    [ObservableProperty]
    private bool _isDictionarySelected;

    [ObservableProperty]
    private bool _isPersonaSelected;

    [ObservableProperty]
    private bool _isHistorySelected;

    [ObservableProperty]
    private bool _isSettingsSelected;

    public MainViewModel()
    {
        var auth = AuthStore.Instance;
        IsLoggedIn = auth.IsLoggedIn;
        UserEmail = auth.Email ?? "";

        auth.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AuthStore.IsLoggedIn) or nameof(AuthStore.Email))
            {
                IsLoggedIn = auth.IsLoggedIn;
                UserEmail = auth.Email ?? "";
            }
        };
    }

    [RelayCommand]
    private void SwitchTab(string tabName)
    {
        if (!Enum.TryParse<SidebarTab>(tabName, out var tab))
            return;

        SelectedTab = tab;
        IsHomeSelected = tab == SidebarTab.Home;
        IsDictionarySelected = tab == SidebarTab.Dictionary;
        IsPersonaSelected = tab == SidebarTab.Persona;
        IsHistorySelected = tab == SidebarTab.History;
        IsSettingsSelected = tab == SidebarTab.Settings;
    }

    [RelayCommand]
    private void Logout()
    {
        AuthSessionManager.LogoutByUser("MainViewModel");
    }

    public void RefreshState()
    {
        var auth = AuthStore.Instance;
        IsLoggedIn = auth.IsLoggedIn;
        UserEmail = auth.Email ?? "";
    }
}

public class BoolToColorConverter : IValueConverter
{
    public string TrueColor { get; set; } = "#9C7D5B";
    public string FalseColor { get; set; } = "#D97706";

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture)
    {
        var isTrue = value is true;
        var hex = isTrue ? TrueColor : FalseColor;
        return (Color)ColorConverter.ConvertFromString(hex);
    }

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture)
    {
        throw new NotSupportedException();
    }
}
