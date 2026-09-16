using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using LobsterInput.Helpers;

namespace LobsterInput.Views.Overlays;

public partial class TipOverlay : Window
{
    private const int AutoDismissSeconds = 4;

    private DispatcherTimer? _dismissTimer;

    public TipOverlay()
    {
        InitializeComponent();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        WindowInteropTools.ApplyNoActivate(this);
    }

    public void ShowTip(string message)
    {
        TipText.Text = message;
        PositionOnScreen();
        Show();

        if (TryFindResource("FadeIn") is Storyboard fadeIn)
            fadeIn.Begin();
        else
            RootCard.Opacity = 1;

        StartDismissTimer();
    }

    public void HideOverlay()
    {
        StopDismissTimer();

        if (TryFindResource("FadeOut") is not Storyboard fadeOut)
        {
            Hide();
            return;
        }

        fadeOut.Completed += (_, _) => Hide();
        fadeOut.Begin();
    }

    private void PositionOnScreen()
    {
        WindowInteropTools.PositionCenteredNearBottom(this, 60);
    }

    private void StartDismissTimer()
    {
        StopDismissTimer();
        _dismissTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(AutoDismissSeconds) };
        _dismissTimer.Tick += OnDismissTick;
        _dismissTimer.Start();
    }

    private void StopDismissTimer()
    {
        _dismissTimer?.Stop();
        _dismissTimer = null;
    }

    private void OnDismissTick(object? sender, EventArgs e)
    {
        StopDismissTimer();
        HideOverlay();
    }

    private void CloseBtn_Click(object sender, RoutedEventArgs e)
    {
        HideOverlay();
    }
}
