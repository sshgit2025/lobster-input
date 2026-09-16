using System.Windows;
using LobsterInput.Helpers;

namespace LobsterInput.Services.TextTargets;

public sealed class TextTargetService : ITextTargetService
{
    public static TextTargetService Instance { get; } = new();

    private TextTargetService()
    {
    }

    public IntPtr GetFocusedWindow() => SelectedTextService.GetFocusedWindow();

    public SelectionSnapshot? CaptureSnapshot(
        IntPtr? targetWindow = null,
        bool includeCommandCopyProbe = true) =>
        SelectedTextService.TakeSnapshot(targetWindow, includeCommandCopyProbe);

    public bool IsCurrentProcessWindow(IntPtr hwnd) =>
        SelectedTextService.IsCurrentProcessWindow(hwnd);

    public bool IsKnownTerminalTarget(IntPtr? hwnd) =>
        hwnd.GetValueOrDefault() != IntPtr.Zero &&
        TextTargetWin32.IsTerminalInputWindow(hwnd.GetValueOrDefault());

    public async Task<TextCommitResult> CommitTextAsync(
        string text,
        IntPtr? targetWindow,
        SelectionSnapshot? snapshot,
        bool skipSystemPaste)
    {
        return await TextCommitCoordinator.Instance.RunAsync(() =>
            CommitTextCoreAsync(text, targetWindow, snapshot, skipSystemPaste));
    }

    private async Task<TextCommitResult> CommitTextCoreAsync(
        string text,
        IntPtr? targetWindow,
        SelectionSnapshot? contextSnapshot,
        bool skipSystemPaste)
    {
        if (string.IsNullOrEmpty(text))
            return TextCommitResult.Skipped("Empty text.");

        if (skipSystemPaste)
            return TextCommitResult.Skipped("System paste disabled.");

        var requestedTarget = targetWindow.GetValueOrDefault();
        var currentTarget = GetFocusedWindow();
        var target = requestedTarget != IntPtr.Zero && TextTargetWin32.IsKnownWindow(requestedTarget)
            ? requestedTarget
            : currentTarget;
        if (target == IntPtr.Zero)
            return TextCommitResult.NoTarget();

        var isCurrentProcess = IsCurrentProcessWindow(target);
        SelectionSnapshot? fillSnapshot = null;

        bool CommitToCurrentTarget()
        {
            fillSnapshot = CaptureSnapshot(target, includeCommandCopyProbe: false);
            return SelectedTextService.PasteText(text, target, fillSnapshot, contextSnapshot);
        }

        var committed = isCurrentProcess
            ? Application.Current?.Dispatcher.Invoke(CommitToCurrentTarget) ?? false
            : await StaTaskRunner.Run(CommitToCurrentTarget);

        DebugTrace.Log(
            "TextTargetService",
            $"commit status={(committed ? "committed" : "failed")}, target=0x{target.ToInt64():X}, requested=0x{requestedTarget.ToInt64():X}, fillEditable={fillSnapshot?.IsEditable?.ToString() ?? "unknown"}, fillSource={fillSnapshot?.Source ?? "nil"}, contextEditable={contextSnapshot?.IsEditable?.ToString() ?? "unknown"}, contextSource={contextSnapshot?.Source ?? "nil"}");

        return committed
            ? TextCommitResult.Success()
            : TextCommitResult.Failed("Paste was not committed.");
    }
}
