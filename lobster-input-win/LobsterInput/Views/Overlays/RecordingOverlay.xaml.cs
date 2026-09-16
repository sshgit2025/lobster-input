using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;
using LobsterInput.Helpers;
using LobsterInput.Services;

namespace LobsterInput.Views.Overlays;

public partial class RecordingOverlay : Window
{
    public event EventHandler? CancelRequested;

    private readonly AudioRecorderService _recorder;
    private readonly Rectangle[] _bars;
    private readonly Queue<double> _levels = new();
    private readonly DispatcherTimer _waveTimer;
    private int _dotPhase;
    private Storyboard? _pulseStoryboard;
    private int _showGeneration;

    public RecordingOverlay()
    {
        InitializeComponent();
        _recorder = AudioRecorderService.Instance;
        _bars = new[] { Bar0, Bar1, Bar2, Bar3, Bar4, Bar5, Bar6, Bar7, Bar8, Bar9 };
        for (var i = 0; i < 10; i++)
            _levels.Enqueue(0.08);
        _waveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
        _waveTimer.Tick += (_, _) => TickWaveform();
        _recorder.PropertyChanged += OnRecorderPropertyChanged;
        LanguageManager.Instance.PropertyChanged += (_, _) =>
            Dispatcher.Invoke(() => { if (IsVisible) CloseBtn.ToolTip = L10n.Cancel; });
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        WindowInteropTools.ApplyNoActivate(this);
    }

    public void ShowOverlay()
    {
        _showGeneration++;
        CloseBtn.ToolTip = L10n.Cancel;
        PositionOnScreen();
        RootCard.BeginAnimation(OpacityProperty, null);
        RootCard.Opacity = 0;
        Show();

        if (TryFindResource("FadeIn") is Storyboard fadeIn)
            fadeIn.Begin();
        else
            RootCard.Opacity = 1;

        _pulseStoryboard = TryFindResource("PulseGreen") as Storyboard;

        UpdateVisualState(_recorder.State);
        _waveTimer.Start();
    }

    public void HideOverlay()
    {
        _showGeneration++;
        _pulseStoryboard?.Stop(this);
        _waveTimer.Stop();
        RootCard.BeginAnimation(OpacityProperty, null);
        RootCard.Opacity = 0;
        Hide();
    }

    private void PositionOnScreen()
    {
        var work = WindowInteropTools.CursorWorkAreaDip();
        WindowInteropTools.PositionCenteredNearBottom(this, Math.Max(60, work.Height * 0.12));
    }

    private void OnRecorderPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnRecorderPropertyChanged(sender, e));
            return;
        }

        switch (e.PropertyName)
        {
            case nameof(AudioRecorderService.State):
                UpdateVisualState(_recorder.State);
                break;
            case nameof(AudioRecorderService.AudioLevel):
                UpdateWaveBars(_recorder.AudioLevel);
                break;
            case nameof(AudioRecorderService.Countdown):
                UpdateCountdown(_recorder.Countdown);
                break;
            case nameof(AudioRecorderService.ElapsedSeconds):
                UpdateElapsed(_recorder.ElapsedSeconds);
                break;
        }
    }

    private void UpdateVisualState(RecordingState state)
    {
        switch (state)
        {
            case RecordingState.Recording:
                ProcessingSpinner.Visibility = Visibility.Collapsed;
                CenterIcon.Visibility = Visibility.Visible;
                StatusText.Visibility = Visibility.Visible;
                StatusText.Text = "00:00";
                CenterIcon.Text = "\uE720";
                CenterIcon.Foreground = (Brush)FindResource("AccentBrush");
                foreach (var bar in _bars)
                {
                    bar.Fill = (Brush)FindResource("AccentBrush");
                    bar.Width = 2;
                    bar.RadiusX = 1;
                    bar.RadiusY = 1;
                }
                break;
            case RecordingState.Processing:
                StatusText.Text = "";
                StatusText.Visibility = Visibility.Collapsed;
                CenterIcon.Visibility = Visibility.Collapsed;
                ProcessingSpinner.Visibility = Visibility.Visible;
                foreach (var bar in _bars)
                {
                    bar.Fill = (Brush)FindResource("AccentBrush");
                    bar.Width = 6;
                    bar.RadiusX = 3;
                    bar.RadiusY = 3;
                }
                break;
        }
    }

    private void UpdateWaveBars(float level)
    {
        // Audio level is sampled by the local animation timer. The timer keeps
        // the overlay alive visually even during quiet input or slow device callbacks.
    }

    private void TickWaveform()
    {
        var rng = Random.Shared;
        if (_recorder.State == RecordingState.Processing)
        {
            _dotPhase = (_dotPhase + 1) % _bars.Length;
            for (var i = 0; i < _bars.Length; i++)
            {
                var active = i == _dotPhase;
                var near = i == (_dotPhase + _bars.Length - 1) % _bars.Length;
                _bars[i].Height = active ? 8 : 6;
                _bars[i].Width = active ? 8 : 6;
                _bars[i].Opacity = active ? 1 : near ? 0.55 : 0.28;
                Canvas.SetBottom(_bars[i], active ? 4 : 5);
            }
            return;
        }

        var input = Math.Clamp(_recorder.AudioLevel, 0, 1);
        var next = Math.Max(0.08 + rng.NextDouble() * 0.18, input * (0.75 + rng.NextDouble() * 0.45));
        _levels.Dequeue();
        _levels.Enqueue(Math.Clamp(next, 0.05, 1));

        var values = _levels.ToArray();
        for (var i = 0; i < _bars.Length; i++)
        {
            var level = values[i];
            var height = Math.Clamp(4 + 16 * level, 4, 16);
            _bars[i].Height = height;
            _bars[i].Width = 2;
            _bars[i].Opacity = 0.45 + Math.Min(0.5, level * 0.75);
            Canvas.SetBottom(_bars[i], (16 - height) / 2);
        }
    }

    private void UpdateCountdown(int? countdown)
    {
        if (countdown.HasValue)
        {
            StatusText.Text = $"{countdown.Value}s";
            StatusText.Foreground = (Brush)FindResource("NeonRedBrush");
        }
        else
        {
            StatusText.Foreground = (Brush)FindResource("TextDimBrush");
            if (_recorder.State == RecordingState.Recording)
                UpdateElapsed(_recorder.ElapsedSeconds);
        }
    }

    private void UpdateElapsed(int elapsedSeconds)
    {
        if (_recorder.State == RecordingState.Recording && _recorder.Countdown == null)
            StatusText.Text = $"{elapsedSeconds / 60:00}:{elapsedSeconds % 60:00}";
    }

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        CancelRequested?.Invoke(this, EventArgs.Empty);
    }

    protected override void OnClosed(EventArgs e)
    {
        _recorder.PropertyChanged -= OnRecorderPropertyChanged;
        _waveTimer.Stop();
        base.OnClosed(e);
    }
}
