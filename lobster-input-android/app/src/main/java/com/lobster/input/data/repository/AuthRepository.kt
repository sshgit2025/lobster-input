package com.lobster.input.data.repository

import com.lobster.input.core.network.ApiService
import com.lobster.input.data.local.AuthPreferences
import com.lobster.input.data.model.*
import com.lobster.input.di.handleResponse
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AuthRepository @Inject constructor(
    private val apiService: ApiService,
    private val authPrefs: AuthPreferences
) {
    
    suspend fun sendCode(email: String) {
        apiService.sendCode(SendCodeRequest(email)).handleResponse()
    }
    
    suspend fun login(email: String, code: String, deviceId: String, hardwareFingerprint: String): AuthResponse {
        val response = apiService.login(
            LoginRequest(email, code, deviceId, hardwareFingerprint)
        ).handleResponse()
        
        // 保存认证信息
        authPrefs.authToken = response.token
        authPrefs.userEmail = response.email
        authPrefs.userTier = response.tier
        
        return response
    }
    
    suspend fun verifyInvite(email: String, inviteCode: String, deviceId: String, hardwareFingerprint: String) {
        val token = authPrefs.getAuthHeader()
        val response = apiService.verifyInvite(
            token,
            VerifyInviteRequest(email, inviteCode, deviceId, hardwareFingerprint)
        ).handleResponse(token)

        authPrefs.authToken = response.token
        authPrefs.userEmail = response.email
        authPrefs.userTier = response.tier
    }
    
    suspend fun getMyInviteCodes(): MyInviteCodesResponse {
        val token = authPrefs.getAuthHeader()
        return apiService.getMyInviteCodes(token).handleResponse(token)
    }
    
    fun logout() {
        authPrefs.clear()
    }
    
    fun isLoggedIn(): Boolean = authPrefs.isLoggedIn
    
    fun getUserEmail(): String? = authPrefs.userEmail
    
    fun getUserTier(): String? = authPrefs.userTier
}
