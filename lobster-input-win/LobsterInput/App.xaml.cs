using System.Threading;
using System.Windows;
using LobsterInput.Helpers;
using LobsterInput.Lifecycle;
using LobsterInput.Services;

namespace LobsterInput;

public partial class App : Application
{
    private const string MutexName = "LobsterInput_SingleInstance_Mutex";

    private Mutex? _mutex;
    private ApplicationCoordinator? _coordinator;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        if (!EnsureSingleInstance())
        {
            Shutdown();
            return;
        }

        DebugTrace.Log("App", "Startup begin");

        CrashReporterService.Instance.Install();
        DebugTrace.Log("App", "Crash reporter installed");

        _coordinator = new ApplicationCoordinator();
        _coordinator.Start();

        DebugTrace.Log("App", "Startup complete");
    }

    private bool EnsureSingleInstance()
    {
        _mutex = new Mutex(true, MutexName, out var createdNew);
        if (createdNew) return true;

        DebugTrace.Log("App", "Another instance detected, exiting");
        _mutex = null;
        return false;
    }

    protected override void OnExit(ExitEventArgs e)
    {
        DebugTrace.Log("App", "Shutting down");

        _coordinator?.Dispose();
        _coordinator = null;

        try { LogReporterService.Instance.FlushAsync().Wait(TimeSpan.FromSeconds(3)); }
        catch { }

        StaTaskRunner.Shutdown();

        _mutex?.ReleaseMutex();
        _mutex?.Dispose();
        _mutex = null;

        base.OnExit(e);
    }
}
