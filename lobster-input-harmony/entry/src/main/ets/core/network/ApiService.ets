// 移植自 Android: core/network/ApiService.kt(Retrofit 接口)。
// 所有端点与方法名与安卓一一对应;token 参数为完整 Authorization header 值(形如 "Bearer xxx")。
// 底层统一走 HttpClient(全局 header/超时/错误处理已折入 HttpClient,等价 NetworkModule 拦截器 + handleResponse)。
// 响应体经 ApiModels 的 parseXxx 工厂函数转为强类型;解析失败抛 ApiException.decodingError。
import { ApiConfig } from './ApiConfig';
import { HttpClient, MultipartPart } from './HttpClient';
import {
  AgreementsResponse,
  AndroidQuickActionRequest,
  ApiException,
  AppStartupConfig,
  AudioProcessResponse,
  AuthResponse,
  CancelRenewalResponse,
  CreateCreditsTopupCheckoutBody,
  CreateSubscriptionCheckoutBody,
  HotWordCreateBody,
  HotWordItem,
  HotWordListResponse,
  HotWordUpdateBody,
  LoginRequest,
  MyInviteCodesResponse,
  parseAgreementsResponse,
  parseAppStartupConfig,
  parseAudioProcessResponse,
  parseAuthResponse,
  parseCancelRenewalResponse,
  parseHotWordItem,
  parseHotWordListResponse,
  parseMyInviteCodesResponse,
  parsePaymentCatalogResponse,
  parsePaymentCheckoutResponse,
  parsePersonaItem,
  parsePersonaListResponse,
  parseRecordingConfigResponse,
  parseTextQuickActionResponse,
  parseUserPlanInfo,
  PaymentCatalogResponse,
  PaymentCheckoutResponse,
  PersonaCreateBody,
  PersonaItem,
  PersonaListResponse,
  PersonaUpdateBody,
  RecordingConfigResponse,
  SendCodeRequest,
  TextProcessRequest,
  TextQuickActionResponse,
  UserPlanInfo,
  VerifyInviteRequest,
} from '../../data/model/ApiModels';

/** 统一包装解析,解析失败抛 DecodingError(等价安卓 body 为空/格式错误)。 */
function decode<T>(body: string, parser: (json: string) => T): T {
  try {
    return parser(body);
  } catch (err) {
    throw ApiException.decodingError(err as Error) as Error;
  }
}

export class ApiService {
  private static instance: ApiService | null = null;

  static getInstance(): ApiService {
    if (ApiService.instance === null) {
      ApiService.instance = new ApiService();
    }
    return ApiService.instance;
  }

  // ==================== 认证 ====================

  async sendCode(request: SendCodeRequest): Promise<void> {
    await HttpClient.postJson(ApiConfig.Auth.SEND_CODE, request);
  }

  async login(request: LoginRequest): Promise<AuthResponse> {
    const body = await HttpClient.postJson(ApiConfig.Auth.VERIFY, request);
    return decode(body, parseAuthResponse);
  }

  async verifyInvite(token: string, request: VerifyInviteRequest): Promise<AuthResponse> {
    const body = await HttpClient.postJson(ApiConfig.Auth.VERIFY_INVITE, request, token);
    return decode(body, parseAuthResponse);
  }

  async getMyInviteCodes(token: string): Promise<MyInviteCodesResponse> {
    const body = await HttpClient.getJson(ApiConfig.Auth.INVITE_CODES, token);
    return decode(body, parseMyInviteCodesResponse);
  }

  /** 退出登录:通知服务端注销当前平台会话(幂等,对应安卓 @POST logout,无请求体)。 */
  async logout(token: string): Promise<void> {
    await HttpClient.postNoBody(ApiConfig.Auth.LOGOUT, token);
  }

  // ==================== 用户信息 ====================

  async getPlanInfo(token: string): Promise<UserPlanInfo> {
    const body = await HttpClient.getJson(ApiConfig.Config.PLAN, token);
    return decode(body, parseUserPlanInfo);
  }

  // ==================== 配置 ====================

  async getStartupConfig(): Promise<AppStartupConfig> {
    const body = await HttpClient.getJson(ApiConfig.Config.STARTUP);
    return decode(body, parseAppStartupConfig);
  }

  async getRecordingConfig(token: string): Promise<RecordingConfigResponse> {
    const body = await HttpClient.getJson(ApiConfig.Config.RECORDING, token);
    return decode(body, parseRecordingConfigResponse);
  }

  // ==================== 支付 ====================

  async getPaymentCatalog(token: string): Promise<PaymentCatalogResponse> {
    const body = await HttpClient.getJson(ApiConfig.Payments.CATALOG, token);
    return decode(body, parsePaymentCatalogResponse);
  }

  async createSubscriptionCheckout(
    token: string,
    request: CreateSubscriptionCheckoutBody
  ): Promise<PaymentCheckoutResponse> {
    const body = await HttpClient.postJson(ApiConfig.Payments.SUBSCRIPTION_CHECKOUT, request, token);
    return decode(body, parsePaymentCheckoutResponse);
  }

  /** 取消订阅自动续费(与其他客户端 API 相同鉴权;后端要求空 JSON body {})。 */
  async cancelSubscriptionRenewal(token: string): Promise<CancelRenewalResponse> {
    const emptyBody: Record<string, Object> = {};
    const body = await HttpClient.postJson(ApiConfig.Subscription.CANCEL_RENEWAL, emptyBody, token);
    return decode(body, parseCancelRenewalResponse);
  }

  async createCreditsTopupCheckout(
    token: string,
    request: CreateCreditsTopupCheckoutBody
  ): Promise<PaymentCheckoutResponse> {
    const body = await HttpClient.postJson(ApiConfig.Payments.CREDITS_TOPUP_CHECKOUT, request, token);
    return decode(body, parsePaymentCheckoutResponse);
  }

  // ==================== 音频处理 ====================

  /**
   * 上传录音文件做转写/指令处理(对应安卓 @Multipart processAudio)。
   * 表单结构与安卓 LobsterIME.uploadAudio 完全一致:
   * - file: 音频文件(audio/wav)
   * - operation: 操作类型文本
   * - selected_text / clipboard_history / fast_mode: 可选文本分片,null 时不携带
   *
   * @param audioFilePath 应用沙箱内音频文件绝对路径
   * @param fileName 上传文件名(等价安卓 file.name)
   */
  async processAudio(
    token: string,
    audioFilePath: string,
    fileName: string,
    operation: string,
    selectedText: string | null = null,
    clipboardHistory: string | null = null,
    fastMode: string | null = null
  ): Promise<AudioProcessResponse> {
    const parts: MultipartPart[] = [];
    const filePart: MultipartPart = {
      name: 'file',
      contentType: 'audio/wav',
      filePath: audioFilePath,
      remoteFileName: fileName,
    };
    parts.push(filePart);
    const operationPart: MultipartPart = {
      name: 'operation',
      contentType: 'text/plain',
      data: operation,
    };
    parts.push(operationPart);
    if (selectedText !== null) {
      const selectedTextPart: MultipartPart = {
        name: 'selected_text',
        contentType: 'text/plain',
        data: selectedText,
      };
      parts.push(selectedTextPart);
    }
    if (clipboardHistory !== null) {
      const clipboardHistoryPart: MultipartPart = {
        name: 'clipboard_history',
        contentType: 'text/plain',
        data: clipboardHistory,
      };
      parts.push(clipboardHistoryPart);
    }
    if (fastMode !== null) {
      const fastModePart: MultipartPart = {
        name: 'fast_mode',
        contentType: 'text/plain',
        data: fastMode,
      };
      parts.push(fastModePart);
    }
    const body = await HttpClient.postMultipart(ApiConfig.Audio.PROCESS, parts, token);
    return decode(body, parseAudioProcessResponse);
  }

  /** 实时识别文本后处理(对应安卓 processRealtimeText)。 */
  async processRealtimeText(token: string, request: TextProcessRequest): Promise<AudioProcessResponse> {
    const body = await HttpClient.postJson(ApiConfig.AudioV2.PROCESS_TEXT, request, token);
    return decode(body, parseAudioProcessResponse);
  }

  async quickAction(token: string, request: AndroidQuickActionRequest): Promise<TextQuickActionResponse> {
    const body = await HttpClient.postJson(ApiConfig.Text.QUICK_ACTION, request, token);
    return decode(body, parseTextQuickActionResponse);
  }

  // ==================== 热词 ====================

  async getHotWords(token: string): Promise<HotWordListResponse> {
    const body = await HttpClient.getJson(ApiConfig.HotWords.LIST, token);
    return decode(body, parseHotWordListResponse);
  }

  async createHotWord(token: string, body: HotWordCreateBody): Promise<HotWordItem> {
    const resp = await HttpClient.postJson(ApiConfig.HotWords.LIST, body, token);
    return decode(resp, parseHotWordItem);
  }

  async updateHotWord(token: string, id: string, body: HotWordUpdateBody): Promise<HotWordItem> {
    const path = ApiConfig.HotWords.ITEM.replace('{id}', encodeURIComponent(id));
    const resp = await HttpClient.putJson(path, body, token);
    return decode(resp, parseHotWordItem);
  }

  async deleteHotWord(token: string, id: string): Promise<void> {
    const path = ApiConfig.HotWords.ITEM.replace('{id}', encodeURIComponent(id));
    await HttpClient.deleteJson(path, token);
  }

  // ==================== 人设 ====================

  async getPersonas(token: string): Promise<PersonaListResponse> {
    const body = await HttpClient.getJson(ApiConfig.Personas.LIST, token);
    return decode(body, parsePersonaListResponse);
  }

  async createPersona(token: string, body: PersonaCreateBody): Promise<PersonaItem> {
    const resp = await HttpClient.postJson(ApiConfig.Personas.LIST, body, token);
    return decode(resp, parsePersonaItem);
  }

  async updatePersona(token: string, id: string, body: PersonaUpdateBody): Promise<PersonaItem> {
    const path = ApiConfig.Personas.ITEM.replace('{id}', encodeURIComponent(id));
    const resp = await HttpClient.putJson(path, body, token);
    return decode(resp, parsePersonaItem);
  }

  async deletePersona(token: string, id: string): Promise<void> {
    const path = ApiConfig.Personas.ITEM.replace('{id}', encodeURIComponent(id));
    await HttpClient.deleteJson(path, token);
  }

  async activatePersona(token: string, id: string): Promise<PersonaItem> {
    const path = ApiConfig.Personas.ACTIVATE.replace('{id}', encodeURIComponent(id));
    // 安卓 Retrofit @POST 无 @Body:不带请求体,不发 "{}"(B-4 对齐)
    const resp = await HttpClient.postNoBody(path, token);
    return decode(resp, parsePersonaItem);
  }

  async deactivatePersonas(token: string): Promise<void> {
    // 安卓 Retrofit @POST 无 @Body:不带请求体,不发 "{}"(B-4 对齐)
    await HttpClient.postNoBody(ApiConfig.Personas.DEACTIVATE_ALL, token);
  }

  // ==================== 协议 ====================

  async getAgreements(): Promise<AgreementsResponse> {
    const body = await HttpClient.getJson(ApiConfig.Agreements.GET);
    return decode(body, parseAgreementsResponse);
  }
}
