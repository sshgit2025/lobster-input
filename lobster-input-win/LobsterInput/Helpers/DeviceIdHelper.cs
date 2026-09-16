using System.Diagnostics;
using System.Management;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32;

namespace LobsterInput.Helpers;

public static class DeviceIdHelper
{
    private static string? _cachedDeviceId;
    private static string? _cachedFingerprint;

    public static string GetDeviceId()
    {
        if (_cachedDeviceId != null) return _cachedDeviceId;

        var machineGuid = ReadMachineGuid();
        if (!string.IsNullOrEmpty(machineGuid))
        {
            _cachedDeviceId = HashString(machineGuid);
            return _cachedDeviceId;
        }

        _cachedDeviceId = HashString(Environment.MachineName + Environment.UserName);
        return _cachedDeviceId;
    }

    public static string GetHardwareFingerprint()
    {
        if (_cachedFingerprint != null) return _cachedFingerprint;

        var sb = new StringBuilder();
        sb.Append(QueryWmi("Win32_Processor", "ProcessorId"));
        sb.Append('|');
        sb.Append(QueryWmi("Win32_BaseBoard", "SerialNumber"));
        sb.Append('|');
        sb.Append(QueryWmi("Win32_BIOS", "SerialNumber"));

        var raw = sb.ToString();
        _cachedFingerprint = string.IsNullOrEmpty(raw.Replace("|", ""))
            ? GetDeviceId()
            : HashString(raw);

        return _cachedFingerprint;
    }

    private static string? ReadMachineGuid()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(
                @"SOFTWARE\Microsoft\Cryptography");
            return key?.GetValue("MachineGuid") as string;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[DeviceId] Registry read failed: {ex.Message}");
            return null;
        }
    }

    private static string QueryWmi(string wmiClass, string property)
    {
        try
        {
            using var searcher = new ManagementObjectSearcher($"SELECT {property} FROM {wmiClass}");
            foreach (var obj in searcher.Get())
            {
                var val = obj[property]?.ToString()?.Trim();
                if (!string.IsNullOrEmpty(val) && val != "To Be Filled By O.E.M.")
                    return val;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[DeviceId] WMI query {wmiClass}.{property} failed: {ex.Message}");
        }

        return "";
    }

    private static string HashString(string input)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(input));
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes)
            sb.Append(b.ToString("x2"));
        return sb.ToString();
    }
}
