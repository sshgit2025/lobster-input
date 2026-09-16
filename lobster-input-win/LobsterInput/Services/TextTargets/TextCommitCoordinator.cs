namespace LobsterInput.Services.TextTargets;

internal sealed class TextCommitCoordinator
{
    public static TextCommitCoordinator Instance { get; } = new();

    private readonly SemaphoreSlim _gate = new(1, 1);

    private TextCommitCoordinator()
    {
    }

    public async Task<TextCommitResult> RunAsync(Func<Task<TextCommitResult>> commit)
    {
        await _gate.WaitAsync();
        try
        {
            return await commit();
        }
        finally
        {
            _gate.Release();
        }
    }
}
