using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;

namespace LobsterInput.ViewModels;

public sealed partial class InviteCodeViewModel : ObservableObject
{
    private static readonly string ValidChars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

    [ObservableProperty]
    private string _inviteCode = "";

    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private string? _errorMessage;

    public string Email { get; set; } = "";

    public event Action? OnSuccess;
    public event Action? OnBack;

    public string RawInviteCode =>
        new(InviteCode.Where(c => ValidChars.Contains(c)).ToArray());

    partial void OnInviteCodeChanged(string value)
    {
        var raw = new string(
            value.ToUpperInvariant()
                 .Where(c => ValidChars.Contains(c))
                 .Take(8)
                 .ToArray());

        var formatted = raw.Length > 4
            ? $"{raw[..4]}-{raw[4..]}"
            : raw;

        if (formatted != value)
            InviteCode = formatted;
    }

    [RelayCommand]
    private async Task SubmitAsync()
    {
        var code = RawInviteCode;
        if (code.Length != 8)
            return;

        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var deviceId = DeviceIdHelper.GetDeviceId();
            var fingerprint = DeviceIdHelper.GetHardwareFingerprint();

            var resp = await ApiClient.Instance.VerifyInviteAsync(
                Email, code, deviceId, fingerprint);

            AuthStore.Instance.ClearPendingInvite();
            AuthStore.Instance.Save(resp);
            RecordingResultStore.Instance.Clear();
            OnSuccess?.Invoke();
        }
        catch (ApiException ex)
        {
            ErrorMessage = ex.ErrorCode is not null
                ? L10n.ErrorForCode(ex.ErrorCode)
                : ex.Message;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            IsLoading = false;
        }
    }

    [RelayCommand]
    private void GoBack()
    {
        AuthStore.Instance.ClearPendingInvite();
        OnBack?.Invoke();
    }
}
