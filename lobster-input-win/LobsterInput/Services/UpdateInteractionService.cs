using System.Windows;
using LobsterInput.Helpers;
using LobsterInput.Views;

namespace LobsterInput.Services;

public static class UpdateInteractionService
{
    private static UpdateDialogWindow? s_currentDialog;

    public static async Task CheckDownloadAndInstallAsync(Action<string>? setStatus = null, Window? owner = null)
    {
        var updater = UpdateService.Instance;
        setStatus?.Invoke(L10n.MenuChecking);

        try
        {
            await updater.CheckForUpdateAsync();

            switch (updater.State)
            {
                case UpdateState.NoUpdate:
                case UpdateState.Error:
                case UpdateState.UpdateAvailable:
                case UpdateState.ReadyToInstall:
                    ShowUpdateDialog(updater, setStatus, owner);
                    return;
            }
        }
        catch (Exception ex)
        {
            updater.SetError(ex.Message);
            ShowUpdateDialog(updater, setStatus, owner);
        }
        finally
        {
            if (updater.State != UpdateState.Downloading)
                setStatus?.Invoke(L10n.MenuCheckUpdate);
        }
    }

    private static void ShowUpdateDialog(
        UpdateService updater,
        Action<string>? setStatus,
        Window? owner)
    {
        var app = Application.Current;
        if (app != null && !app.Dispatcher.CheckAccess())
        {
            app.Dispatcher.Invoke(() => ShowUpdateDialog(updater, setStatus, owner));
            return;
        }

        var resolvedOwner = owner ?? ResolveOwner();
        if (resolvedOwner is TrayMenuWindow)
            resolvedOwner = null;

        if (s_currentDialog?.IsVisible == true)
        {
            BringToFront(s_currentDialog);
            return;
        }

        var dialog = new UpdateDialogWindow(updater, setStatus)
        {
            ShowActivated = true
        };
        s_currentDialog = dialog;
        dialog.Closed += (_, _) =>
        {
            if (ReferenceEquals(s_currentDialog, dialog))
                s_currentDialog = null;
        };

        if (resolvedOwner != null && resolvedOwner.IsVisible)
            dialog.Owner = resolvedOwner;

        dialog.WindowStartupLocation = dialog.Owner != null
            ? WindowStartupLocation.CenterOwner
            : WindowStartupLocation.CenterScreen;
        dialog.Loaded += (_, _) => BringToFront(dialog);
        dialog.Show();
        BringToFront(dialog);
    }

    private static void BringToFront(Window dialog)
    {
        if (!dialog.Dispatcher.CheckAccess())
        {
            dialog.Dispatcher.Invoke(() => BringToFront(dialog));
            return;
        }

        if (dialog.WindowState == WindowState.Minimized)
            dialog.WindowState = WindowState.Normal;

        dialog.Topmost = true;
        dialog.Show();
        dialog.Activate();
        dialog.Focus();
        dialog.Topmost = false;
        dialog.Dispatcher.BeginInvoke(() =>
        {
            dialog.Activate();
            dialog.Focus();
        });
    }

    private static Window? ResolveOwner()
    {
        var app = Application.Current;
        if (app == null)
            return null;

        foreach (Window window in app.Windows)
        {
            if (window.IsActive && window.IsVisible && window is not TrayMenuWindow)
                return window;
        }

        return app.MainWindow?.IsVisible == true ? app.MainWindow : null;
    }
}
