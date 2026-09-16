package com.lobster.input.core.network

import com.lobster.input.data.model.*
import okhttp3.MultipartBody
import okhttp3.RequestBody
import retrofit2.Response
import retrofit2.http.*

interface ApiService {
    
    // ==================== 认证 ====================
    
    @POST(ApiConfig.Auth.SEND_CODE)
    suspend fun sendCode(@Body request: SendCodeRequest): Response<Unit>
    
    @POST(ApiConfig.Auth.VERIFY)
    suspend fun login(@Body request: LoginRequest): Response<AuthResponse>
    
    @POST(ApiConfig.Auth.VERIFY_INVITE)
    suspend fun verifyInvite(
        @Header("Authorization") token: String,
        @Body request: VerifyInviteRequest
    ): Response<AuthResponse>
    
    @GET(ApiConfig.Auth.INVITE_CODES)
    suspend fun getMyInviteCodes(
        @Header("Authorization") token: String
    ): Response<MyInviteCodesResponse>

    @POST(ApiConfig.Auth.LOGOUT)
    suspend fun logout(
        @Header("Authorization") token: String
    ): Response<Unit>
    
    // ==================== 用户信息 ====================
    
    @GET(ApiConfig.Config.PLAN)
    suspend fun getPlanInfo(
        @Header("Authorization") token: String
    ): Response<UserPlanInfo>
    
    // ==================== 配置 ====================
    
    @GET(ApiConfig.Config.STARTUP)
    suspend fun getStartupConfig(): Response<AppStartupConfig>
    
    @GET(ApiConfig.Config.RECORDING)
    suspend fun getRecordingConfig(
        @Header("Authorization") token: String
    ): Response<RecordingConfigResponse>

    // ==================== 支付 ====================

    @GET(ApiConfig.Payments.CATALOG)
    suspend fun getPaymentCatalog(
        @Header("Authorization") token: String
    ): Response<PaymentCatalogResponse>

    @POST(ApiConfig.Payments.SUBSCRIPTION_CHECKOUT)
    suspend fun createSubscriptionCheckout(
        @Header("Authorization") token: String,
        @Body request: CreateSubscriptionCheckoutBody
    ): Response<PaymentCheckoutResponse>

    @POST(ApiConfig.Subscription.CANCEL_RENEWAL)
    suspend fun cancelSubscriptionRenewal(
        @Header("Authorization") token: String,
        @Body body: CancelRenewalBody
    ): Response<CancelRenewalResponse>

    @POST(ApiConfig.Payments.CREDITS_TOPUP_CHECKOUT)
    suspend fun createCreditsTopupCheckout(
        @Header("Authorization") token: String,
        @Body request: CreateCreditsTopupCheckoutBody
    ): Response<PaymentCheckoutResponse>
    
    // ==================== 音频处理 ====================
    
    @Multipart
    @POST(ApiConfig.Audio.PROCESS)
    suspend fun processAudio(
        @Header("Authorization") token: String,
        @Header("X-Client-Platform") clientPlatform: String = ApiConfig.CLIENT_PLATFORM,
        @Part audio: MultipartBody.Part,
        @Part("operation") operation: RequestBody,
        @Part("selected_text") selectedText: RequestBody? = null,
        @Part("clipboard_history") clipboardHistory: RequestBody? = null,
        @Part("fast_mode") fastMode: RequestBody? = null
    ): Response<AudioProcessResponse>

    @POST(ApiConfig.AudioV2.PROCESS_TEXT)
    suspend fun processRealtimeText(
        @Header("Authorization") token: String,
        @Header("X-Client-Platform") clientPlatform: String = ApiConfig.CLIENT_PLATFORM,
        @Body request: TextProcessRequest
    ): Response<AudioProcessResponse>

    @POST(ApiConfig.Text.QUICK_ACTION)
    suspend fun quickAction(
        @Header("Authorization") token: String,
        @Body request: AndroidQuickActionRequest
    ): Response<TextQuickActionResponse>
    
    // ==================== 热词 ====================
    
    @GET(ApiConfig.HotWords.LIST)
    suspend fun getHotWords(
        @Header("Authorization") token: String
    ): Response<HotWordListResponse>
    
    @POST(ApiConfig.HotWords.LIST)
    suspend fun createHotWord(
        @Header("Authorization") token: String,
        @Body body: HotWordCreateBody
    ): Response<HotWordItem>
    
    @PUT(ApiConfig.HotWords.ITEM)
    suspend fun updateHotWord(
        @Header("Authorization") token: String,
        @Path("id") id: String,
        @Body body: HotWordUpdateBody
    ): Response<HotWordItem>
    
    @DELETE(ApiConfig.HotWords.ITEM)
    suspend fun deleteHotWord(
        @Header("Authorization") token: String,
        @Path("id") id: String
    ): Response<Unit>
    
    // ==================== 人设 ====================
    
    @GET(ApiConfig.Personas.LIST)
    suspend fun getPersonas(
        @Header("Authorization") token: String
    ): Response<PersonaListResponse>
    
    @POST(ApiConfig.Personas.LIST)
    suspend fun createPersona(
        @Header("Authorization") token: String,
        @Body body: PersonaCreateBody
    ): Response<PersonaItem>
    
    @PUT(ApiConfig.Personas.ITEM)
    suspend fun updatePersona(
        @Header("Authorization") token: String,
        @Path("id") id: String,
        @Body body: PersonaUpdateBody
    ): Response<PersonaItem>
    
    @DELETE(ApiConfig.Personas.ITEM)
    suspend fun deletePersona(
        @Header("Authorization") token: String,
        @Path("id") id: String
    ): Response<Unit>
    
    @POST(ApiConfig.Personas.ACTIVATE)
    suspend fun activatePersona(
        @Header("Authorization") token: String,
        @Path("id") id: String
    ): Response<PersonaItem>

    @POST(ApiConfig.Personas.DEACTIVATE_ALL)
    suspend fun deactivatePersonas(
        @Header("Authorization") token: String
    ): Response<Unit>
    
    // ==================== 协议 ====================
    
    @GET(ApiConfig.Agreements.GET)
    suspend fun getAgreements(): Response<AgreementsResponse>
}
