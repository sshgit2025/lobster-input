using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Media3D;
using LobsterInput.Helpers;
using LobsterInput.Services;
using LobsterInput.Stores;
using LobsterInput.ViewModels;

namespace LobsterInput.Views;

public partial class MainWindow : Window
{
    private static bool s_shutdownRequested;

    private MainViewModel VM => (MainViewModel)DataContext;
    private AccountPopoverWindow? _accountPopover;
    private bool _subscriptionsActive;

    public MainWindow()
    {
        DebugTrace.Log("MainWindow", "ctor begin");
        InitializeComponent();
        WindowChromeCommandBinder.Attach(this);
        WindowInteropTools.AttachWindowFramePreferences(this);
        DebugTrace.Log("MainWindow", "InitializeComponent complete");
        ApplyLocalization();
        DebugTrace.Log("MainWindow", "ApplyLocalization complete");
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        ShowSelectedPage();
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (!_subscriptionsActive)
        {
            LanguageManager.Instance.PropertyChanged += OnLanguageManagerChanged;
            VM.PropertyChanged += OnViewModelChanged;
            AuthStore.Instance.PropertyChanged += OnAuthStoreChanged;
            _subscriptionsActive = true;
        }

        RefreshMainSurface();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (!_subscriptionsActive)
            return;

        LanguageManager.Instance.PropertyChanged -= OnLanguageManagerChanged;
        VM.PropertyChanged -= OnViewModelChanged;
        AuthStore.Instance.PropertyChanged -= OnAuthStoreChanged;
        _subscriptionsActive = false;
    }

    private void OnLanguageManagerChanged(object? sender, PropertyChangedEventArgs e)
    {
        InvokeOnUi(ApplyLocalization);
    }

    private void OnViewModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        InvokeOnUi(() =>
        {
            if (e.PropertyName == nameof(MainViewModel.SelectedTab))
                ShowSelectedPage();
            else if (e.PropertyName is nameof(MainViewModel.IsLoggedIn) or nameof(MainViewModel.UserEmail))
                ApplyLocalization();
        });
    }

    private void OnAuthStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is not (nameof(AuthStore.IsLoggedIn) or nameof(AuthStore.Tier) or nameof(AuthStore.CreditsRemaining) or nameof(AuthStore.CreditsTotal)))
            return;

        InvokeOnUi(() =>
        {
            ApplyLocalization();
            if (AuthStore.Instance.IsLoggedIn && OnboardingManager.IsCompleted)
                ShowSelectedPage();
        });
    }

    private void InvokeOnUi(Action action)
    {
        if (Dispatcher.CheckAccess())
            action();
        else
            Dispatcher.Invoke(action);
    }

    private void ApplyLocalization()
    {
        Title = L10n.AppNameFull;
        AppNameText.Text = L10n.AppNameShort;
        NavHome.Tag = L10n.SidebarHome;
        NavDictionary.Tag = L10n.SidebarDict;
        NavPersona.Tag = L10n.SidebarPersona;
        NavHistory.Tag = L10n.SidebarHistory;
        NavSettings.Tag = L10n.SidebarSettings;
        AccountButton.ToolTip = L10n.AccountTitle;
        SidebarLanguageButton.ToolTip = L10n.LanguageLabel;
        if (!AuthStore.Instance.IsLoggedIn)
        {
            AccountEmailText.Text = L10n.NotLoggedIn;
            AccountPlanText.Text = "";
        }
        else
        {
            AccountEmailText.Text = AuthStore.Instance.Email ?? "";
            AccountPlanText.Text = LocalizedPlanName(AuthStore.Instance.Tier);
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!s_shutdownRequested && Application.Current?.Dispatcher.HasShutdownStarted != true)
        {
            e.Cancel = true;
            Hide();
            return;
        }

        base.OnClosing(e);
    }

    private void Window_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_accountPopover == null)
            return;

        if (IsEventFromAccountButton(e))
            return;

        _accountPopover.Close();
        _accountPopover = null;
        e.Handled = true;
    }

    private bool IsEventFromAccountButton(RoutedEventArgs e)
    {
        if (e.OriginalSource is not DependencyObject current)
            return false;

        while (current != null)
        {
            if (ReferenceEquals(current, AccountButton))
                return true;

            current = current is Visual or Visual3D
                ? VisualTreeHelper.GetParent(current)
                : LogicalTreeHelper.GetParent(current);
        }

        return false;
    }

    private void ClearWindowCursorOverride()
    {
        if (Mouse.OverrideCursor != null)
            Mouse.OverrideCursor = null;

        if (Cursor != null)
            ClearValue(CursorProperty);
    }

    private void AppMenuButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();

        var settings = new MenuItem { Header = L10n.MenuOpenSettings };
        settings.Click += (_, _) => NavigateTo(SidebarTab.Settings);
        menu.Items.Add(settings);

        var update = new MenuItem { Header = L10n.MenuCheckUpdate };
        update.Click += async (_, _) => await CheckForUpdateAndInstallAsync(update, this);
        menu.Items.Add(update);

        menu.Items.Add(new Separator());

        var quit = new MenuItem { Header = L10n.MenuQuit, FontWeight = FontWeights.SemiBold };
        quit.Click += (_, _) => RequestApplicationShutdown();
        menu.Items.Add(quit);

        OpenContextMenu(menu, BtnAppMenu);
    }

    public static void RequestApplicationShutdown()
    {
        s_shutdownRequested = true;
        Application.Current?.Shutdown();
    }

    private static async Task CheckForUpdateAndInstallAsync(MenuItem item, Window owner)
    {
        item.Header = L10n.MenuChecking;
        item.IsEnabled = false;

        try
        {
            await UpdateInteractionService.CheckDownloadAndInstallAsync(text => item.Header = text, owner);
        }
        finally
        {
            item.Header = L10n.MenuCheckUpdate;
            item.IsEnabled = true;
        }
    }

    private void SidebarLanguageButton_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        foreach (AppLanguage lang in Enum.GetValues<AppLanguage>())
        {
            var item = new MenuItem
            {
                Header = LanguageManager.GetDisplayName(lang),
                IsCheckable = true,
                IsChecked = LanguageManager.Instance.Current == lang,
                Tag = lang
            };
            item.Click += (_, _) =>
            {
                if (item.Tag is AppLanguage selected)
                    LanguageManager.Instance.Current = selected;
            };
            menu.Items.Add(item);
        }

        OpenContextMenu(menu, SidebarLanguageButton);
    }

    private void OpenContextMenu(ContextMenu menu, FrameworkElement placementTarget)
    {
        ClearWindowCursorOverride();
        ApplyMenuStyle(menu);
        menu.PlacementTarget = placementTarget;
        menu.Closed += (_, _) => ClearWindowCursorOverride();
        menu.IsOpen = true;
    }

    private void ApplyMenuStyle(ContextMenu menu)
    {
        if (TryFindResource("DsContextMenuStyle") is Style menuStyle)
            menu.Style = menuStyle;

        var itemStyle = TryFindResource("DsMenuItemStyle") as Style;
        var separatorStyle = TryFindResource("DsMenuSeparatorStyle") as Style;

        foreach (var raw in menu.Items)
        {
            if (raw is MenuItem item && itemStyle != null)
                item.Style = itemStyle;
            else if (raw is Separator separator && separatorStyle != null)
                separator.Style = separatorStyle;
        }
    }

    private async void AccountButton_Click(object sender, RoutedEventArgs e)
    {
        e.Handled = true;

        if (!AuthStore.Instance.IsLoggedIn)
            return;

        _accountPopover?.Close();
        _accountPopover = new AccountPopoverWindow(
            () =>
            {
                _accountPopover?.Close();
                AuthSessionManager.LogoutByUser("MainWindow.AccountPopover");
            },
            () =>
            {
                _accountPopover?.Close();
                ShowInviteCodesPopover();
            })
        {
            Owner = this
        };

        var point = AccountButton.PointToScreen(new Point(0, 0));
        _accountPopover.Left = point.X;
        _accountPopover.Top = Math.Max(0, point.Y - _accountPopover.Height - 8);
        _accountPopover.Closed += (_, _) => _accountPopover = null;
        _accountPopover.Show();

        try
        {
            var info = await ApiClient.Instance.FetchUserPlanInfoAsync();
            AuthStore.Instance.UpdatePlanInfo(info);
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("MainWindow.AccountRefresh", ex);
        }
    }

    private void AccountButton_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key is not (Key.Enter or Key.Space))
            return;

        AccountButton_Click(sender, e);
        e.Handled = true;
    }

    private void ShowInviteCodesPopover()
    {
        var win = new Window
        {
            Title = L10n.MyInviteCodesTitle,
            Width = 520,
            Height = 560,
            MinWidth = 460,
            MinHeight = 460,
            Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Icon = Icon,
            Content = new MyInviteCodesView()
        };
        win.Show();
    }

    public void BringToFront()
    {
        RefreshMainSurface();
        Show();
        if (WindowState == WindowState.Minimized)
            WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    private void RefreshMainSurface()
    {
        VM.RefreshState();
        ApplyLocalization();
        ShowSelectedPage();
    }

    public void NavigateTo(SidebarTab tab)
    {
        VM.SelectedTab = tab;
        VM.IsHomeSelected = tab == SidebarTab.Home;
        VM.IsDictionarySelected = tab == SidebarTab.Dictionary;
        VM.IsPersonaSelected = tab == SidebarTab.Persona;
        VM.IsHistorySelected = tab == SidebarTab.History;
        VM.IsSettingsSelected = tab == SidebarTab.Settings;
        ShowSelectedPage();
    }

    private void ShowSelectedPage()
    {
        ContentHost.Children.Clear();

        if (!AuthStore.Instance.IsLoggedIn)
        {
            return;
        }

        if (!OnboardingManager.IsCompleted)
        {
            return;
        }

        UserControl page = VM.SelectedTab switch
        {
            SidebarTab.Dictionary => new DictionaryView(),
            SidebarTab.Persona => new PersonaView(),
            SidebarTab.History => new HistoryView(),
            SidebarTab.Settings => BuildSettingsPage(),
            _ => new HomeView()
        };
        ContentHost.Children.Add(page);
    }

    private SettingsView BuildSettingsPage()
    {
        var settings = new SettingsView();
        settings.NavigateToInviteCodes += () =>
        {
            ContentHost.Children.Clear();
            ContentHost.Children.Add(new MyInviteCodesView());
        };
        return settings;
    }

    private static string LocalizedPlanName(string tier) => tier switch
    {
        "trial" => L10n.PlanTrial,
        "free" => L10n.PlanFree,
        "weekly" => L10n.PlanWeekly,
        "monthly" => L10n.PlanMonthly,
        "yearly" => L10n.PlanYearly,
        "none" => L10n.TierNone,
        _ => string.IsNullOrWhiteSpace(tier) ? L10n.TierNone : tier
    };
}
