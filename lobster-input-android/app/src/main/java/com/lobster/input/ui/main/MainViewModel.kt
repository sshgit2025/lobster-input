package com.lobster.input.ui.main

import android.content.Context
import com.lobster.input.core.locale.MobileStrings
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.lobster.input.data.local.AuthPreferences
import com.lobster.input.data.model.CancelRenewalBody
import com.lobster.input.data.model.CreateCreditsTopupCheckoutBody
import com.lobster.input.data.model.CreateSubscriptionCheckoutBody
import com.lobster.input.keyboard.pinyin.HotwordDictionaryBridge
import com.lobster.input.data.model.HotWordCreateBody
import com.lobster.input.data.model.HotWordItem
import com.lobster.input.data.model.HotWordUpdateBody
import com.lobster.input.data.model.InviteCodeItem
import com.lobster.input.data.model.PERSONA_MAX_COUNT
import com.lobster.input.data.model.PaymentBillingOption
import com.lobster.input.data.model.PaymentCatalogResponse
import com.lobster.input.data.model.PersonaCreateBody
import com.lobster.input.data.model.PersonaItem
import com.lobster.input.data.model.PersonaPrompts
import com.lobster.input.data.model.PersonaUpdateBody
import com.lobster.input.data.model.PaymentSubscriptionPlan
import com.lobster.input.data.model.UserPlanInfo
import com.lobster.input.data.model.displayMessage
import com.lobster.input.core.network.ApiService
import com.lobster.input.di.handleResponse
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class MainViewModel @Inject constructor(
    private val apiService: ApiService,
    private val authPrefs: AuthPreferences,
    @ApplicationContext private val context: Context
) : ViewModel() {

    private val _uiState = MutableStateFlow(MainUiState())
    val uiState: StateFlow<MainUiState> = _uiState

    val email: String?
        get() = authPrefs.userEmail

    fun refreshAll() {
        loadPlan()
        loadPaymentCatalog()
        loadHotWords()
        loadPersonas()
    }

    fun loadPlan() {
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.getPlanInfo(token).handleResponse(token)
            }.onSuccess { plan ->
                _uiState.update { it.copy(plan = plan, error = null) }
                authPrefs.userTier = plan.tier
            }.onFailure { e ->
                _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainLoadPlanFailed(context))) }
            }
        }
    }

    fun loadPaymentCatalog() {
        viewModelScope.launch {
            _uiState.update { it.copy(isPaymentCatalogLoading = true) }
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.getPaymentCatalog(token).handleResponse(token)
            }.onSuccess { catalog ->
                _uiState.update { it.copy(paymentCatalog = catalog, isPaymentCatalogLoading = false, error = null) }
            }.onFailure { e ->
                _uiState.update {
                    it.copy(
                        isPaymentCatalogLoading = false,
                        paymentStatus = e.displayMessage(context, MobileStrings.mainLoadPlanFailed(context))
                    )
                }
            }
        }
    }

    fun createSubscriptionCheckout(plan: PaymentSubscriptionPlan, option: PaymentBillingOption) {
        val loadingKey = "${plan.planCode}:${option.cycle}"
        viewModelScope.launch {
            _uiState.update { it.copy(checkoutInProgress = loadingKey, paymentStatus = null) }
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.createSubscriptionCheckout(
                    token,
                    CreateSubscriptionCheckoutBody(
                        planCode = plan.planCode,
                        billingCycle = option.cycle,
                        autoRenew = true,
                        provider = _uiState.value.paymentCatalog?.activeProvider.orEmpty(),
                        productCode = option.productCode ?: "${plan.planCode}_${option.cycle}",
                        paymentMethod = "",
                        currency = option.currency.orEmpty(),
                        settlementMode = "full_price",
                        discountCode = ""
                    )
                ).handleResponse(token)
            }.onSuccess { checkout ->
                _uiState.update {
                    it.copy(
                        checkoutInProgress = null,
                        checkoutUrl = checkout.checkoutUrl,
                        paymentStatus = MobileStrings.mainPaymentCheckoutOpened(context)
                    )
                }
                refreshAfterCheckout()
            }.onFailure { e ->
                _uiState.update {
                    it.copy(
                        checkoutInProgress = null,
                        paymentStatus = e.displayMessage(context, MobileStrings.mainPaymentCheckoutFailed(context))
                    )
                }
            }
        }
    }

    fun createCreditsTopupCheckout() {
        val catalog = _uiState.value.paymentCatalog ?: return
        viewModelScope.launch {
            _uiState.update { it.copy(checkoutInProgress = "topup", paymentStatus = null) }
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.createCreditsTopupCheckout(
                    token,
                    CreateCreditsTopupCheckoutBody(
                        provider = catalog.activeProvider,
                        productCode = catalog.creditsTopup.productCode ?: "credits_topup",
                        paymentMethod = "",
                        currency = catalog.creditsTopup.currency.orEmpty(),
                        discountCode = ""
                    )
                ).handleResponse(token)
            }.onSuccess { checkout ->
                _uiState.update {
                    it.copy(
                        checkoutInProgress = null,
                        checkoutUrl = checkout.checkoutUrl,
                        paymentStatus = MobileStrings.mainPaymentCheckoutOpened(context)
                    )
                }
                refreshAfterCheckout()
            }.onFailure { e ->
                _uiState.update {
                    it.copy(
                        checkoutInProgress = null,
                        paymentStatus = e.displayMessage(context, MobileStrings.mainPaymentCheckoutFailed(context))
                    )
                }
            }
        }
    }

    /** 取消订阅自动续费:cancelled / already_cancelled 均视为成功并刷新套餐信息。 */
    fun cancelSubscriptionRenewal() {
        if (_uiState.value.isCancellingRenewal) return
        viewModelScope.launch {
            _uiState.update { it.copy(isCancellingRenewal = true, paymentStatus = null) }
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.cancelSubscriptionRenewal(token, CancelRenewalBody()).handleResponse(token)
            }.onSuccess { result ->
                val message = when (result.status) {
                    "cancelled", "already_cancelled" -> MobileStrings.mainCancelRenewalSuccess(context)
                    // 该订阅由订阅设备的应用商店托管,本端无法直接取消
                    else -> MobileStrings.mainRenewalManagedExternally(context)
                }
                _uiState.update { it.copy(isCancellingRenewal = false, paymentStatus = message) }
                loadPlan()
                loadPaymentCatalog()
            }.onFailure { e ->
                _uiState.update {
                    it.copy(
                        isCancellingRenewal = false,
                        paymentStatus = e.displayMessage(context, MobileStrings.mainCancelRenewalFailed(context))
                    )
                }
            }
        }
    }

    fun consumeCheckoutUrl() {
        _uiState.update { it.copy(checkoutUrl = null) }
    }

    private fun refreshAfterCheckout() {
        viewModelScope.launch {
            listOf(3L, 5L, 8L, 13L, 21L, 34L).forEach { seconds ->
                kotlinx.coroutines.delay(seconds * 1000)
                loadPlan()
                loadPaymentCatalog()
            }
        }
    }

    fun loadHotWords() {
        viewModelScope.launch {
            _uiState.update { it.copy(isHotWordsLoading = true) }
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.getHotWords(token).handleResponse(token).hotwords
            }.onSuccess { words ->
                HotwordDictionaryBridge.persistHotwords(context, words.map { it.word })
                _uiState.update { it.copy(hotWords = words, isHotWordsLoading = false, error = null) }
            }.onFailure { e ->
                _uiState.update { it.copy(isHotWordsLoading = false, error = e.displayMessage(context, MobileStrings.mainLoadHotWordsFailed(context))) }
            }
        }
    }

    fun addHotWord(word: String) {
        val trimmed = word.trim()
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.createHotWord(token, HotWordCreateBody(trimmed)).handleResponse(token)
            }.onSuccess { loadHotWords() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainSaveHotWordFailed(context))) } }
        }
    }

    fun updateHotWord(id: String, word: String) {
        val trimmed = word.trim()
        if (trimmed.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.updateHotWord(token, id, HotWordUpdateBody(trimmed)).handleResponse(token)
            }.onSuccess { loadHotWords() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainSaveHotWordFailed(context))) } }
        }
    }

    fun deleteHotWord(id: String) {
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.deleteHotWord(token, id).handleResponse(token)
            }.onSuccess { loadHotWords() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainDeleteHotWordFailed(context))) } }
        }
    }

    fun loadPersonas() {
        viewModelScope.launch {
            _uiState.update { it.copy(isPersonasLoading = true) }
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.getPersonas(token).handleResponse(token).personas
            }.onSuccess { personas ->
                _uiState.update { it.copy(personas = personas, isPersonasLoading = false, error = null) }
            }.onFailure { e ->
                _uiState.update { it.copy(isPersonasLoading = false, error = e.displayMessage(context, MobileStrings.mainLoadPersonasFailed(context))) }
            }
        }
    }

    fun createPersona(name: String, description: String, prompts: PersonaPrompts) {
        val trimmedName = name.trim()
        if (trimmedName.isEmpty() || uiState.value.personas.count { !it.isBuiltin } >= PERSONA_MAX_COUNT) return
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.createPersona(
                    token,
                    PersonaCreateBody(trimmedName, description.trim().ifEmpty { null }, prompts)
                ).handleResponse(token)
            }.onSuccess { loadPersonas() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainSavePersonaFailed(context))) } }
        }
    }

    fun activatePersona(id: String) {
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.activatePersona(token, id).handleResponse(token)
            }.onSuccess { loadPersonas() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainActivatePersonaFailed(context))) } }
        }
    }

    fun deactivatePersonas() {
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.deactivatePersonas(token).handleResponse(token)
            }.onSuccess { loadPersonas() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainActivatePersonaFailed(context))) } }
        }
    }

    fun updatePersona(id: String, name: String, description: String, prompts: PersonaPrompts) {
        val trimmedName = name.trim()
        if (trimmedName.isEmpty()) return
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.updatePersona(
                    token = token,
                    id = id,
                    body = PersonaUpdateBody(
                        name = trimmedName,
                        description = description.trim().ifEmpty { null },
                        prompts = prompts
                    )
                ).handleResponse(token)
            }.onSuccess { loadPersonas() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainSavePersonaFailed(context))) } }
        }
    }

    fun deletePersona(id: String) {
        viewModelScope.launch {
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.deletePersona(token, id).handleResponse(token)
            }.onSuccess { loadPersonas() }
                .onFailure { e -> _uiState.update { it.copy(error = e.displayMessage(context, MobileStrings.mainDeletePersonaFailed(context))) } }
        }
    }

    fun loadInviteCodes() {
        if (_uiState.value.plan?.showInviteCodesEnabled != true) {
            _uiState.update {
                it.copy(inviteCodes = emptyList(), isInviteCodesLoading = false)
            }
            return
        }
        viewModelScope.launch {
            _uiState.update { it.copy(isInviteCodesLoading = true) }
            runCatching {
                val token = authPrefs.getAuthHeader()
                apiService.getMyInviteCodes(token).handleResponse(token).inviteCodes
            }.onSuccess { codes ->
                _uiState.update { it.copy(inviteCodes = codes, isInviteCodesLoading = false, error = null) }
            }.onFailure { e ->
                _uiState.update { it.copy(isInviteCodesLoading = false, error = e.displayMessage(context, MobileStrings.mainLoadInviteCodesFailed(context))) }
            }
        }
    }

    fun logout() {
        // fire-and-forget 通知服务端注销当前会话(幂等,失败不影响本地退出)。
        // 用独立 scope 而非 viewModelScope:退出后立即导航会清掉 ViewModel,避免请求被取消。
        val token = authPrefs.getAuthHeader()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            runCatching { apiService.logout(token) }
        }
        authPrefs.clear()
    }
}

data class MainUiState(
    val plan: UserPlanInfo? = null,
    val paymentCatalog: PaymentCatalogResponse? = null,
    val hotWords: List<HotWordItem> = emptyList(),
    val personas: List<PersonaItem> = emptyList(),
    val inviteCodes: List<InviteCodeItem> = emptyList(),
    val isPaymentCatalogLoading: Boolean = false,
    val checkoutInProgress: String? = null,
    val isCancellingRenewal: Boolean = false,
    val checkoutUrl: String? = null,
    val paymentStatus: String? = null,
    val isHotWordsLoading: Boolean = false,
    val isPersonasLoading: Boolean = false,
    val isInviteCodesLoading: Boolean = false,
    val error: String? = null
)
