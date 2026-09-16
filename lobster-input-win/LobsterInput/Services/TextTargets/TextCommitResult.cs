namespace LobsterInput.Services.TextTargets;

public enum TextCommitStatus
{
    Committed,
    Skipped,
    NotEditable,
    NoTarget,
    Failed
}

public sealed record TextCommitResult(
    TextCommitStatus Status,
    string? Reason = null)
{
    public bool Committed => Status == TextCommitStatus.Committed;

    public static TextCommitResult Success() => new(TextCommitStatus.Committed);
    public static TextCommitResult Skipped(string reason) => new(TextCommitStatus.Skipped, reason);
    public static TextCommitResult NotEditable() => new(TextCommitStatus.NotEditable, "Target is not editable.");
    public static TextCommitResult NoTarget() => new(TextCommitStatus.NoTarget, "No focused target window.");
    public static TextCommitResult Failed(string? reason = null) => new(TextCommitStatus.Failed, reason);
}
