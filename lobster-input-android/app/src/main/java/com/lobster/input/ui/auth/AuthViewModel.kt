package com.lobster.input.ui.auth

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.lobster.input.core.device.DeviceIdentity
import com.lobster.input.core.locale.MobileStrings
import com.lobster.input.core.network.ApiConfig
import com.lobster.input.data.local.AuthPreferences
import com.lobster.input.data.model.displayMessage
import com.lobster.input.data.repository.AuthRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class AuthViewModel @Inject constructor(
    private val authRepository: AuthRepository,
    private val authPreferences: AuthPreferences,
    @ApplicationContext private val context: Context
) : ViewModel() {
    
    private val _isLoggedIn = MutableStateFlow(authRepository.isLoggedIn())
    val isLoggedIn: StateFlow<Boolean> = _isLoggedIn
    
    private val _uiState = MutableStateFlow<AuthUiState>(AuthUiState.Idle)
    val uiState: StateFlow<AuthUiState> = _uiState
    
    private val _requireInvite = MutableStateFlow(false)
    val requireInvite: StateFlow<Boolean> = _requireInvite

    // 发送验证码剩余冷却秒数（0 表示可发送），基于本地持久化时间戳，退出重进仍生效
    private val _cooldownSeconds = MutableStateFlow(0)
    val cooldownSeconds: StateFlow<Int> = _cooldownSeconds
    private var cooldownJob: Job? = null

    /** 登录页若最近发码邮箱仍在冷却期内，返回该邮箱用于预填。 */
    fun pendingCooldownEmail(): String? = authPreferences.pendingSendCodeEmail()

    /** 根据本地持久化时间戳，恢复指定邮箱当前的发码倒计时。 */
    fun refreshCooldown(email: String) {
        startCooldownTicker(authPreferences.sendCodeRemainingSeconds(email))
    }

    private fun startCooldownTicker(seconds: Int) {
        cooldownJob?.cancel()
        if (seconds <= 0) {
            _cooldownSeconds.value = 0
            return
        }
        _cooldownSeconds.value = seconds
        cooldownJob = viewModelScope.launch {
            while (_cooldownSeconds.value > 0) {
                delay(1000)
                _cooldownSeconds.value = (_cooldownSeconds.value - 1).coerceAtLeast(0)
            }
        }
    }

    fun sendCode(email: String) {
        if (_cooldownSeconds.value > 0) return
        viewModelScope.launch {
            _uiState.value = AuthUiState.Loading
            try {
                authRepository.sendCode(email)
                authPreferences.markCodeSent(email, ApiConfig.SEND_CODE_COOLDOWN_SEC)
                startCooldownTicker(ApiConfig.SEND_CODE_COOLDOWN_SEC)
                _uiState.value = AuthUiState.CodeSent
            } catch (e: Exception) {
                _uiState.value = AuthUiState.Error(displayError(e, MobileStrings.sendCodeFailed(context)))
            }
        }
    }
    
    fun login(email: String, code: String) {
        viewModelScope.launch {
            _uiState.value = AuthUiState.Loading
            try {
                val response = authRepository.login(
                    email,
                    code,
                    DeviceIdentity.deviceId(context),
                    DeviceIdentity.hardwareFingerprint(context)
                )
                _requireInvite.value = response.requireInvite
                
                if (response.requireInvite) {
                    _uiState.value = AuthUiState.RequireInvite
                } else {
                    _isLoggedIn.value = true
                    _uiState.value = AuthUiState.Success
                }
            } catch (e: Exception) {
                _uiState.value = AuthUiState.Error(displayError(e, MobileStrings.loginFailed(context)))
            }
        }
    }
    
    fun verifyInvite(email: String, inviteCode: String, deviceId: String, hardwareFingerprint: String) {
        viewModelScope.launch {
            _uiState.value = AuthUiState.Loading
            try {
                authRepository.verifyInvite(email, inviteCode, deviceId, hardwareFingerprint)
                _isLoggedIn.value = true
                _uiState.value = AuthUiState.Success
            } catch (e: Exception) {
                _uiState.value = AuthUiState.Error(displayError(e, MobileStrings.inviteVerifyFailed(context)))
            }
        }
    }
    
    fun resetState() {
        _uiState.value = AuthUiState.Idle
    }

    private fun displayError(error: Exception, fallback: String): String {
        return error.displayMessage(context, fallback)
    }
}

sealed class AuthUiState {
    object Idle : AuthUiState()
    object Loading : AuthUiState()
    object CodeSent : AuthUiState()
    object RequireInvite : AuthUiState()
    object Success : AuthUiState()
    data class Error(val message: String) : AuthUiState()
}
