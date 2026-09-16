package com.lobster.input.data.local

import android.content.Context
import android.content.SharedPreferences
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.core.security.SecureTokenStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthPreferences @Inject constructor(
    @ApplicationContext context: Context
) {
    private val appContext: Context = context.applicationContext
    private val prefs: SharedPreferences = context.getSharedPreferences(
        ApiConfig.PREFS_NAME,
        Context.MODE_PRIVATE
    )
    
    var authToken: String?
        get() = SecureTokenStore.readToken(prefs)
        set(value) = SecureTokenStore.writeToken(prefs, value)
    
    var userEmail: String?
        get() = prefs.getString(ApiConfig.KEY_USER_EMAIL, null)
        set(value) = prefs.edit().putString(ApiConfig.KEY_USER_EMAIL, value).apply()
    
    var userTier: String?
        get() = prefs.getString(ApiConfig.KEY_USER_TIER, null)
        set(value) = prefs.edit().putString(ApiConfig.KEY_USER_TIER, value).apply()
    
    val isLoggedIn: Boolean
        get() = !authToken.isNullOrEmpty()

    /** 记录一次成功发码，写入邮箱与冷却到期时间戳（持久化，跨进程有效）。 */
    fun markCodeSent(email: String, cooldownSeconds: Int) {
        prefs.edit()
            .putString(ApiConfig.KEY_SEND_CODE_EMAIL, email)
            .putLong(ApiConfig.KEY_SEND_CODE_EXPIRES_AT, System.currentTimeMillis() + cooldownSeconds * 1000L)
            .apply()
    }

    /** 返回指定邮箱当前剩余的发码冷却秒数（0 表示可再次发送）。 */
    fun sendCodeRemainingSeconds(email: String): Int {
        if (email.isEmpty()) return 0
        if (prefs.getString(ApiConfig.KEY_SEND_CODE_EMAIL, null) != email) return 0
        val expiresAt = prefs.getLong(ApiConfig.KEY_SEND_CODE_EXPIRES_AT, 0L)
        val remainingMs = expiresAt - System.currentTimeMillis()
        return if (remainingMs > 0) ((remainingMs + 999) / 1000).toInt() else 0
    }

    /** 若最近发码邮箱仍在冷却期内，返回该邮箱，用于登录页预填并恢复倒计时。 */
    fun pendingSendCodeEmail(): String? {
        val email = prefs.getString(ApiConfig.KEY_SEND_CODE_EMAIL, null) ?: return null
        return if (sendCodeRemainingSeconds(email) > 0) email else null
    }
    
    fun clear() {
        AuthSession.clear(appContext)
    }
    
    fun getAuthHeader(): String {
        return "Bearer ${authToken ?: ""}"
    }
}
