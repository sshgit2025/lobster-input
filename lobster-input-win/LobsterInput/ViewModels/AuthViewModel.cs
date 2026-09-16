using System.Windows.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Services;
using LobsterInput.Stores;

namespace LobsterInput.ViewModels;

public sealed partial class AuthViewModel : ObservableObject
{
    [ObservableProperty]
    private string _email = "";

    [ObservableProperty]
    private string _code = "";

    [ObservableProperty]
    private bool _codeSent;

    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private string? _errorMessage;

    [ObservableProperty]
    private int _resendCountdown;

    [ObservableProperty]
    private bool _canResend = true;

    // 倒计时文案（如“重新发送验证码”），由界面按当前语言刷新
    [ObservableProperty]
    private string _resendCodeText = L10n.ResendCode;

    private DispatcherTimer? _resendTimer;

    // 验证码发送冷却时长（秒），与后端 RESEND_COOLDOWN_SEC 保持一致
    private const int CooldownSeconds = 60;

    public event Action? OnLoginSuccess;
    public event Action<string>? OnNeedInviteCode;

    public AuthViewModel()
    {
        // 冷启动时若最近发码邮箱仍在冷却期内，预填邮箱并恢复倒计时
        var pending = SendCodeCooldownStore.PendingEmail();
        if (!string.IsNullOrEmpty(pending))
        {
            Email = pending!;
        }
        RestoreCooldown();
    }

    partial void OnEmailChanged(string value)
    {
        RestoreCooldown();
    }

    [RelayCommand]
    private async Task SendCodeAsync()
    {
        if (string.IsNullOrWhiteSpace(Email))
        {
            ErrorMessage = L10n.EnterEmail;
            return;
        }

        if (!CanResend)
        {
            return;
        }

        IsLoading = true;
        ErrorMessage = null;

        try
        {
            await ApiClient.Instance.SendCodeAsync(Email.Trim());
            CodeSent = true;
            SendCodeCooldownStore.Mark(Email.Trim(), CooldownSeconds);
            StartResendTimer(CooldownSeconds);
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
    private async Task VerifyAsync()
    {
        if (string.IsNullOrWhiteSpace(Code))
        {
            ErrorMessage = L10n.EnterCode;
            return;
        }

        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var resp = await ApiClient.Instance.VerifyAsync(Email.Trim(), Code.Trim());

            if (resp.RequireInvite)
            {
                AuthStore.Instance.PendingInviteEmail = Email.Trim();
                OnNeedInviteCode?.Invoke(Email.Trim());
            }
            else
            {
                AuthStore.Instance.Save(resp);
                RecordingResultStore.Instance.Clear();
                OnLoginSuccess?.Invoke();
            }
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

    /// <summary>依据当前邮箱的本地持久化时间戳，恢复/刷新发码倒计时。</summary>
    private void RestoreCooldown()
    {
        StartResendTimer(SendCodeCooldownStore.RemainingSeconds(Email.Trim()));
    }

    private void StartResendTimer(int seconds)
    {
        _resendTimer?.Stop();
        if (seconds <= 0)
        {
            CanResend = true;
            ResendCountdown = 0;
            return;
        }

        CanResend = false;
        ResendCountdown = seconds;

        _resendTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _resendTimer.Tick += (_, _) =>
        {
            ResendCountdown--;
            if (ResendCountdown <= 0)
            {
                _resendTimer.Stop();
                CanResend = true;
            }
        };
        _resendTimer.Start();
    }
}
