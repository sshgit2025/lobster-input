using LobsterInput.Helpers;

namespace LobsterInput.Views;

public sealed class InviteCodeWindow : AppStageWindow
{
    public InviteCodeView InviteCodeView { get; } = new();

    public InviteCodeWindow(string email)
        : base(L10n.InvitePageSubtitle, 680, 680, null!)
    {
        InviteCodeView.ViewModel.Email = email;
        SetStageContent(InviteCodeView);
    }
}
