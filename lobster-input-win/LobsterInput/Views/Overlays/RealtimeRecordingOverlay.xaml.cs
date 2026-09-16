using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using LobsterInput.Helpers;
using LobsterInput.Services;

namespace LobsterInput.Views.Overlays;

public partial class RealtimeRecordingOverlay : Window
{
    public event EventHandler? CancelRequested;

    private readonly RealtimeAudioStreamer _streamer = RealtimeAudioStreamer.Instance;
    private readonly Rectangle[] _bars;
    private readonly Queue<double> _levels = new();
    private readonly DispatcherTimer _waveTimer;
    // 实时识别打字机平滑层:把突发 partial 平滑成逐字揭示,只影响悬浮窗显示。
    private readonly TypewriterReveal _typewriter;
    private int _dotPhase;

    public RealtimeRecordingOverlay()
    {
        InitializeComponent();
        _bars = new[] { Bar0, Bar1, Bar2, Bar3, Bar4, Bar5, Bar6, Bar7, Bar8, Bar9 };
        for (var i = 0; i < 10; i++) _levels.Enqueue(0.08);
        _waveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(60) };
        _waveTimer.Tick += (_, _) => TickWaveform();
        _typewriter = new TypewriterReveal(Dispatcher, RenderLiveText);
        _streamer.PropertyChanged += OnStreamerPropertyChanged;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        WindowInteropTools.ApplyNoActivate(this);
    }

    public void ShowOverlay()
    {
        _typewriter.Reset();
        LiveText.Text = "";
        Width = 220;
        PositionOnScreen();
        Show();
        UpdateVisualState(_streamer.State);
        _waveTimer.Start();
    }

    public void HideOverlay()
    {
        _waveTimer.Stop();
        _typewriter.Reset();
        LiveText.Text = "";
        Hide();
    }

    public void UpdateLiveText(string text)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => UpdateLiveText(text));
            return;
        }

        if (_streamer.State == RealtimeRecordingState.Processing)
        {
            _typewriter.Reset();
            BubbleCard.Visibility = Visibility.Collapsed;
            LiveText.Text = "";
            Width = 220;
            PositionOnScreen();
            return;
        }

        // 喂给打字机平滑层;实际逐字渲染走 RenderLiveText。业务的完整文本另存于
        // RecordingWorkflow.realtimeSession.Transcript,与此显示无关。
        _typewriter.SetTarget(text ?? "");
    }

    private void RenderLiveText(string shown)
    {
        LiveText.Text = shown;
        Width = Math.Clamp(180 + LiveText.Text.Length * 7, 220, 520);
        PositionOnScreen();
        Dispatcher.BeginInvoke(() => LiveScroll.ScrollToRightEnd(), DispatcherPriority.Background);
    }

    private void PositionOnScreen()
    {
        var work = WindowInteropTools.CursorWorkAreaDip();
        WindowInteropTools.PositionCenteredNearBottom(this, Math.Max(60, work.Height * 0.12) + 40);
    }

    private void OnStreamerPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnStreamerPropertyChanged(sender, e));
            return;
        }

        switch (e.PropertyName)
        {
            case nameof(RealtimeAudioStreamer.State):
                UpdateVisualState(_streamer.State);
                break;
            case nameof(RealtimeAudioStreamer.ElapsedSeconds):
                UpdateElapsed(_streamer.ElapsedSeconds);
                break;
        }
    }

    private void UpdateVisualState(RealtimeRecordingState state)
    {
        if (state == RealtimeRecordingState.Processing)
        {
            _typewriter.Reset();
            BubbleCard.Visibility = Visibility.Collapsed;
            LiveText.Text = "";
            Width = 220;
            PositionOnScreen();
            StatusText.Visibility = Visibility.Collapsed;
            ProcessingSpinner.Visibility = Visibility.Visible;
            return;
        }

        BubbleCard.Visibility = Visibility.Visible;
        ProcessingSpinner.Visibility = Visibility.Collapsed;
        StatusText.Visibility = Visibility.Visible;
    }

    private void UpdateElapsed(int seconds)
    {
        var time = TimeSpan.FromSeconds(Math.Max(0, seconds));
        StatusText.Text = $"{(int)time.TotalMinutes:00}:{time.Seconds:00}";
    }

    private void TickWaveform()
    {
        if (_streamer.State == RealtimeRecordingState.Processing)
        {
            _dotPhase = (_dotPhase + 1) % _bars.Length;
            for (var i = 0; i < _bars.Length; i++)
            {
                var active = i == _dotPhase;
                _bars[i].Height = active ? 8 : 6;
                _bars[i].Width = active ? 8 : 6;
                _bars[i].Opacity = active ? 1 : 0.28;
                Canvas.SetBottom(_bars[i], active ? 4 : 5);
            }
            return;
        }

        var input = Math.Clamp(_streamer.AudioLevel, 0, 1);
        var next = Math.Max(0.08 + Random.Shared.NextDouble() * 0.18, input * (0.75 + Random.Shared.NextDouble() * 0.45));
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

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        CancelRequested?.Invoke(this, EventArgs.Empty);
    }
}
