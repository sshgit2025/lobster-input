using LobsterInput.Helpers;
using LobsterInput.Views.Onboarding;

namespace LobsterInput.Views;

public sealed class OnboardingWindow : AppStageWindow
{
    public OnboardingView OnboardingView { get; } = new();

    public OnboardingWindow()
        : base(L10n.AppNameFull, 680, 680, null!)
    {
        SetStageContent(OnboardingView);
    }
}
