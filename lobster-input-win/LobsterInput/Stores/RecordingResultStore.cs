using CommunityToolkit.Mvvm.ComponentModel;

namespace LobsterInput.Stores;

public sealed partial class RecordingResultStore : ObservableObject
{
    public static RecordingResultStore Instance { get; } = new();

    private RecordingResultStore() { }

    [ObservableProperty]
    private string _transcript = "";

    [ObservableProperty]
    private string _result = "";

    [ObservableProperty]
    private string? _errorMessage;

    public void Update(string transcript, string result, string? error)
    {
        Transcript = transcript;
        Result = result;
        ErrorMessage = error;
    }

    public void Clear()
    {
        Transcript = "";
        Result = "";
        ErrorMessage = null;
    }
}
