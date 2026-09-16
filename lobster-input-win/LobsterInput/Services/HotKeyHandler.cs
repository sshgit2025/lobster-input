using CommunityToolkit.Mvvm.ComponentModel;
using LobsterInput.Models;
using LobsterInput.Workflows;

namespace LobsterInput.Services;

public sealed partial class HotKeyHandler : ObservableObject
{
    public static HotKeyHandler Instance { get; } = new();

    private readonly RecordingWorkflow _workflow = new();

    public bool SkipSystemPaste
    {
        get => _workflow.SkipSystemPaste;
        set => _workflow.SkipSystemPaste = value;
    }

    public event Action? ShowRecordingOverlay
    {
        add => _workflow.ShowRecordingOverlay += value;
        remove => _workflow.ShowRecordingOverlay -= value;
    }

    public event Action? HideRecordingOverlay
    {
        add => _workflow.HideRecordingOverlay += value;
        remove => _workflow.HideRecordingOverlay -= value;
    }

    public event Action? ShowRealtimeOverlay
    {
        add => _workflow.ShowRealtimeOverlay += value;
        remove => _workflow.ShowRealtimeOverlay -= value;
    }

    public event Action? HideRealtimeOverlay
    {
        add => _workflow.HideRealtimeOverlay += value;
        remove => _workflow.HideRealtimeOverlay -= value;
    }

    public event Action<string>? UpdateRealtimeText
    {
        add => _workflow.UpdateRealtimeText += value;
        remove => _workflow.UpdateRealtimeText -= value;
    }

    public event Action<string>? ShowTip
    {
        add => _workflow.ShowTip += value;
        remove => _workflow.ShowTip -= value;
    }

    public event Action<string>? ShowClarify
    {
        add => _workflow.ShowClarify += value;
        remove => _workflow.ShowClarify -= value;
    }

    public event Action<string, bool>? ShowResult
    {
        add => _workflow.ShowResult += value;
        remove => _workflow.ShowResult -= value;
    }

    public event Action<Guid, string>? UpdateSearchResult
    {
        add => _workflow.UpdateSearchResult += value;
        remove => _workflow.UpdateSearchResult -= value;
    }

    private HotKeyHandler()
    {
    }

    public void Handle(HotKeyCombo combo) => _workflow.Handle(combo);

    public void CancelDuringRecording() => _workflow.CancelDuringRecording();

    public void CancelDuringProcessing() => _workflow.CancelDuringProcessing();

    public void CancelDuringRealtime() => _workflow.CancelDuringRealtime();

    public Task ProcessRecordAsync(
        string id,
        string operation,
        string? audioPath,
        string? selectedText,
        SelectionSnapshot? snapshot = null,
        List<string>? clipboardHistory = null,
        List<ClipboardContextItem>? clipboardItems = null,
        IntPtr? targetWindow = null)
    {
        return _workflow.ProcessRecordAsync(
            id,
            operation,
            audioPath,
            selectedText,
            snapshot,
            clipboardHistory,
            clipboardItems,
            targetWindow);
    }
}
