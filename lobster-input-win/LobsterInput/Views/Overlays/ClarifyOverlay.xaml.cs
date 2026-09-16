using System.Windows;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using LobsterInput.Helpers;

namespace LobsterInput.Views.Overlays;

public partial class ClarifyOverlay : Window
{
    private const int AutoDismissSeconds = 5;

    private DispatcherTimer? _dismissTimer;

    public ClarifyOverlay()
    {
        InitializeComponent();
        LanguageManager.Instance.PropertyChanged += (_, _) =>
            Dispatcher.Invoke(() => { if (IsVisible) TitleText.Text = L10n.OverlayClarifyTitle; });
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        WindowInteropTools.ApplyNoActivate(this, clickThrough: true);
    }

    public void ShowQuestion(string question)
    {
        TitleText.Text = L10n.OverlayClarifyTitle;
        QuestionText.Text = question;
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
        var work = WindowInteropTools.CursorWorkAreaDip();
        WindowInteropTools.PositionCenteredNearTop(this, work.Height * 0.12 + 110);
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
}
