using System.ComponentModel;
using System.Windows;
using System.Windows.Threading;
using LobsterInput.Helpers;
using LobsterInput.Services;
using LobsterInput.Stores;
using LobsterInput.ViewModels;
using LobsterInput.Views;

namespace LobsterInput.Lifecycle;

public sealed class ApplicationCoordinator : IDisposable
{
    private TrayIconManager? _trayManager;
    private MainWindow? _mainWindow;
    private AuthWindow? _authWindow;
    private InviteCodeWindow? _inviteCodeWindow;
    private OnboardingWindow? _onboardingWindow;
    private IOverlayPresenter? _overlayPresenter;
    private DispatcherTimer? _autoUpdateTimer;
    private bool _authEventsHooked;
    private bool _disposed;

    public void Start()
    {
        InitializeServices();
        ThemeManager.Instance.ApplyCurrentTheme();

        DebugTrace.Log("AppCoordinator", "Creating main window");
        _mainWindow = new MainWindow();
        DebugTrace.Log("AppCoordinator", "Main window created");

        _trayManager = new TrayIconManager();
        _trayManager.Initialize(ShowCurrentPrimaryWindow, OpenSettingsFromTray);

        _overlayPresenter = new OverlayPresenter(
            HotKeyHandler.Instance,
            HotKeyService.Instance,
            AudioRecorderService.Instance);
        _overlayPresenter.Initialize();

        _ = LoadInitialDataAsync();
    }

    private static void InitializeServices()
    {
        _ = HotKeyService.Instance;
        _ = HotKeyHandler.Instance;
        _ = OpenClawManager.Instance;
        _ = AudioRecorderService.Instance;
        _ = ThemeManager.Instance;

        DebugTrace.Log("AppCoordinator", "Services initialized");
    }

    private async Task LoadInitialDataAsync()
    {
        try
        {
            var startupConfig = await ApiClient.Instance.FetchStartupConfigAsync();
            AuthStore.Instance.UpdateStartupConfig(startupConfig);
            DebugTrace.Log("AppCoordinator", "Startup config loaded");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("AppCoordinator", ex);
        }

        var auth = AuthStore.Instance;
        if (!_authEventsHooked)
        {
            auth.PropertyChanged += OnAuthPropertyChanged;
            _authEventsHooked = true;
        }

        if (auth.IsLoggedIn)
        {
            DebugTrace.Log("AppCoordinator", "User is logged in, starting services");
            StartUserSession();
        }
        else
        {
            DebugTrace.Log("AppCoordinator", "User not logged in, showing auth window");
            RunOnUi(ShowAuthOrInviteWindow);
        }
    }

    private void OnAuthPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(AuthStore.IsLoggedIn)) return;

        if (AuthStore.Instance.IsLoggedIn)
        {
            DebugTrace.Log("AppCoordinator", "User logged in");
            StartUserSession();
            return;
        }

        DebugTrace.Log("AppCoordinator", "User logged out");
        HotKeyService.Instance.StopListening();
        StopBackgroundTimers();
        RecordingResultStore.Instance.Clear();
        HistoryStore.Instance.ClearMemory();
        RunOnUi(ShowAuthOrInviteWindow);
    }

    private void StartUserSession()
    {
        HistoryStore.Instance.ReloadForCurrentUser();
        HotKeyService.Instance.ReloadForCurrentUser();
        HotKeyService.Instance.StartListening();
        RunOnUi(ShowPostLoginWindow);
        _ = LoadUserDataAsync();
        StartBackgroundTimers();
    }

    private async Task LoadUserDataAsync()
    {
        try
        {
            var plan = await ApiClient.Instance.FetchUserPlanInfoAsync();
            AuthStore.Instance.UpdatePlanInfo(plan);
            DebugTrace.Log("AppCoordinator", "User plan loaded");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("AppCoordinator", ex);
        }

        if (!AuthStore.Instance.IsLoggedIn)
            return;

        try
        {
            var recordingConfig = await ApiClient.Instance.FetchRecordingConfigAsync();
            if (recordingConfig.MaxDurationSec > 0)
            {
                AudioRecorderService.Instance.MaxDuration = recordingConfig.MaxDurationSec;
                RealtimeAudioStreamer.Instance.MaxDuration = recordingConfig.MaxDurationSec;
            }
            DebugTrace.Log("AppCoordinator", "Recording config loaded");
        }
        catch (Exception ex)
        {
            DebugTrace.LogError("AppCoordinator", ex);
        }

        if (!AuthStore.Instance.IsLoggedIn)
            return;

        _ = AudioRecorderService.Instance.PrepareAsync();
        _trayManager?.RefreshCrashCount();
    }

    private void StartBackgroundTimers()
    {
        StopBackgroundTimers();

        // OpenClaw 探活由 OpenClawManager 内部定时器统一负责（线程池回调，不占 UI 线程），
        // 此处不再叠加 DispatcherTimer 重复探活：UI 线程周期任务在系统资源紧张时会放大为界面卡死。

        _autoUpdateTimer = new DispatcherTimer { Interval = TimeSpan.FromHours(4) };
        _autoUpdateTimer.Tick += OnAutoUpdateTimerTick;
        _autoUpdateTimer.Start();

        _ = Task.Run(async () =>
        {
            await Task.Delay(10_000);
            try { await UpdateService.Instance.CheckForUpdateAsync(); }
            catch (Exception ex) { DebugTrace.LogError("AppCoordinator", ex); }
        });

        _ = Task.Run(async () =>
        {
            await Task.Delay(5_000);
            try { await CrashReporterService.Instance.UploadUnreportedAsync(); }
            catch (Exception ex) { DebugTrace.LogError("AppCoordinator", ex); }

            RunOnUi(() => _trayManager?.RefreshCrashCount());
        });

        DebugTrace.Log("AppCoordinator", "Background timers started");
    }

    private async void OnAutoUpdateTimerTick(object? sender, EventArgs e)
    {
        try { await UpdateService.Instance.CheckForUpdateAsync(); }
        catch (Exception ex) { DebugTrace.LogError("AppCoordinator", ex); }
    }

    private void StopBackgroundTimers()
    {
        if (_autoUpdateTimer != null)
        {
            _autoUpdateTimer.Tick -= OnAutoUpdateTimerTick;
            _autoUpdateTimer.Stop();
            _autoUpdateTimer = null;
        }
    }

    private void ShowMainWindow()
    {
        if (_mainWindow == null) return;

        CloseAuthWindow();
        CloseInviteCodeWindow();
        CloseOnboardingWindow();

        _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized)
            _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
        _mainWindow.Topmost = true;
        _mainWindow.Topmost = false;
        _mainWindow.Focus();
    }

    private void ShowCurrentPrimaryWindow()
    {
        if (!AuthStore.Instance.IsLoggedIn)
        {
            ShowAuthOrInviteWindow();
            return;
        }

        ShowPostLoginWindow();
    }

    private void OpenSettingsFromTray()
    {
        if (!AuthStore.Instance.IsLoggedIn || !OnboardingManager.IsCompleted)
        {
            ShowCurrentPrimaryWindow();
            return;
        }

        ShowMainWindow();
        _mainWindow?.NavigateTo(SidebarTab.Settings);
    }

    private void ShowAuthOrInviteWindow()
    {
        _mainWindow?.Hide();
        CloseOnboardingWindow();

        var pendingInviteEmail = AuthStore.Instance.PendingInviteEmail;
        if (!string.IsNullOrWhiteSpace(pendingInviteEmail))
        {
            ShowInviteCodeWindow(pendingInviteEmail);
            return;
        }

        ShowAuthWindow();
    }

    private void ShowPostLoginWindow()
    {
        if (!AuthStore.Instance.IsLoggedIn)
        {
            ShowAuthOrInviteWindow();
            return;
        }

        if (!OnboardingManager.IsCompleted)
        {
            ShowOnboardingWindow();
            return;
        }

        ShowMainWindow();
    }

    private void ShowAuthWindow()
    {
        _mainWindow?.Hide();
        CloseInviteCodeWindow();
        CloseOnboardingWindow();

        if (_authWindow == null)
        {
            _authWindow = new AuthWindow();
            _authWindow.AuthView.ViewModel.OnNeedInviteCode += ShowInviteCodeWindow;
        }

        _authWindow.BringStageToFront();
    }

    private void ShowInviteCodeWindow(string email)
    {
        _mainWindow?.Hide();
        CloseAuthWindow();
        CloseOnboardingWindow();

        _inviteCodeWindow = new InviteCodeWindow(email);
        _inviteCodeWindow.InviteCodeView.ViewModel.OnBack += ShowAuthWindow;
        _inviteCodeWindow.BringStageToFront();
    }

    private void ShowOnboardingWindow()
    {
        _mainWindow?.Hide();
        CloseAuthWindow();
        CloseInviteCodeWindow();

        if (_onboardingWindow == null)
        {
            _onboardingWindow = new OnboardingWindow();
            _onboardingWindow.OnboardingView.OnboardingCompleted += OnOnboardingCompleted;
        }

        _onboardingWindow.BringStageToFront();
    }

    private void OnOnboardingCompleted()
    {
        OnboardingManager.MarkCompleted();
        ShowMainWindow();
    }

    private void CloseAuthWindow()
    {
        if (_authWindow != null)
            _authWindow.AuthView.ViewModel.OnNeedInviteCode -= ShowInviteCodeWindow;

        _authWindow?.CloseForTransition();
        _authWindow = null;
    }

    private void CloseInviteCodeWindow()
    {
        if (_inviteCodeWindow != null)
            _inviteCodeWindow.InviteCodeView.ViewModel.OnBack -= ShowAuthWindow;

        _inviteCodeWindow?.CloseForTransition();
        _inviteCodeWindow = null;
    }

    private void CloseOnboardingWindow()
    {
        if (_onboardingWindow != null)
            _onboardingWindow.OnboardingView.OnboardingCompleted -= OnOnboardingCompleted;

        _onboardingWindow?.CloseForTransition();
        _onboardingWindow = null;
    }

    private void CloseWindows()
    {
        _overlayPresenter?.Dispose();
        _overlayPresenter = null;

        CloseAuthWindow();
        CloseInviteCodeWindow();
        CloseOnboardingWindow();
    }

    private static void RunOnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess())
        {
            action();
            return;
        }

        dispatcher.Invoke(action);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        if (_authEventsHooked)
        {
            AuthStore.Instance.PropertyChanged -= OnAuthPropertyChanged;
            _authEventsHooked = false;
        }

        StopBackgroundTimers();
        HotKeyService.Instance.StopListening();
        HotKeyService.Instance.Dispose();

        RunOnUi(CloseWindows);

        _trayManager?.Dispose();
        _trayManager = null;
    }
}
