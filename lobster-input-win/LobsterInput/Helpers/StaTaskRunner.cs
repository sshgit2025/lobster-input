using System.Windows.Threading;

namespace LobsterInput.Helpers;

public static class StaTaskRunner
{
    private static readonly object Sync = new();
    private static readonly ManualResetEventSlim Ready = new(false);
    private static Dispatcher? _dispatcher;
    private static Thread? _thread;

    public static Task<T> Run<T>(Func<T> func)
    {
        var dispatcher = EnsureDispatcher();
        if (Dispatcher.FromThread(Thread.CurrentThread) == dispatcher)
        {
            try
            {
                return Task.FromResult(func());
            }
            catch (Exception ex)
            {
                return Task.FromException<T>(ex);
            }
        }

        var tcs = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        dispatcher.BeginInvoke(new Action(() =>
        {
            try
            {
                tcs.SetResult(func());
            }
            catch (Exception ex)
            {
                tcs.SetException(ex);
            }
        }), DispatcherPriority.Send);
        return tcs.Task;
    }

    public static void Shutdown()
    {
        Dispatcher? dispatcher;
        lock (Sync)
        {
            dispatcher = _dispatcher;
            _dispatcher = null;
            _thread = null;
            Ready.Reset();
        }

        dispatcher?.BeginInvokeShutdown(DispatcherPriority.Send);
    }

    private static Dispatcher EnsureDispatcher()
    {
        lock (Sync)
        {
            if (_dispatcher != null && !_dispatcher.HasShutdownStarted && !_dispatcher.HasShutdownFinished)
                return _dispatcher;

            Ready.Reset();
            _thread = new Thread(() =>
            {
                _dispatcher = Dispatcher.CurrentDispatcher;
                Ready.Set();
                Dispatcher.Run();
            })
            {
                IsBackground = true,
                Name = "LobsterInput STA worker"
            };
            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();

            Ready.Wait();
            return _dispatcher ?? throw new InvalidOperationException("STA dispatcher failed to start.");
        }
    }
}
