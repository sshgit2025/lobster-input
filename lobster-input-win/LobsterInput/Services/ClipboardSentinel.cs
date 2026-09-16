namespace LobsterInput.Services;

internal static class ClipboardSentinel
{
    private const string SelectionPrefix = "__LOBSTER_SELECTION_SENTINEL_";

    public static string CreateSelectionProbeMarker() =>
        $"{SelectionPrefix}{Guid.NewGuid():N}__";

    public static bool IsInternal(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return false;

        return text.Contains(SelectionPrefix, StringComparison.Ordinal);
    }
}
