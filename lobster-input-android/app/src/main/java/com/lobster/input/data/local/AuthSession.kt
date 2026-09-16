package com.lobster.input.data.local

import android.content.Context
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.core.security.SecureTokenStore

object AuthSession {
    fun isLoggedIn(context: Context): Boolean {
        return !token(context).isNullOrBlank()
    }

    fun authHeader(context: Context): String? {
        return token(context)?.takeIf { it.isNotBlank() }?.let { "Bearer $it" }
    }

    fun clear(context: Context) {
        val prefs = context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
        SecureTokenStore.clearToken(prefs)
        prefs.edit()
            .remove(ApiConfig.KEY_USER_EMAIL)
            .remove(ApiConfig.KEY_USER_TIER)
            .apply()
    }

    fun clearIfCurrent(context: Context, authHeader: String?): Boolean {
        val current = authHeader(context)
        if (authHeader.isNullOrBlank() || current == authHeader) {
            clear(context)
            return true
        }
        return false
    }

    private fun token(context: Context): String? {
        val prefs = context.getSharedPreferences(ApiConfig.PREFS_NAME, Context.MODE_PRIVATE)
        return SecureTokenStore.readToken(prefs)
    }
}
