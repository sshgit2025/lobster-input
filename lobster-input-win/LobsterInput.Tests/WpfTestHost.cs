using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using LobsterInput.Converters;

namespace LobsterInput.Tests;

internal static class WpfTestHost
{
    private static readonly object SyncRoot = new();
    private static Thread? _thread;
    private static Application? _app;
    private static Dispatcher? _dispatcher;
    private static Exception? _startupError;
    private static bool _resourcesInitialized;

    public static void Run(Action action)
    {
        EnsureStarted();

        Exception? error = null;

        _dispatcher!.Invoke(() =>
        {
            try
            {
                EnsureResources(_app!.Resources);
                action();
                DrainDispatcher();
            }
            catch (Exception ex)
            {
                error = ex;
            }
        });

        if (error != null)
            ExceptionDispatchInfo.Capture(error).Throw();
    }

    private static void EnsureStarted()
    {
        if (_dispatcher != null)
            return;

        lock (SyncRoot)
        {
            if (_dispatcher != null)
                return;

            using var ready = new ManualResetEventSlim();

            _thread = new Thread(() =>
            {
                try
                {
                    _app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                    _dispatcher = Dispatcher.CurrentDispatcher;
                }
                catch (Exception ex)
                {
                    _startupError = ex;
                }
                finally
                {
                    ready.Set();
                }

                if (_startupError == null)
                    Dispatcher.Run();
            })
            {
                IsBackground = true,
                Name = "LobsterInput.Tests.WpfSta"
            };

            _thread.SetApartmentState(ApartmentState.STA);
            _thread.Start();

            if (!ready.Wait(TimeSpan.FromSeconds(90)))
                throw new TimeoutException("Timed out waiting for the WPF STA test host.");

            if (_startupError != null)
                ExceptionDispatchInfo.Capture(_startupError).Throw();
        }
    }

    private static void EnsureResources(ResourceDictionary resources)
    {
        if (_resourcesInitialized)
            return;

        resources.MergedDictionaries.Add(Load("DesignTokens.xaml"));
        resources.MergedDictionaries.Add(Load("Animations.xaml"));
        resources.MergedDictionaries.Add(Load("WindowsChrome.xaml"));
        resources.MergedDictionaries.Add(Load("AtomicComponents.xaml"));
        resources.MergedDictionaries.Add(Load("LayoutShells.xaml"));
        resources.MergedDictionaries.Add(Load("CyberTheme.xaml"));
        resources.MergedDictionaries.Add(Load("LegacyAliases.xaml"));

        resources["BoolToVisibility"] = new BooleanToVisibilityConverter();
        resources["InverseBoolConverter"] = new InverseBooleanConverter();
        resources["InverseBoolToVisibility"] = new InverseBooleanToVisibilityConverter();
        resources["NullToCollapsed"] = new NullToCollapsedConverter();

        _resourcesInitialized = true;
    }

    private static ResourceDictionary Load(string name) => new()
    {
        Source = new Uri($"pack://application:,,,/LobsterInput;component/Resources/{name}", UriKind.Absolute)
    };

    private static void DrainDispatcher()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(
            DispatcherPriority.ContextIdle,
            new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }
}
