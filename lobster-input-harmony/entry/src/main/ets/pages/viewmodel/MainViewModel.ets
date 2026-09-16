// 对应安卓 ui/main/MainViewModel.kt(345 行)。
// StateFlow<MainUiState> → 页面持有 @State MainUiState 实例并把(代理后的)引用传入本 ViewModel,
// ViewModel 直接改字段即触发 UI 刷新;协程 viewModelScope.launch → async/Promise。
import { common } from '@kit.AbilityKit'
import { ApiService } from '../../core/network/ApiService'
import { AuthPreferences } from '../../data/local/AuthPreferences'
import { MobileStrings } from '../../core/locale/MobileStrings'
import { Logger } from '../../core/log/Logger'
import { HotwordDictionaryBridge } from '../../keyboard/pinyin/HotwordDictionaryBridge'
import {
  ApiException,
  ApiExceptionKind,
  UserPlanInfo,
  CancelRenewalResponse,
  PaymentCatalogResponse,
  PaymentSubscriptionPlan,
  PaymentBillingOption,
  PaymentCheckoutResponse,
  CreateSubscriptionCheckoutBody,
  CreateCreditsTopupCheckoutBody,
  HotWordItem,
  HotWordCreateBody,
  HotWordUpdateBody,
  HotWordListResponse,
  PersonaItem,
  PersonaPrompts,
  PersonaCreateBody,
  PersonaUpdateBody,
  PersonaListResponse,
  InviteCodeItem,
  MyInviteCodesResponse,
  PERSONA_MAX_COUNT,
  displayMessage
} from '../../data/model/ApiModels'

const TAG: string = 'MainViewModel'

/** 对应 Kotlin data class MainUiState(默认值一致)。 */
export class MainUiState {
  plan: UserPlanInfo | null = null
  paymentCatalog: PaymentCatalogResponse | null = null
  hotWords: HotWordItem[] = []
  personas: PersonaItem[] = []
  inviteCodes: InviteCodeItem[] = []
  isPaymentCatalogLoading: boolean = false
  checkoutInProgress: string | null = null
  cancelRenewalInProgress: boolean = false
  checkoutUrl: string | null = null
  paymentStatus: string | null = null
  isHotWordsLoading: boolean = false
  isPersonasLoading: boolean = false
  isInviteCodesLoading: boolean = false
  error: string | null = null
}

/** 延时工具(Kotlin delay 等价)。 */
function delayMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms)
  })
}

export class MainViewModel {
  private context: common.Context
  private uiState: MainUiState
  private authPrefs: AuthPreferences
  private api: ApiService
  /** 对应 LaunchedEffect(uiState.checkoutUrl) 打开浏览器:创建支付成功后回调页面。 */
  onCheckoutUrl: (url: string) => void = () => {}
  /**
   * 登录态失效(401/封禁)回调:token 已被 HttpClient 清除,页面据此回登录页。
   * 对应安卓 LobsterApp rememberSessionLoggedIn 监听 SharedPreferences token 变化自动回登录页;
   * 鸿蒙无该监听机制,由 ViewModel 在请求失败处主动通知(只通知一次,避免并发请求重复触发)。
   */
  onUnauthorized: () => void = () => {}
  private unauthorizedNotified: boolean = false

  constructor(context: common.Context, uiState: MainUiState) {
    this.context = context
    this.uiState = uiState
    this.authPrefs = AuthPreferences.getInstance()
    this.api = ApiService.getInstance()
  }

  /** 对应 val email get() = authPrefs.userEmail。 */
  async getEmail(): Promise<string | null> {
    return this.authPrefs.userEmail
  }

  refreshAll(): void {
    this.loadPlan()
    this.loadPaymentCatalog()
    this.loadHotWords()
    this.loadPersonas()
  }

  async loadPlan(): Promise<void> {
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const plan: UserPlanInfo = await this.api.getPlanInfo(token)
      this.uiState.plan = plan
      this.uiState.error = null
      this.authPrefs.userTier = plan.tier
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainLoadPlanFailed())
    }
  }

  async loadPaymentCatalog(): Promise<void> {
    this.uiState.isPaymentCatalogLoading = true
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const catalog: PaymentCatalogResponse = await this.api.getPaymentCatalog(token)
      this.uiState.paymentCatalog = catalog
      this.uiState.isPaymentCatalogLoading = false
      this.uiState.error = null
    } catch (e) {
      this.uiState.isPaymentCatalogLoading = false
      this.uiState.paymentStatus = this.toUiError(e as Error, MobileStrings.mainLoadPlanFailed())
    }
  }

  async createSubscriptionCheckout(plan: PaymentSubscriptionPlan, option: PaymentBillingOption): Promise<void> {
    const loadingKey: string = `${plan.plan_code}:${option.cycle}`
    this.uiState.checkoutInProgress = loadingKey
    this.uiState.paymentStatus = null
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const activeProvider: string = this.uiState.paymentCatalog !== null
        ? this.uiState.paymentCatalog.active_provider : ''
      const body: CreateSubscriptionCheckoutBody = {
        plan_code: plan.plan_code,
        billing_cycle: option.cycle,
        auto_renew: true,
        provider: activeProvider,
        product_code: option.product_code !== null && option.product_code !== undefined && option.product_code !== ''
          ? option.product_code : `${plan.plan_code}_${option.cycle}`,
        payment_method: '',
        currency: option.currency !== null && option.currency !== undefined ? option.currency : '',
        settlement_mode: 'full_price',
        discount_code: ''
      }
      const checkout: PaymentCheckoutResponse = await this.api.createSubscriptionCheckout(token, body)
      this.uiState.checkoutInProgress = null
      this.uiState.checkoutUrl = checkout.checkout_url
      this.uiState.paymentStatus = MobileStrings.mainPaymentCheckoutOpened()
      this.onCheckoutUrl(checkout.checkout_url)
      this.refreshAfterCheckout()
    } catch (e) {
      this.uiState.checkoutInProgress = null
      this.uiState.paymentStatus = this.toUiError(e as Error, MobileStrings.mainPaymentCheckoutFailed())
    }
  }

  async createCreditsTopupCheckout(): Promise<void> {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null) {
      return
    }
    this.uiState.checkoutInProgress = 'topup'
    this.uiState.paymentStatus = null
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const body: CreateCreditsTopupCheckoutBody = {
        provider: catalog.active_provider,
        product_code: catalog.credits_topup.product_code !== null && catalog.credits_topup.product_code !== undefined &&
          catalog.credits_topup.product_code !== '' ? catalog.credits_topup.product_code : 'credits_topup',
        payment_method: '',
        currency: catalog.credits_topup.currency !== null && catalog.credits_topup.currency !== undefined
          ? catalog.credits_topup.currency : '',
        discount_code: ''
      }
      const checkout: PaymentCheckoutResponse = await this.api.createCreditsTopupCheckout(token, body)
      this.uiState.checkoutInProgress = null
      this.uiState.checkoutUrl = checkout.checkout_url
      this.uiState.paymentStatus = MobileStrings.mainPaymentCheckoutOpened()
      this.onCheckoutUrl(checkout.checkout_url)
      this.refreshAfterCheckout()
    } catch (e) {
      this.uiState.checkoutInProgress = null
      this.uiState.paymentStatus = this.toUiError(e as Error, MobileStrings.mainPaymentCheckoutFailed())
    }
  }

  /**
   * 取消订阅自动续费:cancelled / already_cancelled 均视为成功并刷新套餐信息;
   * 其余状态(如订阅由外部应用商店托管)提示到商店管理。结果统一走 paymentStatus 展示。
   */
  async cancelSubscriptionRenewal(): Promise<void> {
    if (this.uiState.cancelRenewalInProgress) {
      return
    }
    this.uiState.cancelRenewalInProgress = true
    this.uiState.paymentStatus = null
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const response: CancelRenewalResponse = await this.api.cancelSubscriptionRenewal(token)
      this.uiState.cancelRenewalInProgress = false
      if (response.status === 'cancelled' || response.status === 'already_cancelled') {
        this.uiState.paymentStatus = MobileStrings.mainCancelRenewalSuccess()
      } else {
        // 订阅由外部应用商店托管,本端无法取消
        this.uiState.paymentStatus = MobileStrings.mainRenewalStoreManaged()
      }
      this.loadPlan()
      this.loadPaymentCatalog()
    } catch (e) {
      this.uiState.cancelRenewalInProgress = false
      this.uiState.paymentStatus = this.toUiError(e as Error, MobileStrings.mainCancelRenewalFailed())
    }
  }

  consumeCheckoutUrl(): void {
    this.uiState.checkoutUrl = null
  }

  /** 支付页打开后按斐波那契间隔轮询刷新套餐/目录(对齐 Kotlin refreshAfterCheckout)。 */
  private async refreshAfterCheckout(): Promise<void> {
    const secondsList: number[] = [3, 5, 8, 13, 21, 34]
    for (let i = 0; i < secondsList.length; i++) {
      await delayMs(secondsList[i] * 1000)
      this.loadPlan()
      this.loadPaymentCatalog()
    }
  }

  async loadHotWords(): Promise<void> {
    this.uiState.isHotWordsLoading = true
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const response: HotWordListResponse = await this.api.getHotWords(token)
      const words: HotWordItem[] = response.hotwords
      // 与安卓一致:热词同步给拼音引擎词典桥
      try {
        HotwordDictionaryBridge.persistHotwords(this.context, words.map((w: HotWordItem): string => w.word))
      } catch (bridgeError) {
        Logger.w(TAG, `persistHotwords failed: ${(bridgeError as Error).message}`)
      }
      this.uiState.hotWords = words
      this.uiState.isHotWordsLoading = false
      this.uiState.error = null
    } catch (e) {
      this.uiState.isHotWordsLoading = false
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainLoadHotWordsFailed())
    }
  }

  async addHotWord(word: string): Promise<void> {
    const trimmed: string = word.trim()
    if (trimmed.length === 0) {
      return
    }
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const body: HotWordCreateBody = { word: trimmed }
      await this.api.createHotWord(token, body)
      this.loadHotWords()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainSaveHotWordFailed())
    }
  }

  async updateHotWord(id: string, word: string): Promise<void> {
    const trimmed: string = word.trim()
    if (trimmed.length === 0) {
      return
    }
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const body: HotWordUpdateBody = { word: trimmed }
      await this.api.updateHotWord(token, id, body)
      this.loadHotWords()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainSaveHotWordFailed())
    }
  }

  async deleteHotWord(id: string): Promise<void> {
    try {
      const token: string = this.authPrefs.getAuthHeader()
      await this.api.deleteHotWord(token, id)
      this.loadHotWords()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainDeleteHotWordFailed())
    }
  }

  async loadPersonas(): Promise<void> {
    this.uiState.isPersonasLoading = true
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const response: PersonaListResponse = await this.api.getPersonas(token)
      this.uiState.personas = response.personas
      this.uiState.isPersonasLoading = false
      this.uiState.error = null
    } catch (e) {
      this.uiState.isPersonasLoading = false
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainLoadPersonasFailed())
    }
  }

  async createPersona(name: string, description: string, prompts: PersonaPrompts): Promise<void> {
    const trimmedName: string = name.trim()
    const userCount: number = this.uiState.personas.filter((p: PersonaItem): boolean => !p.is_builtin).length
    if (trimmedName.length === 0 || userCount >= PERSONA_MAX_COUNT) {
      return
    }
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const trimmedDesc: string = description.trim()
      const body: PersonaCreateBody = {
        name: trimmedName,
        description: trimmedDesc.length === 0 ? null : trimmedDesc,
        prompts: prompts
      }
      await this.api.createPersona(token, body)
      this.loadPersonas()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainSavePersonaFailed())
    }
  }

  async activatePersona(id: string): Promise<void> {
    try {
      const token: string = this.authPrefs.getAuthHeader()
      await this.api.activatePersona(token, id)
      this.loadPersonas()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainActivatePersonaFailed())
    }
  }

  async deactivatePersonas(): Promise<void> {
    try {
      const token: string = this.authPrefs.getAuthHeader()
      await this.api.deactivatePersonas(token)
      this.loadPersonas()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainActivatePersonaFailed())
    }
  }

  async updatePersona(id: string, name: string, description: string, prompts: PersonaPrompts): Promise<void> {
    const trimmedName: string = name.trim()
    if (trimmedName.length === 0) {
      return
    }
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const trimmedDesc: string = description.trim()
      const body: PersonaUpdateBody = {
        name: trimmedName,
        description: trimmedDesc.length === 0 ? null : trimmedDesc,
        prompts: prompts
      }
      await this.api.updatePersona(token, id, body)
      this.loadPersonas()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainSavePersonaFailed())
    }
  }

  async deletePersona(id: string): Promise<void> {
    try {
      const token: string = this.authPrefs.getAuthHeader()
      await this.api.deletePersona(token, id)
      this.loadPersonas()
    } catch (e) {
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainDeletePersonaFailed())
    }
  }

  async loadInviteCodes(): Promise<void> {
    if (this.uiState.plan === null || this.uiState.plan.show_invite_codes_enabled !== true) {
      this.uiState.inviteCodes = []
      this.uiState.isInviteCodesLoading = false
      return
    }
    this.uiState.isInviteCodesLoading = true
    try {
      const token: string = this.authPrefs.getAuthHeader()
      const response: MyInviteCodesResponse = await this.api.getMyInviteCodes(token)
      this.uiState.inviteCodes = response.invite_codes
      this.uiState.isInviteCodesLoading = false
      this.uiState.error = null
    } catch (e) {
      this.uiState.isInviteCodesLoading = false
      this.uiState.error = this.toUiError(e as Error, MobileStrings.mainLoadInviteCodesFailed())
    }
  }

  async logout(): Promise<void> {
    // fire-and-forget 通知服务端注销当前会话(幂等,失败不影响本地退出),与安卓 MainViewModel.logout 一致:
    // 先取 token 发起请求(不等待结果),再清本地登录态。
    const token: string = this.authPrefs.getAuthHeader()
    this.serverLogout(token)
    this.authPrefs.clear()
  }

  /** 服务端 logout 请求(吞掉一切错误,仅记日志)。 */
  private async serverLogout(token: string): Promise<void> {
    try {
      await this.api.logout(token)
    } catch (e) {
      Logger.w(TAG, `server logout failed: ${(e as Error).message}`)
    }
  }

  /**
   * 错误统一转 UI 文案;若为登录态失效(401 会话过期/账号封禁,token 已被 HttpClient 清除),
   * 额外通知页面回登录页(仅首次)。
   */
  private toUiError(e: Error, fallback: string): string {
    if (e instanceof ApiException &&
      (e.kind === ApiExceptionKind.UNAUTHORIZED || e.kind === ApiExceptionKind.USER_BANNED)) {
      if (!this.unauthorizedNotified) {
        this.unauthorizedNotified = true
        this.onUnauthorized()
      }
    }
    return displayMessage(e, fallback)
  }
}
