namespace LobsterInput.Services.HotKeys;

public interface IHotKeyBackend : IDisposable
{
    bool IsListening { get; }

    event Action<HotKeyCombo>? HotKeyPressed;
    event Action<string>? Error;

    void Start(IReadOnlyDictionary<HotKeyCombo, HotKeyConfig> configs);
    void Stop();
}
