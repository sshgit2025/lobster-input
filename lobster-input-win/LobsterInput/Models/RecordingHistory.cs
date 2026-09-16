using System.Text.Json.Serialization;
using LobsterInput.Helpers;

namespace LobsterInput.Models;

public enum RecordingStatus
{
    Pending,
    Processing,
    Success,
    Failed
}

public class RecordingHistory
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("created_at")]
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;

    [JsonPropertyName("operation")]
    public string Operation { get; set; } = "transcribe";

    [JsonPropertyName("audio_file_path")]
    public string? AudioFilePath { get; set; }

    [JsonPropertyName("selected_text")]
    public string? SelectedText { get; set; }

    [JsonPropertyName("transcript")]
    public string? Transcript { get; set; }

    [JsonPropertyName("result")]
    public string? Result { get; set; }

    [JsonPropertyName("action_type")]
    public string? ActionType { get; set; }

    [JsonPropertyName("status")]
    [JsonConverter(typeof(JsonStringEnumConverter))]
    public RecordingStatus Status { get; set; } = RecordingStatus.Pending;

    [JsonPropertyName("error_message")]
    public string? ErrorMessage { get; set; }

    [JsonPropertyName("retryable")]
    public bool Retryable { get; set; } = true;

    [JsonPropertyName("processing_duration")]
    public double? ProcessingDuration { get; set; }

    [JsonPropertyName("process_started_at")]
    public DateTime? ProcessStartedAt { get; set; }

    [JsonIgnore]
    public bool ResultIsMarkdown => ActionType == "show_markdown";

    [JsonIgnore]
    public bool AudioFileExists =>
        AudioFilePath != null && File.Exists(AudioFilePath);

    [JsonIgnore]
    public string OperationDisplayName => Operation switch
    {
        "transcribe" => L10n.OpTranscribe,
        "rewrite" => L10n.OpRewrite,
        "agent" => L10n.OpAgent,
        _ => Operation
    };
}
