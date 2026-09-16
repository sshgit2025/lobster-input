using System.Diagnostics;
using System.Reflection;
using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Config;
using LobsterInput.Views;
using Velopack;

namespace LobsterInput.Services;

public class AppUpdateInfo
{
    public string Version { get; set; } = "";
    public string DownloadUrl { get; set; } = "";
    public string? ReleaseNotes { get; set; }
}

public enum UpdateState
{
    Idle,
    Checking,
    UpdateAvailable,
    Downloading,
    ReadyToInstall,
    NoUpdate,
    Error
}

public sealed partial class UpdateService : ObservableObject
{
    [ObservableProperty]
    private UpdateState _state = UpdateState.Idle;

    [ObservableProperty]
    private AppUpdateInfo? _availableUpdate;

    [ObservableProperty]
    private double _downloadProgress;

    private readonly UpdateManager _manager = new(ApiConfig.Update.VelopackFeedUrl);
    private Velopack.UpdateInfo? _pendingUpdate;

    public static UpdateService Instance { get; } = new();
    public string? LastErrorMessage { get; private set; }

    private UpdateService()
    {
    }

    public void SetError(string message)
    {
        LastErrorMessage = message;
        State = UpdateState.Error;
    }

    public string CurrentVersion
    {
        get
        {
            if (_manager.CurrentVersion != null)
                return _manager.CurrentVersion.ToString();

            var ver = Assembly.GetExecutingAssembly().GetName().Version;
            return ver?.ToString(3) ?? "0.0.0";
        }
    }

    public bool IsVelopackInstalled => _manager.IsInstalled;

    public async Task CheckForUpdateAsync()
    {
        if (State is UpdateState.Checking or UpdateState.Downloading)
            return;

        State = UpdateState.Checking;
        AvailableUpdate = null;
        _pendingUpdate = null;
        DownloadProgress = 0;
        LastErrorMessage = null;

        try
        {
            if (!_manager.IsInstalled)
            {
                LastErrorMessage = "VELOPACK_NOT_INSTALLED";
                State = UpdateState.Error;
                Debug.WriteLine("[Update] Velopack package is not installed; update is unavailable in unpackaged dev builds.");
                return;
            }

            if (_manager.UpdatePendingRestart is { } pendingRestart)
            {
                AvailableUpdate = FromVelopackAsset(pendingRestart);
                State = UpdateState.ReadyToInstall;
                Debug.WriteLine($"[Update] Update pending restart: {AvailableUpdate.Version}");
                return;
            }

            var update = await _manager.CheckForUpdatesAsync();
            if (update == null)
            {
                State = UpdateState.NoUpdate;
                Debug.WriteLine("[Update] Already up to date");
                return;
            }

            _pendingUpdate = update;
            AvailableUpdate = FromVelopackAsset(update.TargetFullRelease);
            State = UpdateState.UpdateAvailable;
            Debug.WriteLine($"[Update] New version available: {AvailableUpdate.Version}");
        }
        catch (Exception ex)
        {
            LastErrorMessage = ex.Message;
            Debug.WriteLine($"[Update] Check failed: {ex.Message}");
            State = UpdateState.Error;
        }
    }

    public async Task DownloadAndInstallAsync()
    {
        if (State == UpdateState.Downloading)
            return;

        if (!_manager.IsInstalled)
        {
            LastErrorMessage = "VELOPACK_NOT_INSTALLED";
            State = UpdateState.Error;
            Debug.WriteLine("[Update] Velopack package is not installed; cannot apply update.");
            return;
        }

        try
        {
            if (_pendingUpdate == null && _manager.UpdatePendingRestart == null)
            {
                LastErrorMessage = "NO_UPDATE_READY";
                State = UpdateState.Error;
                Debug.WriteLine("[Update] No update is ready to install.");
                return;
            }

            State = UpdateState.Downloading;
            DownloadProgress = 0;

            if (_pendingUpdate != null)
            {
                await _manager.DownloadUpdatesAsync(_pendingUpdate, progress => DownloadProgress = progress / 100.0);
                AvailableUpdate = FromVelopackAsset(_pendingUpdate.TargetFullRelease);
            }

            DownloadProgress = 1.0;
            State = UpdateState.ReadyToInstall;

            var target = _pendingUpdate?.TargetFullRelease ?? _manager.UpdatePendingRestart;
            if (target == null)
            {
                LastErrorMessage = "NO_UPDATE_ASSET";
                State = UpdateState.Error;
                Debug.WriteLine("[Update] Download completed, but no Velopack asset was found to apply.");
                return;
            }

            _manager.WaitExitThenApplyUpdates(target, silent: true, restart: true);
            System.Windows.Application.Current?.Dispatcher.Invoke(() =>
            {
                MainWindow.RequestApplicationShutdown();
            });
        }
        catch (Exception ex)
        {
            LastErrorMessage = ex.Message;
            Debug.WriteLine($"[Update] Install failed: {ex.Message}");
            State = UpdateState.Error;
        }
    }

    private static AppUpdateInfo FromVelopackAsset(VelopackAsset asset)
    {
        return new AppUpdateInfo
        {
            Version = asset.Version.ToString(),
            DownloadUrl = asset.FileName,
            ReleaseNotes = string.IsNullOrWhiteSpace(asset.NotesMarkdown)
                ? asset.NotesHTML
                : asset.NotesMarkdown
        };
    }
}
