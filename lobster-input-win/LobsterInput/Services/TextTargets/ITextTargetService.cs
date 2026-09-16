namespace LobsterInput.Services.TextTargets;

public interface ITextTargetService
{
    IntPtr GetFocusedWindow();
    SelectionSnapshot? CaptureSnapshot(
        IntPtr? targetWindow = null,
        bool includeCommandCopyProbe = true);
    Task<TextCommitResult> CommitTextAsync(string text, IntPtr? targetWindow, SelectionSnapshot? snapshot, bool skipSystemPaste);
    bool IsCurrentProcessWindow(IntPtr hwnd);
    bool IsKnownTerminalTarget(IntPtr? hwnd);
}
