using LobsterInput.Helpers;

namespace LobsterInput.Views;

public sealed class AuthWindow : AppStageWindow
{
    public AuthView AuthView { get; } = new();

    public AuthWindow()
        : base(L10n.AppNameFull, 680, 680, null!)
    {
        SetStageContent(AuthView);
    }
}
