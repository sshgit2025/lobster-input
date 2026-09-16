using System.Diagnostics;
using System.Drawing;
using System.Windows;
using LobsterInput.Helpers;
using Forms = System.Windows.Forms;
using LobsterInput.Stores;
using LobsterInput.ViewModels;
using LobsterInput.Views;

namespace LobsterInput.Services;

public sealed class TrayIconManager : IDisposable
{
    private Forms.NotifyIcon? _trayIcon;
    private TrayMenuWindow? _trayMenu;
    private Window? _mainWindow;
    private Action? _showCurrentWindow;
    private Action? _openSettings;
    private bool _disposed;
    private bool _isUploadingCrash;

    public void Initialize(Window mainWindow)
    {
        _mainWindow = mainWindow;
        _showCurrentWindow = null;
        _openSettings = null;
        InitializeCore();
    }

    public void Initialize(Action showCurrentWindow, Action openSettings)
    {
        _showCurrentWindow = showCurrentWindow;
        _openSettings = openSettings;
        InitializeCore();
    }

    private void InitializeCore()
    {
        _trayIcon = new Forms.NotifyIcon
        {
            Text = TrayText(L10n.AppNameFull),
            Icon = LoadAppIcon() ?? SystemIcons.Application,
            Visible = true
        };

        _trayIcon.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left)
                ShowMainWindow();
            else if (e.Button == Forms.MouseButtons.Right)
                ShowTrayMenu();
        };

        LanguageManager.Instance.PropertyChanged += OnLanguageChanged;

        RefreshCrashCount();
        DebugTrace.Log("TrayIcon", "Initialized native tray icon");
    }

    private void ShowTrayMenu()
    {
        if (_trayIcon == null) return;

        Application.Current?.Dispatcher.Invoke(() =>
        {
            if (_trayMenu?.IsVisible == true)
            {
                _trayMenu.Close();
                return;
            }

            _trayMenu?.Close();
            _trayMenu = new TrayMenuWindow(
                ShowMainWindow,
                OpenSettings,
                CheckForUpdateAsync,
                UploadCrashLogsAsync,
                SelectInputDevice,
                Quit);
            _trayMenu.Closed += (_, _) => _trayMenu = null;
            _trayMenu.ShowNearCursor();
        });
    }

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        if (_trayIcon == null) return;

        _trayIcon.Text = TrayText(L10n.AppNameFull);
        Application.Current?.Dispatcher.Invoke(() => _trayMenu?.Close());
    }

    private void ShowMainWindow()
    {
        if (_showCurrentWindow != null)
        {
            Application.Current?.Dispatcher.Invoke(_showCurrentWindow);
            return;
        }

        if (_mainWindow == null) return;

        Application.Current?.Dispatcher.Invoke(() =>
        {
            _mainWindow.Show();
            if (_mainWindow.WindowState == WindowState.Minimized)
                _mainWindow.WindowState = WindowState.Normal;
            _mainWindow.Activate();
            _mainWindow.Topmost = true;
            _mainWindow.Topmost = false;
            _mainWindow.Focus();
        });
    }

    private void OpenSettings()
    {
        if (_openSettings != null)
        {
            Application.Current?.Dispatcher.Invoke(_openSettings);
            return;
        }

        ShowMainWindow();
        if (_mainWindow is MainWindow win)
            win.NavigateTo(SidebarTab.Settings);
    }

    public void RefreshCrashCount()
    {
        var count = CrashReporterService.Instance.UnreportedCount;
        Application.Current?.Dispatcher.Invoke(() =>
        {
            _trayMenu?.RefreshCrashCount(count, _isUploadingCrash);
        });
    }

    private async Task CheckForUpdateAsync()
    {
        Window? owner = null;
        Application.Current?.Dispatcher.Invoke(() =>
        {
            owner = ResolveUpdateOwner();
            _trayMenu?.Close();
            _trayMenu = null;
        });

        try
        {
            await UpdateInteractionService.CheckDownloadAndInstallAsync(owner: owner);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[TrayIcon] Update check failed: {ex.Message}");
        }
    }

    private Window? ResolveUpdateOwner()
    {
        if (_mainWindow?.IsVisible == true)
            return _mainWindow;

        var app = Application.Current;
        if (app == null)
            return null;

        foreach (Window window in app.Windows)
        {
            if (window.IsVisible && window is not TrayMenuWindow)
                return window;
        }

        return null;
    }

    private async Task UploadCrashLogsAsync()
    {
        if (_isUploadingCrash) return;
        _isUploadingCrash = true;

        _trayMenu?.SetCrashStatus(L10n.MenuCrashUploading, false);

        try
        {
            await CrashReporterService.Instance.UploadUnreportedAsync();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[TrayIcon] Crash upload failed: {ex.Message}");
        }
        finally
        {
            _isUploadingCrash = false;
            RefreshCrashCount();
        }
    }

    private void SelectInputDevice(string? deviceId)
    {
        AudioRecorderService.Instance.SelectInputDevice(deviceId);
    }

    private void Quit()
    {
        DebugTrace.Log("TrayIcon", "Quit requested");
        MainWindow.RequestApplicationShutdown();
    }

    private static Icon? LoadAppIcon()
    {
        var uri = new Uri("pack://application:,,,/LobsterInput;component/Resources/Images/lobster.ico");
        var streamInfo = Application.GetResourceStream(uri);
        if (streamInfo == null) return null;

        using var stream = streamInfo.Stream;
        return new Icon(stream);
    }

    private static string TrayText(string text)
    {
        return text.Length <= 63 ? text : text[..63];
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        LanguageManager.Instance.PropertyChanged -= OnLanguageChanged;

        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null;
        }

        _trayMenu?.Close();
        _trayMenu = null;
        DebugTrace.Log("TrayIcon", "Disposed");
    }
}
