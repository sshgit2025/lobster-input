using LobsterInput.Helpers;
using LobsterInput.Models;
using LobsterInput.Stores;

namespace LobsterInput.Services;

public static class AuthSessionManager
{
    private static readonly object Sync = new();

    public static bool InvalidateIfRequired(Exception exception, string source)
    {
        if (exception is not ApiException apiException || !apiException.RequiresLogout)
            return false;

        Invalidate(source, apiException.ErrorCode ?? apiException.Message);
        return true;
    }

    /// 用户主动退出登录：先 fire-and-forget 通知服务端注销会话，再清理本地登录态。
    /// 服务端调用失败不阻塞本地退出（接口幂等，会话不再续期后也会自然过期）。
    public static void LogoutByUser(string source)
    {
        lock (Sync)
        {
            var token = AuthStore.Instance.Token;
            if (string.IsNullOrEmpty(token))
                return;

            DebugTrace.Log("AuthSession", $"User logout from {source}");
            _ = NotifyServerLogoutAsync(token);
            RecordingResultStore.Instance.Clear();
            AuthStore.Instance.Logout();
        }
    }

    private static async Task NotifyServerLogoutAsync(string token)
    {
        try
        {
            await ApiClient.Instance.LogoutAsync(token);
        }
        catch (Exception ex)
        {
            DebugTrace.Log("AuthSession", $"Server logout notify failed (ignored): {ex.Message}");
        }
    }

    public static void Invalidate(string source, string reason)
    {
        lock (Sync)
        {
            if (!AuthStore.Instance.IsLoggedIn)
                return;

            DebugTrace.Log("AuthSession", $"Invalidating session from {source}: {reason}");
            RecordingResultStore.Instance.Clear();
            AuthStore.Instance.Logout();
        }
    }
}
