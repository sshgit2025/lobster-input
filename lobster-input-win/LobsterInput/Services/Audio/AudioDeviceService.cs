using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using NAudio.CoreAudioApi;

namespace LobsterInput.Services.Audio;

public sealed class AudioDeviceService : IDisposable
{
    private static readonly string DeviceSettingsPath = Path.Combine(
        AppPaths.AppDataDir,
        "audio_device.json");

    private string? _selectedDeviceId;
    private readonly object _settingsGate = new();
    private bool _disposed;

    public static AudioDeviceService Instance { get; } = new();

    private AudioDeviceService()
    {
        _selectedDeviceId = LoadSelectedDeviceId();
    }

    public IReadOnlyList<InputDeviceInfo> InputDevices()
    {
        try
        {
            var selectedDeviceId = SelectedDeviceIdSnapshot();
            using var enumerator = new MMDeviceEnumerator();
            var devices = EnumerateSelectableCaptureDevices(enumerator);
            try
            {
                return devices
                    .Select(device => new InputDeviceInfo(
                        device.ID,
                        device.FriendlyName,
                        string.Equals(device.ID, selectedDeviceId, StringComparison.OrdinalIgnoreCase)))
                    .ToList();
            }
            finally
            {
                DisposeDevices(devices);
            }
        }
        catch (Exception ex)
        {
            DebugTrace.Log("AudioDevice", $"Input device enumeration failed: {ex.Message}");
            return Array.Empty<InputDeviceInfo>();
        }
    }

    public void SelectInputDevice(string? deviceId)
    {
        lock (_settingsGate)
        {
            _selectedDeviceId = string.IsNullOrWhiteSpace(deviceId) ? null : deviceId;
            SaveSelectedDeviceId(_selectedDeviceId);
        }
    }

    public IReadOnlyList<CaptureDeviceCandidate> ResolveCaptureDeviceCandidates()
    {
        try
        {
            var selectedDeviceId = SelectedDeviceIdSnapshot();
            using var enumerator = new MMDeviceEnumerator();
            var devices = EnumerateSelectableCaptureDevices(enumerator);
            try
            {
                var defaultCommunicationsId = ResolveDefaultDeviceId(enumerator, Role.Communications);
                var defaultConsoleId = ResolveDefaultDeviceId(enumerator, Role.Console);
                var ordered = OrderAutomaticDevices(devices, defaultCommunicationsId, defaultConsoleId);
                var candidates = new List<CaptureDeviceCandidate>();
                var explicitDevice = FindDevice(devices, selectedDeviceId);
                var order = 0;

                if (!string.IsNullOrEmpty(selectedDeviceId))
                {
                    if (explicitDevice != null)
                    {
                        candidates.Add(ToCandidate(explicitDevice, order++, false, "explicit"));
                    }
                    else
                    {
                        DebugTrace.Log("AudioDevice", $"Explicit input device unavailable id={selectedDeviceId}; falling back to automatic selection");
                        ClearSelectedDeviceIfCurrent(selectedDeviceId);
                    }
                }

                foreach (var device in ordered)
                {
                    if (explicitDevice != null &&
                        string.Equals(device.ID, explicitDevice.ID, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    candidates.Add(ToCandidate(device, order, true, order == 0 ? "auto-primary" : "auto-next"));
                    order++;
                }

                return candidates;
            }
            finally
            {
                DisposeDevices(devices);
            }
        }
        catch (Exception ex)
        {
            DebugTrace.Log("AudioDevice", $"Auto input device resolution failed: {ex.Message}");
            return Array.Empty<CaptureDeviceCandidate>();
        }
    }

    public MMDevice OpenCaptureDevice(CaptureDeviceCandidate candidate)
    {
        using var enumerator = new MMDeviceEnumerator();
        var device = enumerator.GetDevice(candidate.Id);
        try
        {
            if (device.State != DeviceState.Active || !IsUserSelectableDevice(device))
                throw new InvalidOperationException($"Capture device is not active or selectable: {candidate.Name}");

            return device;
        }
        catch
        {
            device.Dispose();
            throw;
        }
    }

    public static bool IsRecoverableCaptureException(Exception ex)
    {
        const uint ENoInterface = 0x80004002;
        const uint AudclntDeviceInvalidated = 0x88890004;

        var hresult = unchecked((uint)ex.HResult);
        if (hresult is ENoInterface or AudclntDeviceInvalidated)
            return true;

        return ex.InnerException != null && IsRecoverableCaptureException(ex.InnerException);
    }

    private string? SelectedDeviceIdSnapshot()
    {
        lock (_settingsGate)
            return _selectedDeviceId;
    }

    private void ClearSelectedDeviceIfCurrent(string deviceId)
    {
        lock (_settingsGate)
        {
            if (!string.Equals(_selectedDeviceId, deviceId, StringComparison.OrdinalIgnoreCase))
                return;

            _selectedDeviceId = null;
            SaveSelectedDeviceId(null);
        }
    }

    private static List<MMDevice> EnumerateSelectableCaptureDevices(MMDeviceEnumerator enumerator)
    {
        return enumerator
            .EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active)
            .Where(IsUserSelectableDevice)
            .ToList();
    }

    private static List<MMDevice> OrderAutomaticDevices(
        IReadOnlyList<MMDevice> devices,
        string? defaultCommunicationsId,
        string? defaultConsoleId)
    {
        var ordered = new List<MMDevice>();
        var externalDevices = devices.Where(device => !IsBuiltInDevice(device)).ToList();
        var builtInDevices = devices.Where(IsBuiltInDevice).ToList();

        AppendById(externalDevices, defaultCommunicationsId, ordered);
        AppendById(externalDevices, defaultConsoleId, ordered);
        AppendAll(externalDevices, ordered);
        AppendById(builtInDevices, defaultCommunicationsId, ordered);
        AppendById(builtInDevices, defaultConsoleId, ordered);
        AppendAll(builtInDevices, ordered);

        return ordered;
    }

    private static void AppendById(IEnumerable<MMDevice> devices, string? id, List<MMDevice> ordered)
    {
        if (string.IsNullOrEmpty(id)) return;
        var device = devices.FirstOrDefault(candidate =>
            string.Equals(candidate.ID, id, StringComparison.OrdinalIgnoreCase));
        AppendUnique(device, ordered);
    }

    private static void AppendAll(IEnumerable<MMDevice> devices, List<MMDevice> ordered)
    {
        foreach (var device in devices)
            AppendUnique(device, ordered);
    }

    private static void AppendUnique(MMDevice? device, List<MMDevice> ordered)
    {
        if (device == null) return;
        if (ordered.Any(existing => string.Equals(existing.ID, device.ID, StringComparison.OrdinalIgnoreCase))) return;
        ordered.Add(device);
    }

    private static MMDevice? FindDevice(IEnumerable<MMDevice> devices, string? id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        return devices.FirstOrDefault(device =>
            string.Equals(device.ID, id, StringComparison.OrdinalIgnoreCase));
    }

    private static string? ResolveDefaultDeviceId(MMDeviceEnumerator enumerator, Role role)
    {
        try
        {
            using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, role);
            return device.ID;
        }
        catch (COMException ex)
        {
            DebugTrace.Log("AudioDevice", $"Default capture device unavailable role={role}, hresult=0x{ex.HResult:X8}, error={ex.Message}");
            return null;
        }
        catch (Exception ex)
        {
            DebugTrace.Log("AudioDevice", $"Default capture device unavailable role={role}, error={ex.Message}");
            return null;
        }
    }

    private static CaptureDeviceCandidate ToCandidate(MMDevice device, int order, bool automatic, string reason)
    {
        return new CaptureDeviceCandidate(device.ID, device.FriendlyName, order, automatic, reason);
    }

    private static void DisposeDevices(IEnumerable<MMDevice> devices)
    {
        foreach (var device in devices)
            device.Dispose();
    }

    private static bool IsUserSelectableDevice(MMDevice device)
    {
        var id = device.ID ?? "";
        var name = device.FriendlyName ?? "";
        var tokens = new[]
        {
            "CADefaultDeviceAggregate",
            "Aggregate",
            "Virtual",
            "Loopback",
            "Monitor",
            "Stereo Mix",
            "What U Hear",
            "虚拟",
            "聚合",
            "立体声混音"
        };

        return !tokens.Any(token =>
            id.Contains(token, StringComparison.OrdinalIgnoreCase) ||
            name.Contains(token, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsBuiltInDevice(MMDevice device)
    {
        var id = device.ID ?? "";
        var name = device.FriendlyName ?? "";
        var tokens = new[]
        {
            "Built-in",
            "Built in",
            "Internal",
            "Integrated",
            "Realtek",
            "Microphone Array",
            "麦克风阵列",
            "内置",
            "内建"
        };

        return tokens.Any(token =>
            id.Contains(token, StringComparison.OrdinalIgnoreCase) ||
            name.Contains(token, StringComparison.OrdinalIgnoreCase));
    }

    private static string? LoadSelectedDeviceId()
    {
        try
        {
            if (!File.Exists(DeviceSettingsPath)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(DeviceSettingsPath));
            return doc.RootElement.TryGetProperty("device_id", out var value) ? value.GetString() : null;
        }
        catch
        {
            return null;
        }
    }

    private static void SaveSelectedDeviceId(string? deviceId)
    {
        var dir = Path.GetDirectoryName(DeviceSettingsPath)!;
        Directory.CreateDirectory(dir);
        File.WriteAllText(DeviceSettingsPath, JsonSerializer.Serialize(new { device_id = deviceId }));
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
    }
}

public sealed record CaptureDeviceCandidate(
    string Id,
    string Name,
    int Order,
    bool IsAutomaticSelection,
    string Reason);
