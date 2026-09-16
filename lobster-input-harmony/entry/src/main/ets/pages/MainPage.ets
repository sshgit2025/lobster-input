// 对应安卓 ui/main/MainScreen.kt(2209 行):主界面全部功能块的 ArkUI 复刻。
// 结构:顶栏 + 内容区(底部导航 home/history/persona/account 四个 tab,
// 以及 dictionary/subscription/invite 三个子页 + 人设编辑页)+ 底部导航栏。
// Compose NavHost → @State selectedTab/subPage 条件渲染(底栏常驻,与安卓 Scaffold 行为一致)。
import { common, Want, abilityAccessCtrl, bundleManager, Permissions } from '@kit.AbilityKit'
import { inputMethod } from '@kit.IMEKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { promptAction } from '@kit.ArkUI'
import { MobileStrings, MobileLanguage } from '../core/locale/MobileStrings'
import { MobileHistoryStore, MobileHistoryRecord, MobileHistoryStatus } from '../core/history/MobileHistoryStore'
import { AppPreferences } from '../data/local/AppPreferences'
import { ApiConfig } from '../core/network/ApiConfig'
import { TypingPreferences } from '../keyboard/typing/coordinator/TypingPreferences'
import { UpdateManager, UpdateManifest, InstalledVersion, UpdateCheckResult } from '../core/update/UpdateManager'
import { Logger } from '../core/log/Logger'
import {
  HotWordItem,
  PersonaItem,
  PersonaPrompts,
  InviteCodeItem,
  UserPlanInfo,
  PaymentCatalogResponse,
  PaymentSubscriptionPlan,
  PaymentBillingOption,
  PaymentCreditsTopup,
  emptyPersonaPrompts,
  PERSONA_MAX_COUNT,
  PERSONA_NAME_MAX_LENGTH,
  PERSONA_DESC_MAX_LENGTH,
  PERSONA_PROMPT_MAX_LENGTH
} from '../data/model/ApiModels'
import { MainViewModel, MainUiState } from './viewmodel/MainViewModel'
import { AppTheme, AppShapes, AppTypography, AppBrand } from './theme/AppTheme'

const TAG: string = 'MainPage'

// ==================== 返回键路由(由 Index @Entry 转发 onBackPress) ====================

export class BackRouter {
  onBack: (() => boolean) | null = null
}

// ==================== 多语言内联文案(对应 MainScreen.kt 私有 mobileText) ====================

function mobileText(language: MobileLanguage, zh: string, en: string, ru: string, ko: string,
  zhHant?: string, yue?: string): string {
  switch (language) {
    case MobileLanguage.ZH_HANT:
      return zhHant !== undefined ? zhHant : zh
    case MobileLanguage.YUE:
      return yue !== undefined ? yue : zh
    case MobileLanguage.EN:
      return en
    case MobileLanguage.RU:
      return ru
    case MobileLanguage.KO:
      return ko
    default:
      return zh
  }
}

/** MobileLanguage 全量列表(对应 MobileLanguage.values())。 */
const ALL_LANGUAGES: MobileLanguage[] =
  [MobileLanguage.ZH, MobileLanguage.ZH_HANT, MobileLanguage.YUE, MobileLanguage.EN, MobileLanguage.RU, MobileLanguage.KO]

/** 对应 Kotlin MobileLanguage.label。 */
function mobileLanguageLabel(language: MobileLanguage): string {
  switch (language) {
    case MobileLanguage.ZH_HANT:
      return '繁體中文'
    case MobileLanguage.YUE:
      return '粵語（廣東省版）'
    case MobileLanguage.EN:
      return 'English'
    case MobileLanguage.RU:
      return 'Русский'
    case MobileLanguage.KO:
      return '한국어'
    default:
      return '简体中文'
  }
}

function enabledText(language: MobileLanguage, enabled: boolean): string {
  return enabled
    ? mobileText(language, '开', 'On', 'Вкл', '켜짐', '開', '開')
    : mobileText(language, '关', 'Off', 'Выкл', '꺼짐', '關', '關')
}

function operationText(language: MobileLanguage, operation: string): string {
  if (operation === 'rewrite') {
    return mobileText(language, '指令', 'Command', 'Команда', '명령', '指令', '指令')
  }
  if (operation.indexOf('android_quick_') === 0 || operation.indexOf('quick_') === 0) {
    return mobileText(language, '快捷处理', 'Quick action', 'Быстро', '빠른 처리')
  }
  return mobileText(language, '语音输入', 'Voice input', 'Голосовой ввод', '음성 입력', '語音輸入', '語音輸入')
}

function billingCycleRank(cycle: string | null): number {
  switch (cycle) {
    case 'weekly':
      return 10
    case 'monthly':
      return 20
    case 'quarterly':
      return 30
    case 'yearly':
    case 'annual':
      return 40
    default:
      return 100
  }
}

function billingCycleTitle(language: MobileLanguage, cycle: string | null): string {
  switch (cycle) {
    case 'weekly':
      return mobileText(language, '周付', 'Weekly', 'Неделя', '주간')
    case 'monthly':
      return mobileText(language, '月付', 'Monthly', 'Месяц', '월간')
    case 'quarterly':
      return mobileText(language, '季付', 'Quarterly', 'Квартал', '분기')
    case 'yearly':
    case 'annual':
      return mobileText(language, '年付', 'Yearly', 'Год', '연간')
    default:
      return cycle !== null && cycle.length > 0 ? cycle : '-'
  }
}

function priceText(cents: number, currency: string | null | undefined): string {
  const code: string = currency !== null && currency !== undefined && currency.trim().length > 0
    ? currency.toUpperCase() : 'USD'
  let symbol: string = `${code} `
  if (code === 'USD') {
    symbol = 'US$'
  } else if (code === 'CNY') {
    symbol = '¥'
  } else if (code === 'EUR') {
    symbol = '€'
  } else if (code === 'GBP') {
    symbol = '£'
  }
  const whole: number = Math.floor(cents / 100)
  const frac: string = (cents % 100).toString().padStart(2, '0')
  return `${symbol}${whole}.${frac}`
}

/** 选项实际应付金额(分):优先服务端下发的 payable_price_cents(升级时为补差价),回退目录价。 */
function payableCents(option: PaymentBillingOption): number {
  return option.payable_price_cents !== undefined ? option.payable_price_cents : option.price_cents
}

/** 是否为补差价升级选项:服务端判定可购、按补差价结算且实际应付低于目录价。 */
function isUpgradeOption(option: PaymentBillingOption): boolean {
  return option.purchasable === true
    && option.settlement_mode === 'prorated_difference'
    && payableCents(option) < option.price_cents
}

/** 订阅按钮的选项级状态(2026-07 月付→年付补差价升级规则)。 */
enum PlanOptionState {
  /** 正常订阅 */
  SUBSCRIBE = 0,
  /** 补差价升级(可购) */
  UPGRADE = 1,
  /** 当前套餐(禁用) */
  CURRENT = 2,
  /** 暂不支持降级(禁用) */
  DOWNGRADE = 3,
}

function paymentCreditsText(language: MobileLanguage, credits: number): string {
  return mobileText(language, `${credits} 积分`, `${credits} credits`, `${credits} кредитов`, `${credits} 크레딧`)
}

function localizedPlanName(language: MobileLanguage, planCode: string): string {
  switch (planCode) {
    case 'trial':
      return mobileText(language, '免费试用', 'Free Trial', 'Пробный', '무료 체험', '免費試用', '免費試用')
    case 'free':
      return mobileText(language, '免费版', 'Free', 'Бесплатный', '무료', '免費版', '免費版')
    case 'weekly':
      return mobileText(language, '周套餐', 'Weekly', 'Недельный', '주간', '週套餐', '週套餐')
    case 'monthly':
      return mobileText(language, '月套餐', 'Monthly', 'Месячный', '월간', '月套餐', '月套餐')
    case 'yearly':
      return mobileText(language, '年套餐', 'Yearly', 'Годовой', '연간', '年套餐', '年套餐')
    case 'lite':
      return mobileText(language, '轻量套餐', 'Lite', 'Лайт', '라이트', '輕量套餐', '輕量套餐')
    case 'standard':
      return mobileText(language, '标准套餐', 'Standard', 'Стандарт', '스탠다드', '標準套餐', '標準套餐')
    case 'pro':
      return mobileText(language, '专业套餐', 'Pro', 'Про', '프로', '專業套餐', '專業套餐')
    case 'none':
    case '':
      return mobileText(language, '无套餐', 'No Plan', 'Нет тарифа', '요금제 없음', '無套餐', '無套餐')
    default:
      return planCode.length > 0 ? planCode.toUpperCase() : '-'
  }
}

/**
 * 将后端返回的 ISO8601 UTC 字符串(带/不带小数秒)格式化为本地日期(仅年月日)。
 * 无法解析或为空时返回 null。
 */
function formatServerDate(raw: string | null): string | null {
  if (raw === null || raw.length === 0) {
    return null
  }
  let ms: number = Date.parse(raw)
  if (isNaN(ms)) {
    // 回退:去掉小数秒后再试;补 Z 当作 UTC
    let normalized: string = raw.replace(' ', 'T')
    const dotIdx: number = normalized.indexOf('.')
    if (dotIdx >= 0) {
      normalized = normalized.substring(0, dotIdx)
    }
    if (normalized.indexOf('Z') < 0 && normalized.indexOf('+') < 0) {
      normalized = normalized + 'Z'
    }
    ms = Date.parse(normalized)
  }
  if (isNaN(ms)) {
    return null
  }
  const d: Date = new Date(ms)
  const pad = (n: number): string => n.toString().padStart(2, '0')
  return `${d.getFullYear()}/${pad(d.getMonth() + 1)}/${pad(d.getDate())}`
}

/** 对应 DateFormat.getDateTimeInstance(SHORT, SHORT)。 */
function formatDateTime(timestamp: number): string {
  const d: Date = new Date(timestamp)
  const pad = (n: number): string => n.toString().padStart(2, '0')
  return `${d.getFullYear()}/${pad(d.getMonth() + 1)}/${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function delayMs(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms)
  })
}

// ==================== 底部导航(对应 bottomNavItems) ====================

interface BottomNavItem {
  route: string
  icon: string
  label: string
}

function bottomNavItems(language: MobileLanguage): BottomNavItem[] {
  const items: BottomNavItem[] = [
    { route: 'home', icon: '🏠', label: mobileText(language, '首页', 'Home', 'Главная', '홈') },
    { route: 'history', icon: '🕘', label: mobileText(language, '历史', 'History', 'История', '기록') },
    { route: 'persona', icon: '👤', label: mobileText(language, '人设', 'Persona', 'Персона', '페르소나', '人設', '人設') },
    { route: 'account', icon: '⚙️', label: mobileText(language, '设置', 'Settings', 'Настройки', '설정') }
  ]
  return items
}

// ==================== @Builder 参数接口(对象字面量按引用传递保证刷新) ====================

interface TextP {
  text: string
}

interface InfoRowP {
  label: string
  value: string
}

interface SettingRowP {
  icon: string
  title: string
  subtitle: string
  enabled: boolean
  action: () => void
  /** 可选徽章文案(标题右侧小胶囊,如环境徽章"内测版/正式版") */
  badge?: string
}

interface SettingSwitchRowP {
  icon: string
  title: string
  subtitle: string
  checked: boolean
  onChange: (on: boolean) => void
}

interface StatusRowP {
  label: string
  ok: boolean
}

interface SetupStepP {
  index: number
  title: string
  desc: string
}

interface EmptyCardP {
  title: string
  subtitle: string
}

/** 检查更新对话框状态(对应 sealed AccountUpdateUiState;鸿蒙不做 APK 下载,精简掉下载/装包权限态)。 */
enum AccountUpdateKind {
  None = 'none',
  Checking = 'checking',
  NoUpdate = 'noUpdate',
  Available = 'available',
  Error = 'error'
}

// ==================== 主页面 ====================

@Component
export struct MainPage {
  /** 退出登录回调(对应 MainScreen onLogout)。 */
  onLogout: () => void = () => {}
  /** 系统返回键路由(Index @Entry 持有并转发)。 */
  backRouter: BackRouter = new BackRouter()

  @State language: MobileLanguage = MobileLanguage.ZH
  @State uiState: MainUiState = new MainUiState()
  @State email: string = ''
  @State selectedTab: string = 'home'
  /** '' | 'dictionary' | 'subscription' | 'invite' */
  @State subPage: string = ''
  @State historyRecords: MobileHistoryRecord[] = []
  // 词典页局部状态
  @State newWord: string = ''
  @State editingHotWordId: string = ''
  // 人设页局部状态
  @State showCreateDialog: boolean = false
  @State editingPersonaId: string = ''
  // 设置页局部状态
  @State imeCurrent: boolean = false
  @State hasRecordAudioPermission: boolean = false
  @State realtimeRecognitionEnabled: boolean = false
  // 拼音键盘:模糊音(单个总开关,默认关)+ 纠错(默认开)
  @State fuzzyEnabled: boolean = false
  @State pinyinCorrectionEnabled: boolean = true
  @State updateKind: AccountUpdateKind = AccountUpdateKind.None
  @State updateManifest: UpdateManifest | null = null
  @State updateError: string = ''
  @State installedVersionName: string = ''
  @State installedVersionCode: number = 0
  // 订阅页:各套餐已选计费周期(对应 mutableStateMapOf)
  @State selectedCycles: Map<string, string> = new Map<string, string>()
  // 订阅页:取消自动续费确认弹窗
  @State showCancelRenewalDialog: boolean = false

  private viewModel: MainViewModel | null = null
  private historyStore: MobileHistoryStore | null = null
  private updateManager: UpdateManager | null = null
  private prefs: AppPreferences | null = null

  async aboutToAppear(): Promise<void> {
    const context: common.Context = getContext(this)
    this.backRouter.onBack = (): boolean => this.handleBack()
    this.language = MobileStrings.currentLanguage()

    this.historyStore = new MobileHistoryStore()
    this.updateManager = new UpdateManager()
    this.prefs = AppPreferences.getInstance(context)

    const vm: MainViewModel = new MainViewModel(context, this.uiState)
    // 对应 LaunchedEffect(uiState.checkoutUrl):打开外部浏览器后消费掉 URL
    vm.onCheckoutUrl = (url: string): void => {
      this.openUrl(url)
      vm.consumeCheckoutUrl()
    }
    // 登录态失效(401 会话过期/封禁,token 已被 HttpClient 清除):提示后回登录页
    // (对应安卓 LobsterApp 监听 SharedPreferences token 变化自动回登录页)
    vm.onUnauthorized = (): void => {
      promptAction.showToast({ message: MobileStrings.sessionExpired() })
      this.onLogout()
    }
    this.viewModel = vm

    // 对应 LaunchedEffect(Unit) { viewModel.refreshAll() }
    vm.refreshAll()
    const email: string | null = await vm.getEmail()
    this.email = email !== null ? email : ''

    this.refreshHistory()
    this.loadLocalPreferences()
    try {
      const version: InstalledVersion = await this.updateManager.currentInstalledVersion()
      this.installedVersionName = version.versionName
      this.installedVersionCode = version.versionCode
    } catch (e) {
      Logger.w(TAG, `read installed version failed: ${(e as Error).message}`)
    }
    this.refreshInputStatusSoon()
  }

  /**
   * 环境徽章文案:由 ApiConfig.ENVIRONMENT(ACTIVE_ENV)动态派生,禁止写死。
   * preview(内测环境)→ 内测版;uat(公测环境)→ 正式版。
   */
  private envBadgeText(): string {
    if (ApiConfig.ENVIRONMENT === 'uat') {
      return mobileText(this.language, '正式版', 'Official', 'Релиз', '정식판', '正式版', '正式版')
    }
    return mobileText(this.language, '内测版', 'Beta', 'Бета', '베타', '內測版', '內測版')
  }

  aboutToDisappear(): void {
    this.backRouter.onBack = null
  }

  // ==================== 返回键处理(对应 popBackStack 层级) ====================

  private handleBack(): boolean {
    if (this.updateKind !== AccountUpdateKind.None) {
      if (this.updateKind !== AccountUpdateKind.Checking) {
        this.updateKind = AccountUpdateKind.None
      }
      return true
    }
    if (this.showCreateDialog) {
      this.showCreateDialog = false
      return true
    }
    if (this.editingPersonaId.length > 0) {
      this.editingPersonaId = ''
      return true
    }
    if (this.subPage.length > 0) {
      this.subPage = ''
      return true
    }
    if (this.selectedTab !== 'home') {
      this.selectedTab = 'home'
      return true
    }
    return false
  }

  // ==================== 数据/系统辅助 ====================

  private refreshHistory(): void {
    const store: MobileHistoryStore | null = this.historyStore
    if (store === null) {
      return
    }
    this.historyRecords = store.records()
  }

  private async loadLocalPreferences(): Promise<void> {
    const prefs: AppPreferences | null = this.prefs
    if (prefs === null) {
      return
    }
    try {
      this.realtimeRecognitionEnabled = await prefs.getBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, false)
      this.fuzzyEnabled = await prefs.getBoolean(TypingPreferences.KEY_FUZZY_ZZH, false)
      this.pinyinCorrectionEnabled = await prefs.getBoolean(TypingPreferences.KEY_CORRECTION, true)
    } catch (e) {
      Logger.w(TAG, `load local prefs failed: ${(e as Error).message}`)
    }
  }

  /** 对应 isLobsterImeCurrent():当前默认输入法是否为龙虾输入法。 */
  private isLobsterImeCurrent(): boolean {
    try {
      const prop: inputMethod.InputMethodProperty = inputMethod.getCurrentInputMethod()
      const compatProp = prop as Object as Record<string, string>
      return this.isLobsterImePropertyValue(prop.name) ||
        this.isLobsterImePropertyValue(prop.id) ||
        this.isLobsterImePropertyValue(compatProp['packageName']) ||
        this.isLobsterImePropertyValue(compatProp['methodId'])
    } catch (e) {
      return false
    }
  }

  private isLobsterImePropertyValue(value: string | undefined): boolean {
    return value === 'com.lobster.input' || value === 'LobsterImeAbility'
  }

  private checkMicPermission(): boolean {
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager()
      const bundleInfo: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      const status: abilityAccessCtrl.GrantStatus =
        atManager.checkAccessTokenSync(bundleInfo.appInfo.accessTokenId, 'ohos.permission.MICROPHONE')
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED
    } catch (e) {
      return false
    }
  }

  private refreshInputStatus(): void {
    this.imeCurrent = this.isLobsterImeCurrent()
    this.hasRecordAudioPermission = this.checkMicPermission()
  }

  /** 从系统设置返回后连续探测 10 次(对应 refreshInputStatusSoon)。 */
  private async refreshInputStatusSoon(): Promise<void> {
    this.refreshInputStatus()
    for (let i = 0; i < 10; i++) {
      await delayMs(700)
      this.refreshInputStatus()
    }
  }

  /** 对应 microphonePermissionLauncher:拉起系统麦克风授权弹窗。 */
  private async requestMicPermission(): Promise<void> {
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager()
      const permissions: Array<Permissions> = ['ohos.permission.MICROPHONE']
      const result = await atManager.requestPermissionsFromUser(context, permissions)
      this.hasRecordAudioPermission = result.authResults.length > 0 && result.authResults[0] === 0
    } catch (e) {
      Logger.w(TAG, `requestMicPermission failed: ${(e as Error).message}`)
    }
  }

  /** 鸿蒙对应「打开输入法设置」:Want 跳系统设置输入法页;跳不进则退回设置首页/文字引导。 */
  private async openInputMethodSettings(): Promise<void> {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
    try {
      const element = inputMethod.getSystemInputMethodConfigAbility()
      const imeWant: Want = {
        bundleName: element.bundleName,
        moduleName: element.moduleName,
        abilityName: element.abilityName
      }
      await context.startAbility(imeWant)
    } catch (e) {
      const settingsWant: Want = {
        bundleName: 'com.huawei.hmos.settings',
        abilityName: 'com.huawei.hmos.settings.MainAbility'
      }
      try {
        await context.startAbility(settingsWant)
      } catch (e2) {
        promptAction.showToast({
          message: mobileText(this.language,
            '请前往 设置 → 系统 → 键盘与输入法 启用龙虾输入法',
            'Open Settings → System → Keyboard & input method to enable Lobster.',
            'Откройте Настройки → Система → Клавиатура и ввод, чтобы включить Lobster.',
            '설정 → 시스템 → 키보드 및 입력 방식에서 랍스터 입력기를 켜세요.')
        })
      }
    }
    this.refreshInputStatusSoon()
  }

  /** 鸿蒙对应「切换当前输入法」:拉起系统输入法选择器。 */
  private async showImePicker(): Promise<void> {
    try {
      await inputMethod.getSetting().showOptionalInputMethods()
    } catch (e) {
      promptAction.showToast({
        message: mobileText(this.language, '无法打开输入法选择器', 'Could not open keyboard picker',
          'Не удалось открыть выбор клавиатуры', '입력기 선택 창을 열 수 없습니다')
      })
    }
    this.refreshInputStatusSoon()
  }

  private openUrl(url: string): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    }
    context.startAbility(want).catch((e: Error) => {
      Logger.w(TAG, `openUrl failed: ${e.message}`)
    })
  }

  /** 鸿蒙不做 APK 侧载:发现新版本时引导前往应用市场。 */
  private openAppGallery(): void {
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext
    const want: Want = {
      action: 'ohos.want.action.appdetail',
      uri: 'store://appgallery.huawei.com/app/detail?id=com.lobster.input'
    }
    context.startAbility(want).catch((e: Error) => {
      Logger.w(TAG, `openAppGallery failed: ${e.message}`)
      promptAction.showToast({
        message: mobileText(this.language, '请前往应用市场搜索“龙虾输入法”更新', 'Search "Lobster Input" in AppGallery to update.',
          'Найдите "Lobster Input" в AppGallery для обновления.', 'AppGallery에서 "랍스터 입력기"를 검색해 업데이트하세요.')
      })
    })
  }

  private copyToClipboard(text: string): void {
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      promptAction.showToast({
        message: mobileText(this.language, '已复制', 'Copied', 'Скопировано', '복사됨')
      })
    }).catch((e: Error) => {
      Logger.w(TAG, `copy failed: ${e.message}`)
    })
  }

  /** 对应 AccountScreen checkUpdate():走 UpdateManager 契约。 */
  private async checkUpdate(): Promise<void> {
    if (this.updateKind === AccountUpdateKind.Checking) {
      return
    }
    this.updateKind = AccountUpdateKind.Checking
    const manager: UpdateManager | null = this.updateManager
    if (manager === null) {
      this.updateKind = AccountUpdateKind.None
      return
    }
    try {
      const result: UpdateCheckResult = await manager.checkForUpdate()
      if (result.updateAvailable && result.manifest !== null) {
        this.updateManifest = result.manifest
        this.updateKind = AccountUpdateKind.Available
      } else {
        this.updateKind = AccountUpdateKind.NoUpdate
      }
    } catch (e) {
      const message: string = (e as Error).message
      this.updateError = message !== undefined && message.length > 0
        ? message
        : mobileText(this.language, '检查更新失败', 'Update check failed', 'Не удалось проверить обновления', '업데이트 확인 실패')
      this.updateKind = AccountUpdateKind.Error
    }
  }

  private onLanguageChange(item: MobileLanguage): void {
    MobileStrings.setLanguage(item)
    this.language = item
    this.viewModel?.loadPersonas()
  }

  /** 切换底部 tab(对应 navController.navigate + popUpTo home)。 */
  private selectTab(route: string): void {
    this.subPage = ''
    this.selectedTab = route
    if (route === 'history') {
      this.refreshHistory()
    } else if (route === 'persona') {
      this.viewModel?.loadPersonas()
    }
  }

  // ==================== 订阅目录派生计算(对应 PaymentSubscriptionCard 内逻辑) ====================

  private sortedSubscriptions(): PaymentSubscriptionPlan[] {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null) {
      return []
    }
    return catalog.subscriptions.slice().sort(
      (a: PaymentSubscriptionPlan, b: PaymentSubscriptionPlan): number => a.rank - b.rank)
  }

  private sortedOptions(plan: PaymentSubscriptionPlan): PaymentBillingOption[] {
    return plan.billing_options.slice().sort(
      (a: PaymentBillingOption, b: PaymentBillingOption): number => billingCycleRank(a.cycle) - billingCycleRank(b.cycle))
  }

  /** 已选周期:优先用户选择,否则第一个可购选项,否则 monthly,否则第一个。 */
  private effectiveCycle(plan: PaymentSubscriptionPlan): string {
    const chosen: string | undefined = this.selectedCycles.get(plan.plan_code)
    if (chosen !== undefined && chosen.length > 0) {
      return chosen
    }
    const options: PaymentBillingOption[] = this.sortedOptions(plan)
    for (let i = 0; i < options.length; i++) {
      if (this.isOptionPurchasable(plan, options[i])) {
        return options[i].cycle
      }
    }
    for (let i = 0; i < options.length; i++) {
      if (options[i].cycle === 'monthly') {
        return options[i].cycle
      }
    }
    return options.length > 0 ? options[0].cycle : ''
  }

  /** 当前套餐是否为付费套餐(未付费时所有选项均可购)。 */
  private currentPlanPaid(): boolean {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    return catalog !== null && catalog.current_plan.paid
  }

  /**
   * 选项级可购判定(与 PaymentPlanRowView.optionState 同源规则):
   * 未付费全可购;服务端下发 purchasable 时以服务端为准;旧后端回退套餐级判定。
   */
  private isOptionPurchasable(plan: PaymentSubscriptionPlan, option: PaymentBillingOption): boolean {
    if (!this.currentPlanPaid()) {
      return true
    }
    if (option.purchasable !== undefined) {
      return option.purchasable
    }
    return !this.isCurrentPlan(plan) && !this.isLowerTier(plan)
  }

  private currentPlanRank(): number {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null) {
      return -1
    }
    for (let i = 0; i < catalog.subscriptions.length; i++) {
      if (catalog.subscriptions[i].plan_code === catalog.current_plan.plan_code) {
        return catalog.subscriptions[i].rank
      }
    }
    return -1
  }

  private isCurrentPlan(plan: PaymentSubscriptionPlan): boolean {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    return catalog !== null && catalog.current_plan.paid && catalog.current_plan.plan_code === plan.plan_code
  }

  private isLowerTier(plan: PaymentSubscriptionPlan): boolean {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null || !catalog.current_plan.paid) {
      return false
    }
    const currentRank: number = this.currentPlanRank()
    return currentRank >= 0 && plan.rank <= currentRank && !this.isCurrentPlan(plan)
  }

  private findEditingPersona(): PersonaItem | null {
    if (this.editingPersonaId.length === 0) {
      return null
    }
    for (let i = 0; i < this.uiState.personas.length; i++) {
      if (this.uiState.personas[i].id === this.editingPersonaId) {
        return this.uiState.personas[i]
      }
    }
    return null
  }

  private userPersonaCount(): number {
    return this.uiState.personas.filter((p: PersonaItem): boolean => !p.is_builtin).length
  }

  private planCreditsLine(): string {
    const plan: UserPlanInfo | null = this.uiState.plan
    if (plan === null) {
      return mobileText(this.language, '加载中', 'Loading', 'Загрузка', '로딩 중')
    }
    return `${plan.credits_remaining} / ${plan.credits_total}`
  }

  /** 套餐有效期:优先订阅到期时间,回退套餐到期时间;均为空表示永久有效。 */
  private planExpiryLine(): string {
    const plan: UserPlanInfo | null = this.uiState.plan
    if (plan === null) {
      return mobileText(this.language, '加载中', 'Loading', 'Загрузка', '로딩 중')
    }
    const formatted: string | null = formatServerDate(plan.subscription_expires_at)
      ?? formatServerDate(plan.plan_expires_at)
    return formatted ?? mobileText(this.language, '永久有效', 'No expiry', 'Бессрочно', '무기한', '永久有效', '永久有效')
  }

  // ==================== build ====================

  build() {
    Stack() {
      Column() {
        this.TopBar()
        Column() {
          if (this.subPage === 'dictionary') {
            this.DictionaryContent()
          } else if (this.subPage === 'subscription') {
            this.SubscriptionContent()
          } else if (this.subPage === 'invite') {
            this.InviteContent()
          } else if (this.selectedTab === 'home') {
            this.HomeContent()
          } else if (this.selectedTab === 'history') {
            this.HistoryContent()
          } else if (this.selectedTab === 'persona') {
            this.PersonaContent()
          } else {
            this.AccountContent()
          }
        }
        .layoutWeight(1)
        .width('100%')

        this.BottomBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppTheme.colors.background)

      // 新建人设弹窗(对应 CreatePersonaDialog)
      if (this.showCreateDialog) {
        CreatePersonaDialogView({
          language: this.language,
          onDismiss: (): void => {
            this.showCreateDialog = false
          },
          onCreate: (name: string, desc: string, prompts: PersonaPrompts): void => {
            this.viewModel?.createPersona(name, desc, prompts)
            this.showCreateDialog = false
          }
        })
      }

      // 检查更新弹窗(对应 AndroidUpdateDialog,鸿蒙改为应用市场引导)
      if (this.updateKind !== AccountUpdateKind.None) {
        this.UpdateDialog()
      }

      // 取消自动续费确认弹窗
      if (this.showCancelRenewalDialog) {
        this.CancelRenewalDialog()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 顶栏 / 底栏 ====================

  @Builder
  TopBar() {
    Row() {
      Text(MobileStrings.keyboardTitle())
        .fontSize(AppTypography.titleLarge.fontSize)
        .fontWeight(AppTypography.titleLarge.fontWeight)
        .fontColor(AppTheme.colors.onPrimaryContainer)
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor(AppTheme.colors.primaryContainer)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  BottomBar() {
    Row() {
      ForEach(bottomNavItems(this.language), (item: BottomNavItem) => {
        Column() {
          Text(item.icon)
            .fontSize(20)
            .padding({ left: 16, right: 16, top: 3, bottom: 3 })
            .backgroundColor(this.selectedTab === item.route && this.subPage === ''
              ? AppTheme.colors.primaryContainer : Color.Transparent)
            .borderRadius(16)
          Blank().height(3)
          Text(item.label)
            .fontSize(AppTypography.labelMedium.fontSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.selectedTab === item.route && this.subPage === ''
              ? AppTheme.colors.primary : AppTheme.colors.onSurfaceVariant)
        }
        .layoutWeight(1)
        .padding({ top: 8, bottom: 8 })
        .alignItems(HorizontalAlign.Center)
        .onClick(() => {
          this.selectTab(item.route)
        })
      }, (item: BottomNavItem): string => `${this.language}|${item.route}|${this.selectedTab}|${this.subPage}`)
    }
    .width('100%')
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 6, color: '#14000000', offsetY: -1 })
  }

  // ==================== 通用小件 ====================

  /** 分组小标题(对应 SectionHeader)。 */
  @Builder
  SectionHeader(p: TextP) {
    Text(p.text)
      .fontSize(AppTypography.labelLarge.fontSize)
      .fontWeight(FontWeight.Medium)
      .letterSpacing(0.6)
      .fontColor(AppTheme.colors.primary)
      .padding({ left: 6, top: 8, bottom: 2 })
      .width('100%')
      .textAlign(TextAlign.Start)
  }

  /** 键值信息行(对应 InfoRow)。 */
  @Builder
  InfoRow(p: InfoRowP) {
    Row() {
      Text(p.label)
        .fontSize(AppTypography.bodyMedium.fontSize)
        .fontColor(AppTheme.colors.onSurfaceVariant)
      Blank().layoutWeight(1)
      Text(p.value)
        .fontSize(AppTypography.bodyMedium.fontSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppTheme.colors.onSurface)
    }
    .width('100%')
  }

  /** 统一设置行:左侧圆角图标徽章 + 标题/副标题 + 尾部箭头(对应 SettingRow)。 */
  @Builder
  SettingRow(p: SettingRowP) {
    Row() {
      Text(p.icon)
        .fontSize(18)
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.colors.primaryContainer)
        .borderRadius(10)
      Blank().width(14)
      Column() {
        Row() {
          Text(p.title)
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.colors.onSurface)
          if (p.badge !== undefined && p.badge.length > 0) {
            Text(p.badge)
              .fontSize(10)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppTheme.colors.onPrimaryContainer)
              .backgroundColor(AppTheme.colors.primaryContainer)
              .borderRadius(8)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .margin({ left: 6 })
          }
        }
        if (p.subtitle.length > 0) {
          Text(p.subtitle)
            .fontSize(AppTypography.bodySmall.fontSize)
            .fontColor(AppTheme.colors.onSurfaceVariant)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Blank().width(12)
      Text('›')
        .fontSize(20)
        .fontColor(AppTheme.colors.onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .opacity(p.enabled ? 1 : 0.5)
    .onClick(() => {
      if (p.enabled) {
        p.action()
      }
    })
  }

  /** 带开关的设置行(对应 SettingRow trailing Switch)。 */
  @Builder
  SettingSwitchRow(p: SettingSwitchRowP) {
    Row() {
      Text(p.icon)
        .fontSize(18)
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.colors.primaryContainer)
        .borderRadius(10)
      Blank().width(14)
      Column() {
        Text(p.title)
          .fontSize(AppTypography.bodyLarge.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.colors.onSurface)
        if (p.subtitle.length > 0) {
          Text(p.subtitle)
            .fontSize(AppTypography.bodySmall.fontSize)
            .fontColor(AppTheme.colors.onSurfaceVariant)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Blank().width(12)
      Toggle({ type: ToggleType.Switch, isOn: p.checked })
        .selectedColor(AppTheme.colors.primary)
        .onChange((on: boolean) => {
          p.onChange(on)
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
  }

  /** 行间细分割线(对应 RowDivider)。 */
  @Builder
  RowDivider() {
    Divider()
      .color(AppTheme.colors.outlineAlpha50)
      .margin({ left: 66 })
  }

  /** 空态卡片(对应 EmptyCard)。 */
  @Builder
  EmptyCard(p: EmptyCardP) {
    Column() {
      Text(p.title)
        .fontSize(AppTypography.titleMedium.fontSize)
        .fontWeight(AppTypography.titleMedium.fontWeight)
        .fontColor(AppTheme.colors.onSurface)
      Blank().height(6)
      Text(p.subtitle)
        .fontSize(AppTypography.bodyMedium.fontSize)
        .fontColor(AppTheme.colors.onSurfaceVariant)
    }
    .width('100%')
    .padding(20)
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 输入法配置状态行(对应 InputStatusRow)。 */
  @Builder
  InputStatusRow(p: StatusRowP) {
    Row() {
      Text(p.ok ? '✓' : 'ℹ')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(p.ok ? AppTheme.colors.primary : AppTheme.colors.error)
        .width(20)
        .textAlign(TextAlign.Center)
      Blank().width(8)
      Text(p.label)
        .fontSize(AppTypography.bodyMedium.fontSize)
        .fontColor(AppTheme.colors.onSurface)
        .layoutWeight(1)
      Text(p.ok ? 'OK' : 'Todo')
        .fontSize(AppTypography.labelMedium.fontSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(p.ok ? AppTheme.colors.onPrimaryContainer : AppTheme.colors.onErrorContainer)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .backgroundColor(p.ok ? AppTheme.colors.primaryContainer : AppTheme.colors.errorContainer)
        .borderRadius(AppShapes.chip)
    }
    .width('100%')
  }

  /** 步骤引导(对应 SetupStep)。 */
  @Builder
  SetupStep(p: SetupStepP) {
    Row() {
      Text(p.index.toString())
        .fontSize(AppTypography.labelLarge.fontSize)
        .fontColor(AppTheme.colors.onPrimaryContainer)
        .width(28)
        .height(28)
        .textAlign(TextAlign.Center)
        .backgroundColor(AppTheme.colors.primaryContainer)
        .borderRadius(14)
      Blank().width(12)
      Column() {
        Text(p.title)
          .fontSize(AppTypography.titleSmall.fontSize)
          .fontWeight(AppTypography.titleSmall.fontWeight)
          .fontColor(AppTheme.colors.onSurface)
        Text(p.desc)
          .fontSize(AppTypography.bodySmall.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /** 子页返回标题行。 */
  @Builder
  SubPageHeader(p: TextP) {
    Row() {
      Text('‹')
        .fontSize(28)
        .fontColor(AppTheme.colors.onBackground)
        .width(40)
        .height(40)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.subPage = ''
        })
      Text(p.text)
        .fontSize(AppTypography.titleLarge.fontSize)
        .fontWeight(AppTypography.titleLarge.fontWeight)
        .fontColor(AppTheme.colors.onBackground)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  // ==================== 首页(对应 HomeScreen) ====================

  @Builder
  HomeContent() {
    Scroll() {
      Column({ space: 14 }) {
        // 水波渐变品牌 Hero(对应 BrandHeroCard)
        Column({ space: 12 }) {
          Text('🎙')
            .fontSize(26)
            .width(48)
            .height(48)
            .textAlign(TextAlign.Center)
            .backgroundColor('#38FFFFFF')
            .borderRadius(24)
          Text(mobileText(this.language, '纯语音输入法已就绪', 'Voice input is ready',
            'Голосовой ввод готов', '음성 입력 준비됨'))
            .fontSize(AppTypography.titleLarge.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
          Text(mobileText(this.language,
            '在任意输入框切换到龙虾输入法后，可以直接使用语音输入和指令处理。系统输入法启用、切换和麦克风权限请到“设置”页完成。',
            'Switch to Lobster in any text field to use voice input and commands. Keyboard setup and microphone permission are in Settings.',
            'Выберите Lobster в любом поле, чтобы использовать голосовой ввод и команды. Настройка и микрофон находятся в настройках.',
            '입력창에서 랍스터 입력기로 전환하면 음성 입력과 명령을 사용할 수 있습니다. 키보드와 마이크 설정은 설정에서 진행하세요.'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor('#EBFFFFFF')
        }
        .width('100%')
        .padding(20)
        .borderRadius(AppShapes.card)
        .linearGradient({
          angle: 135,
          colors: [[AppBrand.gradientStart, 0], [AppBrand.gradientEnd, 1]]
        })
        .alignItems(HorizontalAlign.Start)

        this.SectionHeader({ text: mobileText(this.language, '账户状态', 'Account status', 'Статус аккаунта', '계정 상태') })

        // 账户概览卡
        Column({ space: 10 }) {
          Row() {
            Text(mobileText(this.language, '账户概览', 'Overview', 'Обзор', '개요'))
              .fontSize(AppTypography.titleMedium.fontSize)
              .fontWeight(AppTypography.titleMedium.fontWeight)
              .fontColor(AppTheme.colors.onSurface)
            Blank().layoutWeight(1)
            Text('↻')
              .fontSize(20)
              .fontColor(AppTheme.colors.primary)
              .width(36)
              .height(36)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.viewModel?.refreshAll()
              })
          }
          .width('100%')

          this.InfoRow({
            label: mobileText(this.language, '邮箱', 'Email', 'Почта', '이메일'),
            value: this.email.length > 0 ? this.email
              : mobileText(this.language, '未登录', 'Not signed in', 'Не выполнен вход', '로그인 안 됨')
          })
          this.InfoRow({
            label: mobileText(this.language, '套餐', 'Plan', 'Тариф', '요금제'),
            value: this.uiState.plan !== null
              ? ((this.uiState.plan.plan_name ?? '').trim().length > 0 ? (this.uiState.plan.plan_name as string) : localizedPlanName(this.language, this.uiState.plan.tier))
              : mobileText(this.language, '加载中', 'Loading', 'Загрузка', '로딩 중')
          })
          this.InfoRow({
            label: mobileText(this.language, '积分', 'Credits', 'Кредиты', '크레딧'),
            value: this.planCreditsLine()
          })
          if (this.uiState.plan !== null) {
            this.InfoRow({
              label: mobileText(this.language, '已用积分', 'Used', 'Использовано', '사용됨'),
              value: `${this.uiState.plan.credits_used}`
            })
            if (formatServerDate(this.uiState.plan.credits_reset_at) !== null) {
              this.InfoRow({
                label: mobileText(this.language, '积分重置日期', 'Credits reset', 'Сброс кредитов', '크레딧 초기화'),
                value: formatServerDate(this.uiState.plan.credits_reset_at)!
              })
            }
            this.InfoRow({
              label: mobileText(this.language, '套餐有效期', 'Plan valid until', 'Действует до', '요금제 유효기간'),
              value: this.planExpiryLine()
            })
          }
        }
        .width('100%')
        .padding(18)
        .borderRadius(AppShapes.card)
        .backgroundColor(AppTheme.colors.surface)
        .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
        .alignItems(HorizontalAlign.Start)

        // 错误提示 chip(点击重试)
        if (this.uiState.error !== null && this.uiState.error.length > 0) {
          Row() {
            Text('ℹ')
              .fontSize(14)
              .fontColor(AppTheme.colors.error)
            Blank().width(6)
            Text(this.uiState.error)
              .fontSize(AppTypography.labelLarge.fontSize)
              .fontColor(AppTheme.colors.onErrorContainer)
          }
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(AppTheme.colors.errorContainer)
          .borderRadius(AppShapes.chip)
          .onClick(() => {
            this.viewModel?.refreshAll()
          })
        }
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  // ==================== 历史(对应 HistoryScreen) ====================

  @Builder
  HistoryContent() {
    Column({ space: 10 }) {
      Row() {
        Text(mobileText(this.language, '历史记录', 'History', 'История', '기록'))
          .fontSize(AppTypography.titleLarge.fontSize)
          .fontWeight(AppTypography.titleLarge.fontWeight)
          .fontColor(AppTheme.colors.onBackground)
        Blank().layoutWeight(1)
        Text('↻')
          .fontSize(20)
          .fontColor(AppTheme.colors.primary)
          .width(36)
          .height(36)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.refreshHistory()
          })
        if (this.historyRecords.length > 0) {
          Text('🗑')
            .fontSize(18)
            .fontColor(AppTheme.colors.error)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.historyStore?.clearAll()
              this.refreshHistory()
            })
        }
      }
      .width('100%')

      if (this.historyRecords.length === 0) {
        this.EmptyCard({
          title: mobileText(this.language, '暂无历史记录', 'No history yet', 'Истории пока нет', '기록 없음'),
          subtitle: mobileText(this.language, '使用输入法完成语音输入或指令处理后，记录会显示在这里。',
            'Voice input and command results will appear here.',
            'Результаты голосового ввода и команд появятся здесь.',
            '음성 입력과 명령 결과가 여기에 표시됩니다.')
        })
      } else {
        List({ space: 10 }) {
          ForEach(this.historyRecords, (record: MobileHistoryRecord) => {
            ListItem() {
              HistoryRecordCard({
                language: this.language,
                record: record,
                onCopy: (text: string): void => {
                  this.copyToClipboard(text)
                },
                onDelete: (): void => {
                  this.historyStore?.delete(record.id)
                  this.refreshHistory()
                }
              })
            }
          }, (record: MobileHistoryRecord): string => `${this.language}|${record.id}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  // ==================== 热词词典(对应 DictionaryScreen) ====================

  @Builder
  DictionaryContent() {
    Column({ space: 12 }) {
      this.SubPageHeader({ text: mobileText(this.language, '热词词典', 'Hot words', 'Словарь', '단어 사전') })

      Row() {
        TextInput({
          placeholder: mobileText(this.language, '添加热词', 'Add word', 'Добавить слово', '단어 추가'),
          text: this.newWord
        })
          .height(52)
          .layoutWeight(1)
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.surface)
          .fontColor(AppTheme.colors.onSurface)
          .placeholderColor(AppTheme.colors.onSurfaceVariant)
          .onChange((value: string) => {
            this.newWord = value
          })
        Blank().width(8)
        Button('+')
          .fontSize(24)
          .fontColor(AppTheme.colors.onPrimary)
          .width(52)
          .height(52)
          .borderRadius(AppShapes.button)
          .backgroundColor(AppTheme.colors.primary)
          .enabled(this.newWord.trim().length > 0)
          .opacity(this.newWord.trim().length > 0 ? 1 : 0.5)
          .onClick(() => {
            this.viewModel?.addHotWord(this.newWord)
            this.newWord = ''
          })
      }
      .width('100%')

      if (this.uiState.isHotWordsLoading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(AppTheme.colors.primary)
          .alignSelf(ItemAlign.Center)
      }

      List({ space: 8 }) {
        if (this.uiState.hotWords.length === 0 && !this.uiState.isHotWordsLoading) {
          ListItem() {
            this.EmptyCard({
              title: mobileText(this.language, '暂无热词', 'No words yet', 'Слов пока нет', '단어 없음'),
              subtitle: mobileText(this.language, '添加行业术语、人名、产品名后，语音识别会更稳定。',
                'Add terms, names, and product names to improve recognition.',
                'Добавьте термины, имена и продукты для лучшего распознавания.',
                '용어, 이름, 제품명을 추가하면 인식이 더 안정적입니다.')
            })
          }
        }
        ForEach(this.uiState.hotWords, (item: HotWordItem) => {
          ListItem() {
            HotWordRow({
              language: this.language,
              item: item,
              isEditing: this.editingHotWordId === item.id,
              onStartEdit: (): void => {
                this.editingHotWordId = item.id
              },
              onSave: (word: string): void => {
                this.viewModel?.updateHotWord(item.id, word)
                this.editingHotWordId = ''
              },
              onCancel: (): void => {
                this.editingHotWordId = ''
              },
              onDelete: (): void => {
                this.viewModel?.deleteHotWord(item.id)
              }
            })
          }
        }, (item: HotWordItem): string =>
          `${this.language}|${item.id}|${item.word}|${this.editingHotWordId === item.id ? '1' : '0'}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  // ==================== 人设(对应 PersonaScreen / PersonaEditScreen) ====================

  @Builder
  PersonaContent() {
    if (this.findEditingPersona() !== null) {
      PersonaEditView({
        language: this.language,
        persona: this.findEditingPersona() as PersonaItem,
        isLoading: this.uiState.isPersonasLoading,
        onBack: (): void => {
          this.editingPersonaId = ''
        },
        onSave: (name: string, desc: string, prompts: PersonaPrompts): void => {
          this.viewModel?.updatePersona(this.editingPersonaId, name, desc, prompts)
          this.editingPersonaId = ''
        }
      })
    } else {
      Column({ space: 12 }) {
        Row() {
          Column() {
            Text(mobileText(this.language, '人设配置', 'Persona setup', 'Настройка персоны', '페르소나 설정', '人設設定', '人設設定'))
              .fontSize(AppTypography.titleLarge.fontSize)
              .fontWeight(AppTypography.titleLarge.fontWeight)
              .fontColor(AppTheme.colors.onBackground)
            Text(`${this.userPersonaCount()} / ${PERSONA_MAX_COUNT}`)
              .fontSize(AppTypography.bodySmall.fontSize)
              .fontColor(AppTheme.colors.onSurfaceVariant)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button('+')
            .fontSize(22)
            .fontColor(AppTheme.colors.onPrimary)
            .width(48)
            .height(48)
            .borderRadius(AppShapes.button)
            .backgroundColor(AppTheme.colors.primary)
            .enabled(this.userPersonaCount() < PERSONA_MAX_COUNT)
            .opacity(this.userPersonaCount() < PERSONA_MAX_COUNT ? 1 : 0.5)
            .onClick(() => {
              this.showCreateDialog = true
            })
        }
        .width('100%')

        if (this.uiState.isPersonasLoading) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(AppTheme.colors.primary)
            .alignSelf(ItemAlign.Center)
        }

        List({ space: 8 }) {
          if (this.uiState.personas.length === 0 && !this.uiState.isPersonasLoading) {
            ListItem() {
              this.EmptyCard({
                title: mobileText(this.language, '暂无人设', 'No personas yet', 'Персон пока нет', '페르소나 없음', '暫無人設', '暫無人設'),
                subtitle: mobileText(this.language,
                  '创建不同场景的语音输入和指令处理提示词，启用后会影响输入法输出效果。',
                  'Create prompts for voice input and command output.',
                  'Создайте подсказки для голосового ввода и команд.',
                  '음성 입력과 명령 결과용 프롬프트를 만들 수 있습니다.',
                  '建立不同場景的語音輸入和指令處理提示詞，啟用後會影響輸入法輸出效果。',
                  '建立唔同場景嘅語音輸入同指令處理提示詞，啟用後會影響輸入法輸出效果。')
              })
            }
          }
          ForEach(this.uiState.personas, (persona: PersonaItem) => {
            ListItem() {
              PersonaCard({
                language: this.language,
                persona: persona,
                onOpen: (): void => {
                  if (!persona.is_builtin) {
                    this.editingPersonaId = persona.id
                  }
                },
                onActivate: (): void => {
                  this.viewModel?.activatePersona(persona.id)
                },
                onDeactivate: (): void => {
                  this.viewModel?.deactivatePersonas()
                },
                onDelete: (): void => {
                  this.viewModel?.deletePersona(persona.id)
                }
              })
            }
          }, (persona: PersonaItem): string => `${this.language}|${JSON.stringify(persona)}`)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
  }

  // ==================== 设置(对应 AccountScreen) ====================

  @Builder
  AccountContent() {
    Scroll() {
      Column({ space: 12 }) {
        // 账户 Profile Hero(对应 ProfileHeroCard)
        Column({ space: 16 }) {
          Row() {
            Text('👤')
              .fontSize(24)
              .width(48)
              .height(48)
              .textAlign(TextAlign.Center)
              .backgroundColor('#38FFFFFF')
              .borderRadius(24)
            Blank().width(14)
            Column() {
              Text(this.email.length > 0 ? this.email
                : mobileText(this.language, '未登录', 'Not signed in', 'Не выполнен вход', '로그인 안 됨'))
                .fontSize(AppTypography.titleMedium.fontSize)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
              Text(this.uiState.plan !== null ? this.uiState.plan.tier
                : mobileText(this.language, '加载中', 'Loading', 'Загрузка', '로딩 중'))
                .fontSize(AppTypography.bodySmall.fontSize)
                .fontColor('#E6FFFFFF')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Row() {
            Text(mobileText(this.language, '剩余积分', 'Credits left', 'Осталось кредитов', '남은 크레딧'))
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor('#EBFFFFFF')
            Blank().layoutWeight(1)
            Text(this.uiState.plan !== null ? this.planCreditsLine() : '—')
              .fontSize(AppTypography.titleMedium.fontSize)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .backgroundColor('#29FFFFFF')
          .borderRadius(12)
        }
        .width('100%')
        .padding(20)
        .borderRadius(AppShapes.card)
        .linearGradient({
          angle: 135,
          colors: [[AppBrand.gradientStart, 0], [AppBrand.gradientEnd, 1]]
        })
        .alignItems(HorizontalAlign.Start)

        this.SectionHeader({ text: mobileText(this.language, '账户', 'Account', 'Аккаунт', '계정') })

        Column() {
          this.SettingRow({
            icon: '👑',
            title: mobileText(this.language, '订阅与套餐', 'Subscription', 'Подписка', '구독'),
            subtitle: this.uiState.plan !== null ? this.uiState.plan.tier
              : mobileText(this.language, '查看套餐与积分加购', 'View plans and top-up', 'Тарифы и пополнение', '요금제 및 충전 보기'),
            enabled: true,
            action: (): void => {
              this.subPage = 'subscription'
              this.viewModel?.loadPaymentCatalog()
            }
          })
          if (this.uiState.plan !== null && this.uiState.plan.show_invite_codes_enabled) {
            this.RowDivider()
            this.SettingRow({
              icon: '🎁',
              title: mobileText(this.language, '我的邀请码', 'Invite codes', 'Коды приглашения', '초대 코드'),
              subtitle: mobileText(this.language, '邀请好友领取奖励', 'Invite friends for rewards', 'Приглашайте друзей', '친구 초대 보상'),
              enabled: true,
              action: (): void => {
                this.subPage = 'invite'
                this.viewModel?.loadInviteCodes()
              }
            })
          }
        }
        .width('100%')
        .borderRadius(AppShapes.card)
        .backgroundColor(AppTheme.colors.surface)
        .shadow({ radius: 4, color: '#14000000', offsetY: 1 })

        this.SectionHeader({ text: mobileText(this.language, '输入法设置', 'Keyboard', 'Клавиатура', '키보드') })

        this.KeyboardSetupCard()

        this.SectionHeader({ text: mobileText(this.language, '偏好', 'Preferences', 'Предпочтения', '환경설정') })

        Column() {
          // 语言选择(对应 DropdownMenu)
          Row() {
            Text('🌐')
              .fontSize(18)
              .width(36)
              .height(36)
              .textAlign(TextAlign.Center)
              .backgroundColor(AppTheme.colors.primaryContainer)
              .borderRadius(10)
            Blank().width(14)
            Column() {
              Text(mobileText(this.language, '语言', 'Language', 'Язык', '언어'))
                .fontSize(AppTypography.bodyLarge.fontSize)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppTheme.colors.onSurface)
              Text(mobileLanguageLabel(this.language))
                .fontSize(AppTypography.bodySmall.fontSize)
                .fontColor(AppTheme.colors.onSurfaceVariant)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Blank().width(12)
            Select(this.languageSelectOptions())
              .selected(this.currentLanguageIndex())
              .value('▾')
              .font({ size: 16 })
              .fontColor(AppTheme.colors.onSurfaceVariant)
              .backgroundColor(Color.Transparent)
              .onSelect((index: number) => {
                this.onLanguageChange(ALL_LANGUAGES[index])
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })

          this.RowDivider()
          this.SettingSwitchRow({
            icon: '📶',
            title: mobileText(this.language, '流式实时识别', 'Streaming recognition', 'Потоковое распознавание', '실시간 스트리밍 인식'),
            subtitle: mobileText(this.language,
              '开启后输入法麦克风改为长按实时识别；关闭后点击开始、再次点击结束。',
              'Hold the mic for realtime recognition; off means tap to start and tap to finish.',
              'Удерживайте микрофон для распознавания; иначе нажмите для начала и завершения.',
              '켜면 마이크를 길게 눌러 실시간 인식, 끄면 탭으로 시작·종료합니다.'),
            checked: this.realtimeRecognitionEnabled,
            onChange: (on: boolean): void => {
              this.realtimeRecognitionEnabled = on
              this.prefs?.putBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, on)
            }
          })
          this.RowDivider()
          this.SettingRow({
            icon: '📚',
            title: mobileText(this.language, '热词词典', 'Hot words', 'Словарь', '단어 사전'),
            subtitle: mobileText(this.language, '添加专属词汇，提升识别准确度',
              'Add custom words to improve accuracy', 'Добавьте слова для точности', '정확도 향상을 위한 단어 추가'),
            enabled: true,
            action: (): void => {
              this.subPage = 'dictionary'
              this.viewModel?.loadHotWords()
            }
          })
        }
        .width('100%')
        .borderRadius(AppShapes.card)
        .backgroundColor(AppTheme.colors.surface)
        .shadow({ radius: 4, color: '#14000000', offsetY: 1 })

        this.SectionHeader({ text: mobileText(this.language, '拼音键盘', 'Pinyin keyboard', 'Клавиатура пиньинь', '병음 키보드') })

        Column() {
          this.SettingSwitchRow({
            icon: '🎛',
            title: mobileText(this.language, '模糊音', 'Fuzzy pinyin', 'Нечёткий пиньинь', '퍼지 병음'),
            subtitle: mobileText(this.language,
              '平翘舌(z/zh)、前后鼻音(an/ang)、l/n 不分时开启;发音标准建议保持关闭',
              'For accents that merge z/zh, an/ang, l/n. Keep off if you type accurately.',
              'Для акцентов z/zh, an/ang, l/n.', 'z/zh, an/ang, l/n 구분 안 될 때'),
            checked: this.fuzzyEnabled,
            onChange: (on: boolean): void => {
              this.fuzzyEnabled = on
              this.applyFuzzySetting(on)
            }
          })
          this.RowDivider()
          this.SettingSwitchRow({
            icon: '📝',
            title: mobileText(this.language, '拼音纠错', 'Typo correction', 'Исправление опечаток', '오타 교정'),
            subtitle: mobileText(this.language, '拼错字母时智能纠正(建议保持开启)',
              'Auto-fix typos (recommended on)', 'Автоисправление опечаток', '오타 자동 교정'),
            checked: this.pinyinCorrectionEnabled,
            onChange: (on: boolean): void => {
              this.pinyinCorrectionEnabled = on
              this.prefs?.putBoolean(TypingPreferences.KEY_CORRECTION, on)
            }
          })
        }
        .width('100%')
        .borderRadius(AppShapes.card)
        .backgroundColor(AppTheme.colors.surface)
        .shadow({ radius: 4, color: '#14000000', offsetY: 1 })

        this.SectionHeader({ text: mobileText(this.language, '关于', 'About', 'О приложении', '정보') })

        Column() {
          this.SettingRow({
            icon: '🔄',
            title: mobileText(this.language, '检查更新', 'Check for updates', 'Проверить обновления', '업데이트 확인'),
            subtitle: mobileText(this.language,
              `当前版本 ${this.installedVersionName} (${this.installedVersionCode})`,
              `Current ${this.installedVersionName} (${this.installedVersionCode})`,
              `Версия ${this.installedVersionName} (${this.installedVersionCode})`,
              `현재 ${this.installedVersionName} (${this.installedVersionCode})`),
            enabled: this.updateKind !== AccountUpdateKind.Checking,
            action: (): void => {
              this.checkUpdate()
            },
            badge: this.envBadgeText()
          })
        }
        .width('100%')
        .borderRadius(AppShapes.card)
        .backgroundColor(AppTheme.colors.surface)
        .shadow({ radius: 4, color: '#14000000', offsetY: 1 })

        // 退出登录
        Button(mobileText(this.language, '退出登录', 'Sign out', 'Выйти', '로그아웃'))
          .fontSize(AppTypography.bodyLarge.fontSize)
          .fontColor(AppTheme.colors.error)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: AppTheme.colors.errorAlpha50 })
          .borderRadius(AppShapes.button)
          .width('100%')
          .height(48)
          .onClick(() => {
            this.viewModel?.logout()
            this.onLogout()
          })

        Blank().height(8)
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  /** 系统输入法配置卡(对应 AccountScreen 键盘配置 ElevatedCard,安卓话术改为鸿蒙引导)。 */
  @Builder
  KeyboardSetupCard() {
    Column({ space: 10 }) {
      Text(mobileText(this.language, '系统输入法配置', 'Keyboard setup', 'Настройка клавиатуры', '키보드 설정'))
        .fontSize(AppTypography.titleMedium.fontSize)
        .fontWeight(AppTypography.titleMedium.fontWeight)
        .fontColor(AppTheme.colors.onSurface)

      this.InputStatusRow({
        label: mobileText(this.language, '当前输入法是龙虾输入法', 'Lobster is current keyboard', 'Lobster выбрана', '랍스터 입력기가 선택됨'),
        ok: this.imeCurrent
      })
      this.InputStatusRow({
        label: mobileText(this.language, '麦克风权限', 'Microphone permission', 'Доступ к микрофону', '마이크 권한'),
        ok: this.hasRecordAudioPermission
      })

      if (!(this.imeCurrent && this.hasRecordAudioPermission)) {
        Text(mobileText(this.language,
          '鸿蒙需要用户手动启用和切换输入法。完成后返回本页可继续操作。',
          'HarmonyOS requires manual keyboard setup and switching.',
          'HarmonyOS требует вручную включить и выбрать клавиатуру.',
          'HarmonyOS에서는 키보드를 직접 켜고 전환해야 합니다.'))
          .fontSize(AppTypography.bodySmall.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
        if (!this.imeCurrent) {
          this.SetupStep({
            index: 1,
            title: mobileText(this.language, '启用并切换输入法', 'Enable and switch keyboard', 'Включите и выберите', '키보드 켜고 전환'),
            desc: mobileText(this.language,
              '先在系统输入法设置里打开龙虾输入法，再从输入法选择器切换到龙虾输入法。',
              'Enable Lobster in system settings, then select it from the keyboard picker.',
              'Включите Lobster в настройках, затем выберите ее.',
              '시스템 설정에서 랍스터를 켠 뒤 입력기 선택에서 전환하세요.')
          })
        }
        if (!this.hasRecordAudioPermission) {
          this.SetupStep({
            index: 2,
            title: mobileText(this.language, '授予麦克风', 'Allow microphone', 'Разрешите микрофон', '마이크 허용'),
            desc: mobileText(this.language,
              '语音输入需要麦克风权限，否则无法录音。',
              'Voice input needs microphone permission.',
              'Голосовой ввод требует доступ к микрофону.',
              '음성 입력에는 마이크 권한이 필요합니다.')
          })
        }
      }

      Button() {
        Row() {
          Text('⚙️').fontSize(16)
          Blank().width(8)
          Text(mobileText(this.language, '打开输入法设置', 'Open keyboard settings', 'Открыть настройки', '입력기 설정 열기'))
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontColor(AppTheme.colors.onPrimary)
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(48)
      .borderRadius(AppShapes.button)
      .backgroundColor(AppTheme.colors.primary)
      .onClick(() => {
        this.openInputMethodSettings()
      })

      Button() {
        Row() {
          Text('⌨️').fontSize(16)
          Blank().width(8)
          Text(this.imeCurrent
            ? mobileText(this.language, '当前已是龙虾输入法', 'Lobster is current', 'Lobster выбрана', '랍스터가 선택됨')
            : mobileText(this.language, '切换当前输入法', 'Switch keyboard', 'Сменить клавиатуру', '입력기 전환'))
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontColor(AppTheme.colors.onSurface)
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(48)
      .borderRadius(AppShapes.button)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: AppTheme.colors.outline })
      .onClick(() => {
        this.showImePicker()
      })

      Button() {
        Row() {
          Text('🎤').fontSize(16)
          Blank().width(8)
          Text(this.hasRecordAudioPermission
            ? mobileText(this.language, '麦克风权限已允许', 'Microphone allowed', 'Микрофон разрешен', '마이크 허용됨')
            : mobileText(this.language, '申请麦克风权限', 'Request microphone', 'Запросить микрофон', '마이크 권한 요청'))
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontColor(AppTheme.colors.onSurface)
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height(48)
      .borderRadius(AppShapes.button)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: AppTheme.colors.outline })
      .enabled(!this.hasRecordAudioPermission)
      .opacity(this.hasRecordAudioPermission ? 0.5 : 1)
      .onClick(() => {
        this.requestMicPermission()
      })
    }
    .width('100%')
    .padding(18)
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
  }

  private languageSelectOptions(): SelectOption[] {
    const options: SelectOption[] = []
    for (let i = 0; i < ALL_LANGUAGES.length; i++) {
      options.push({ value: mobileLanguageLabel(ALL_LANGUAGES[i]) })
    }
    return options
  }

  private currentLanguageIndex(): number {
    for (let i = 0; i < ALL_LANGUAGES.length; i++) {
      if (ALL_LANGUAGES[i] === this.language) {
        return i
      }
    }
    return 0
  }

  /** 模糊音单个总开关写入全部 7 个键(与安卓一致)。 */
  private async applyFuzzySetting(on: boolean): Promise<void> {
    const prefs: AppPreferences | null = this.prefs
    if (prefs === null) {
      return
    }
    await prefs.putBoolean(TypingPreferences.KEY_FUZZY_ZZH, on)
    await prefs.putBoolean(TypingPreferences.KEY_FUZZY_CCH, on)
    await prefs.putBoolean(TypingPreferences.KEY_FUZZY_SSH, on)
    await prefs.putBoolean(TypingPreferences.KEY_FUZZY_ANANG, on)
    await prefs.putBoolean(TypingPreferences.KEY_FUZZY_ENENG, on)
    await prefs.putBoolean(TypingPreferences.KEY_FUZZY_INING, on)
    await prefs.putBoolean(TypingPreferences.KEY_FUZZY_LN, on)
  }

  // ==================== 订阅子页(对应 SubscriptionScreen + PaymentSubscriptionCard) ====================

  @Builder
  SubscriptionContent() {
    Scroll() {
      Column({ space: 12 }) {
        this.SubPageHeader({ text: mobileText(this.language, '订阅与套餐', 'Subscription', 'Подписка', '구독') })
        this.PaymentSubscriptionCard()
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  @Builder
  PaymentSubscriptionCard() {
    Column({ space: 12 }) {
      Row() {
        Column() {
          Text(mobileText(this.language, '订阅与充值', 'Subscription', 'Подписка', '구독'))
            .fontSize(AppTypography.titleMedium.fontSize)
            .fontWeight(AppTypography.titleMedium.fontWeight)
            .fontColor(AppTheme.colors.onSurface)
          Text(mobileText(this.language,
            '购买后会打开安全支付页面，支付完成后回到 App 刷新状态。',
            'A secure payment page opens in your browser. Return and refresh after payment.',
            'Откроется безопасная страница оплаты. После оплаты вернитесь и обновите.',
            '브라우저에서 안전한 결제 페이지가 열립니다. 결제 후 돌아와 새로고침하세요.'))
            .fontSize(AppTypography.bodySmall.fontSize)
            .fontColor(AppTheme.colors.onSurfaceVariant)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.uiState.isPaymentCatalogLoading) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color(AppTheme.colors.primary)
        } else {
          Text('↻')
            .fontSize(20)
            .fontColor(AppTheme.colors.primary)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.viewModel?.loadPaymentCatalog()
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 支付状态 chip
      if (this.uiState.paymentStatus !== null && this.uiState.paymentStatus.length > 0) {
        Text(this.uiState.paymentStatus)
          .fontSize(AppTypography.labelLarge.fontSize)
          .fontColor(AppTheme.colors.onSecondaryContainer)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(AppTheme.colors.secondaryContainer)
          .borderRadius(AppShapes.chip)
      }

      if (this.uiState.paymentCatalog === null && this.uiState.isPaymentCatalogLoading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(AppTheme.colors.primary)
          .alignSelf(ItemAlign.Center)
      } else if (this.uiState.paymentCatalog === null) {
        Text(mobileText(this.language, '订阅信息暂不可用', 'Subscription is unavailable',
          'Подписка недоступна', '구독 정보를 사용할 수 없습니다'))
          .fontSize(AppTypography.bodyMedium.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
        Button(mobileText(this.language, '重新加载', 'Reload', 'Загрузить снова', '다시 불러오기'))
          .fontSize(AppTypography.bodyLarge.fontSize)
          .fontColor(AppTheme.colors.primary)
          .backgroundColor(Color.Transparent)
          .border({ width: 1, color: AppTheme.colors.outline })
          .borderRadius(AppShapes.button)
          .width('100%')
          .height(48)
          .onClick(() => {
            this.viewModel?.loadPaymentCatalog()
          })
      } else if (!(this.uiState.paymentCatalog as PaymentCatalogResponse).subscription_module.enabled) {
        Text(mobileText(this.language, '订阅功能暂未开放', 'Subscription is not available',
          'Подписка пока недоступна', '구독 기능이 아직 열려 있지 않습니다'))
          .fontSize(AppTypography.bodyMedium.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
      } else {
        this.PaymentCurrentPlanSummary()
        if ((this.uiState.paymentCatalog as PaymentCatalogResponse).credits_topup.available) {
          this.PaymentTopupRow()
          Divider().color(AppTheme.colors.outline)
        }
        ForEach(this.sortedSubscriptions(), (sub: PaymentSubscriptionPlan) => {
          PaymentPlanRowView({
            language: this.language,
            plan: sub,
            options: this.sortedOptions(sub),
            selectedCycle: this.effectiveCycle(sub),
            checkoutInProgress: this.uiState.checkoutInProgress,
            isCurrent: this.isCurrentPlan(sub),
            isLowerTier: this.isLowerTier(sub),
            currentPlanPaid: this.currentPlanPaid(),
            onCycleChange: (cycle: string): void => {
              this.selectedCycles.set(sub.plan_code, cycle)
            },
            onSubscribe: (option: PaymentBillingOption): void => {
              this.viewModel?.createSubscriptionCheckout(sub, option)
            }
          })
        }, (sub: PaymentSubscriptionPlan): string => {
          const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
          const currentCode: string = catalog !== null ? catalog.current_plan.plan_code : ''
          const inProgress: string = this.uiState.checkoutInProgress !== null ? this.uiState.checkoutInProgress : ''
          const paid: string = catalog !== null && catalog.current_plan.paid ? '1' : '0'
          return `${this.language}|${sub.plan_code}|${this.effectiveCycle(sub)}|${inProgress}|${currentCode}|${paid}|${JSON.stringify(sub)}`
        })
      }
    }
    .width('100%')
    .padding(18)
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 当前套餐摘要(对应 PaymentCurrentPlanSummary)+ 自动续费管理三态。 */
  @Builder
  PaymentCurrentPlanSummary() {
    Column({ space: 8 }) {
      Row() {
        Column() {
          Text(mobileText(this.language, '当前套餐', 'Current plan', 'Текущий тариф', '현재 요금제'))
            .fontSize(AppTypography.labelMedium.fontSize)
            .fontColor(AppTheme.colors.onPrimaryContainer)
          Text(this.currentPlanDisplayName())
            .fontSize(AppTypography.titleMedium.fontSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppTheme.colors.onPrimaryContainer)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.currentPlanCreditsLine())
          .fontSize(AppTypography.titleMedium.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.colors.onPrimaryContainer)
      }
      .width('100%')

      // 自动续费三态:可取消 → 续费日期 + 取消入口;不可取消 → 商店管理提示;未开启 → 不展示
      if (this.uiState.plan !== null && (this.uiState.plan as UserPlanInfo).auto_renew) {
        if ((this.uiState.plan as UserPlanInfo).renewal_cancellable) {
          Row() {
            Text(mobileText(this.language,
              `将于 ${this.renewalDateText()} 自动续费`,
              `Renews automatically on ${this.renewalDateText()}`,
              `Автопродление ${this.renewalDateText()}`,
              `${this.renewalDateText()}에 자동 갱신됩니다`,
              `將於 ${this.renewalDateText()} 自動續費`,
              `將會喺 ${this.renewalDateText()} 自動續費`))
              .fontSize(AppTypography.bodySmall.fontSize)
              .fontColor(AppTheme.colors.onPrimaryContainer)
              .layoutWeight(1)

            if (this.uiState.cancelRenewalInProgress) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color(AppTheme.colors.onPrimaryContainer)
            } else {
              Text(mobileText(this.language, '取消自动续费', 'Cancel auto-renewal', 'Отменить автопродление',
                '자동 갱신 취소', '取消自動續費', '取消自動續費'))
                .fontSize(AppTypography.labelLarge.fontSize)
                .fontColor(AppTheme.colors.onPrimaryContainer)
                .decoration({ type: TextDecorationType.Underline, color: AppTheme.colors.onPrimaryContainer })
                .onClick(() => {
                  this.showCancelRenewalDialog = true
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else {
          Text(MobileStrings.mainRenewalStoreManaged())
            .fontSize(AppTypography.bodySmall.fontSize)
            .fontColor(AppTheme.colors.onPrimaryContainer)
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(AppTheme.colors.primaryContainer)
    .borderRadius(AppShapes.card)
    .alignItems(HorizontalAlign.Start)
  }

  /** 下次自动续费日期(优先 next_renewal_at,回退订阅/套餐到期时间)。 */
  private renewalDateText(): string {
    const plan: UserPlanInfo | null = this.uiState.plan
    if (plan === null) {
      return '-'
    }
    const formatted: string | null = formatServerDate(plan.next_renewal_at)
      ?? formatServerDate(plan.subscription_expires_at)
      ?? formatServerDate(plan.plan_expires_at)
    return formatted ?? '-'
  }

  /** 取消自动续费确认弹窗(遮罩样式对齐 UpdateDialog)。 */
  @Builder
  CancelRenewalDialog() {
    Column() {
      Column({ space: 10 }) {
        Text(mobileText(this.language, '取消自动续费', 'Cancel auto-renewal', 'Отменить автопродление',
          '자동 갱신 취소', '取消自動續費', '取消自動續費'))
          .fontSize(AppTypography.titleLarge.fontSize)
          .fontWeight(AppTypography.titleLarge.fontWeight)
          .fontColor(AppTheme.colors.onSurface)

        Text(mobileText(this.language,
          `取消后套餐仍可使用至 ${this.renewalDateText()}，到期后不再自动扣费。`,
          `You can keep using your plan until ${this.renewalDateText()}. No further charges after it expires.`,
          `Тариф действует до ${this.renewalDateText()}. После окончания списаний не будет.`,
          `${this.renewalDateText()}까지 요금제를 계속 사용할 수 있으며, 만료 후에는 자동 결제되지 않습니다.`,
          `取消後套餐仍可使用至 ${this.renewalDateText()}，到期後不再自動扣費。`,
          `取消咗之後套餐照用得到 ${this.renewalDateText()}，到期之後唔會再自動扣費。`))
          .fontSize(AppTypography.bodyMedium.fontSize)
          .fontColor(AppTheme.colors.onSurface)

        Row({ space: 8 }) {
          Blank().layoutWeight(1)
          Button(mobileText(this.language, '暂不', 'Not now', 'Не сейчас', '나중에', '暫不', '暫時唔取消'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.primary)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.showCancelRenewalDialog = false
            })
          Button(mobileText(this.language, '确认取消', 'Confirm', 'Подтвердить', '취소 확인', '確認取消', '確認取消'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onPrimary)
            .backgroundColor(AppTheme.colors.primary)
            .borderRadius(AppShapes.button)
            .onClick(() => {
              this.showCancelRenewalDialog = false
              this.viewModel?.cancelSubscriptionRenewal()
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(20)
      .borderRadius(AppShapes.dialog)
      .backgroundColor(AppTheme.colors.surface)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.showCancelRenewalDialog = false
    })
  }

  private currentPlanDisplayName(): string {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null) {
      return '-'
    }
    for (let i = 0; i < catalog.subscriptions.length; i++) {
      if (catalog.subscriptions[i].plan_code === catalog.current_plan.plan_code) {
        return catalog.subscriptions[i].name
      }
    }
    if ((catalog.current_plan.plan_name ?? '').trim().length > 0) {
      return catalog.current_plan.plan_name as string
    }
    return localizedPlanName(this.language, catalog.current_plan.plan_code)
  }

  private currentPlanCreditsLine(): string {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null) {
      return '-'
    }
    return `${catalog.current_plan.plan_credits_remaining} / ${catalog.current_plan.plan_credits_total}`
  }

  /** 积分加购行(对应 PaymentTopupRow)。 */
  @Builder
  PaymentTopupRow() {
    Row() {
      Column() {
        Text(mobileText(this.language, '积分加购', 'Credit top-up', 'Пополнение кредитов', '크레딧 충전'))
          .fontSize(AppTypography.titleSmall.fontSize)
          .fontWeight(AppTypography.titleSmall.fontWeight)
          .fontColor(AppTheme.colors.onSurface)
        Text(this.topupAmountText())
          .fontSize(AppTypography.bodySmall.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button() {
        if (this.uiState.checkoutInProgress === 'topup') {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(AppTheme.colors.onPrimary)
        } else {
          Text(this.topupPriceText())
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onPrimary)
        }
      }
      .height(40)
      .padding({ left: 16, right: 16 })
      .borderRadius(AppShapes.button)
      .backgroundColor(AppTheme.colors.primary)
      .enabled(this.uiState.checkoutInProgress === null)
      .opacity(this.uiState.checkoutInProgress === null ? 1 : 0.5)
      .onClick(() => {
        this.viewModel?.createCreditsTopupCheckout()
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  private topupAmountText(): string {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null) {
      return ''
    }
    const topup: PaymentCreditsTopup = catalog.credits_topup
    return topup.amount !== null && topup.amount !== undefined
      ? paymentCreditsText(this.language, topup.amount) : ''
  }

  private topupPriceText(): string {
    const catalog: PaymentCatalogResponse | null = this.uiState.paymentCatalog
    if (catalog === null) {
      return ''
    }
    const topup: PaymentCreditsTopup = catalog.credits_topup
    return topup.price_cents !== null && topup.price_cents !== undefined
      ? priceText(topup.price_cents, topup.currency)
      : mobileText(this.language, '购买', 'Buy', 'Купить', '구매')
  }

  // ==================== 邀请码子页(对应 InviteCodesScreen) ====================

  @Builder
  InviteContent() {
    Column({ space: 10 }) {
      this.SubPageHeader({ text: mobileText(this.language, '我的邀请码', 'Invite codes', 'Коды приглашения', '초대 코드') })

      if (this.uiState.isInviteCodesLoading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(AppTheme.colors.primary)
          .alignSelf(ItemAlign.Center)
      }
      if (this.uiState.inviteCodes.length === 0 && !this.uiState.isInviteCodesLoading) {
        this.EmptyCard({
          title: mobileText(this.language, '暂无邀请码', 'No invite codes', 'Нет кодов', '초대 코드 없음'),
          subtitle: mobileText(this.language, '邀请码会在这里显示，可复制分享给好友。',
            'Your invite codes appear here to share with friends.',
            'Здесь появятся коды приглашения для друзей.',
            '초대 코드가 여기에 표시되어 친구에게 공유할 수 있습니다.')
        })
      }

      List({ space: 10 }) {
        ForEach(this.uiState.inviteCodes, (code: InviteCodeItem) => {
          ListItem() {
            InviteCodeCard({
              language: this.language,
              item: code,
              onCopy: (text: string): void => {
                this.copyToClipboard(text)
              }
            })
          }
        }, (code: InviteCodeItem): string => `${this.language}|${code.code}|${code.is_used ? '1' : '0'}`)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  // ==================== 检查更新弹窗(对应 AndroidUpdateDialog,鸿蒙走应用市场) ====================

  private updateDialogTitle(): string {
    switch (this.updateKind) {
      case AccountUpdateKind.Checking:
        return mobileText(this.language, '正在检查更新', 'Checking for updates', 'Проверка обновлений', '업데이트 확인 중')
      case AccountUpdateKind.NoUpdate:
        return mobileText(this.language, '当前已是最新版本', "You're up to date", 'Установлена последняя версия', '최신 버전입니다')
      case AccountUpdateKind.Available:
        return mobileText(this.language, '发现新版本', 'Update available', 'Доступно обновление', '업데이트 가능')
      case AccountUpdateKind.Error:
        return mobileText(this.language, '更新失败', 'Update failed', 'Ошибка обновления', '업데이트 실패')
      default:
        return ''
    }
  }

  @Builder
  UpdateDialog() {
    Column() {
      Column({ space: 10 }) {
        Text(this.updateDialogTitle())
          .fontSize(AppTypography.titleLarge.fontSize)
          .fontWeight(AppTypography.titleLarge.fontWeight)
          .fontColor(AppTheme.colors.onSurface)

        if (this.updateKind === AccountUpdateKind.Checking) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(AppTheme.colors.primary)
            .alignSelf(ItemAlign.Center)
          Text(mobileText(this.language, '正在读取更新源。', 'Reading the update feed.',
            'Читаем источник обновлений.', '업데이트 정보를 읽는 중입니다.'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onSurface)
        } else if (this.updateKind === AccountUpdateKind.NoUpdate) {
          Text(mobileText(this.language,
            `当前版本 ${this.installedVersionName} (${this.installedVersionCode}) 无需更新。`,
            `Version ${this.installedVersionName} (${this.installedVersionCode}) is current.`,
            `Версия ${this.installedVersionName} (${this.installedVersionCode}) актуальна.`,
            `버전 ${this.installedVersionName} (${this.installedVersionCode})는 최신입니다.`))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onSurface)
        } else if (this.updateKind === AccountUpdateKind.Available) {
          Text(mobileText(this.language,
            `新版本 ${this.updateManifest !== null ? this.updateManifest.version_name : ''} (${this.updateManifest !== null ? this.updateManifest.version_code : 0}) 已发布，请前往应用市场更新。`,
            `Version ${this.updateManifest !== null ? this.updateManifest.version_name : ''} (${this.updateManifest !== null ? this.updateManifest.version_code : 0}) is available. Please update from AppGallery.`,
            `Версия ${this.updateManifest !== null ? this.updateManifest.version_name : ''} (${this.updateManifest !== null ? this.updateManifest.version_code : 0}) доступна. Обновитесь через AppGallery.`,
            `버전 ${this.updateManifest !== null ? this.updateManifest.version_name : ''} (${this.updateManifest !== null ? this.updateManifest.version_code : 0})가 출시되었습니다. AppGallery에서 업데이트하세요.`))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onSurface)
          if (this.updateManifest !== null && this.updateManifest.release_notes !== null &&
            this.updateManifest.release_notes.length > 0) {
            Text(this.updateManifest.release_notes)
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.onSurfaceVariant)
          }
        } else if (this.updateKind === AccountUpdateKind.Error) {
          Text(this.updateError)
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onSurface)
        }

        Row({ space: 8 }) {
          Blank().layoutWeight(1)
          if (this.updateKind !== AccountUpdateKind.Checking) {
            Button(mobileText(this.language, '取消', 'Cancel', 'Отмена', '취소'))
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.primary)
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.updateKind = AccountUpdateKind.None
              })
          }
          if (this.updateKind === AccountUpdateKind.Available) {
            Button(mobileText(this.language, '去应用市场', 'Open AppGallery', 'Открыть AppGallery', 'AppGallery 열기'))
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.onPrimary)
              .backgroundColor(AppTheme.colors.primary)
              .borderRadius(AppShapes.button)
              .onClick(() => {
                this.openAppGallery()
              })
          } else if (this.updateKind === AccountUpdateKind.NoUpdate || this.updateKind === AccountUpdateKind.Error) {
            Button(mobileText(this.language, '知道了', 'OK', 'ОК', '확인'))
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.primary)
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.updateKind = AccountUpdateKind.None
              })
          }
        }
        .width('100%')
      }
      .width('82%')
      .padding(20)
      .borderRadius(AppShapes.dialog)
      .backgroundColor(AppTheme.colors.surface)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      // 点击遮罩关闭(检查中不可关,与安卓 onDismissRequest 一致)
      if (this.updateKind !== AccountUpdateKind.Checking) {
        this.updateKind = AccountUpdateKind.None
      }
    })
  }
}

// ==================== 列表项子组件 ====================

/** 组件字段默认值:空历史记录(MobileHistoryRecord 为 interface,不能 new)。 */
function emptyHistoryRecord(): MobileHistoryRecord {
  const record: MobileHistoryRecord = {
    id: '',
    operation: '',
    transcript: null,
    result: null,
    actionType: null,
    selectedText: null,
    errorMessage: null,
    status: MobileHistoryStatus.SUCCESS,
    createdAt: 0
  }
  return record
}

/** 组件字段默认值:空人设(PersonaItem 为 interface,不能 new)。 */
function emptyPersonaItem(): PersonaItem {
  const item: PersonaItem = {
    id: '',
    name: '',
    description: null,
    is_active: false,
    is_builtin: false,
    prompts: emptyPersonaPrompts()
  }
  return item
}

/** 历史记录卡片(对应 HistoryRecordCard)。 */
@Component
struct HistoryRecordCard {
  language: MobileLanguage = MobileLanguage.ZH
  record: MobileHistoryRecord = emptyHistoryRecord()
  onCopy: (text: string) => void = () => {}
  onDelete: () => void = () => {}

  private output(): string {
    const result: string | null = this.record.result
    if (result !== null && result !== undefined && result.trim().length > 0) {
      return result
    }
    const transcript: string | null = this.record.transcript
    return transcript !== null && transcript !== undefined ? transcript : ''
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.record.status === MobileHistoryStatus.SUCCESS ? '✓' : '✕')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.record.status === MobileHistoryStatus.SUCCESS
            ? AppTheme.colors.primary : AppTheme.colors.error)
          .width(20)
          .textAlign(TextAlign.Center)
        Blank().width(8)
        Text(operationText(this.language, this.record.operation))
          .fontSize(AppTypography.labelMedium.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .backgroundColor(AppTheme.colors.surfaceVariant)
          .borderRadius(AppShapes.chip)
        Blank().layoutWeight(1)
        Text(formatDateTime(this.record.createdAt))
          .fontSize(AppTypography.bodySmall.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.record.selectedText !== null && this.record.selectedText !== undefined &&
        this.record.selectedText.trim().length > 0) {
        Text(`${mobileText(this.language, '原文', 'Original', 'Оригинал', '원문')}：${this.record.selectedText}`)
          .fontSize(AppTypography.bodySmall.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
      }

      if (this.output().trim().length > 0) {
        Text(this.output())
          .fontSize(AppTypography.bodyMedium.fontSize)
          .fontColor(AppTheme.colors.onSurface)
      }

      if (this.record.errorMessage !== null && this.record.errorMessage !== undefined &&
        this.record.errorMessage.trim().length > 0) {
        Text(this.record.errorMessage)
          .fontSize(AppTypography.bodyMedium.fontSize)
          .fontColor(AppTheme.colors.error)
      }

      Row({ space: 8 }) {
        Button(mobileText(this.language, '复制', 'Copy', 'Копировать', '복사'))
          .fontSize(AppTypography.bodyMedium.fontSize)
          .fontColor(AppTheme.colors.primary)
          .backgroundColor(Color.Transparent)
          .enabled(this.output().trim().length > 0)
          .opacity(this.output().trim().length > 0 ? 1 : 0.4)
          .onClick(() => {
            this.onCopy(this.output())
          })
        Button(mobileText(this.language, '删除', 'Delete', 'Удалить', '삭제'))
          .fontSize(AppTypography.bodyMedium.fontSize)
          .fontColor(AppTheme.colors.primary)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.onDelete()
          })
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
  }
}

/** 热词行(对应 HotWordRow):编辑态文本保存在本组件内,行进入编辑态时重建初始化。 */
@Component
struct HotWordRow {
  language: MobileLanguage = MobileLanguage.ZH
  item: HotWordItem = { id: '', word: '', created_at: null }
  isEditing: boolean = false
  onStartEdit: () => void = () => {}
  onSave: (word: string) => void = () => {}
  onCancel: () => void = () => {}
  onDelete: () => void = () => {}

  @State editWord: string = ''

  aboutToAppear(): void {
    this.editWord = this.item.word
  }

  build() {
    Column() {
      if (this.isEditing) {
        Column({ space: 8 }) {
          TextInput({ text: this.editWord })
            .height(48)
            .width('100%')
            .borderRadius(AppShapes.field)
            .backgroundColor(AppTheme.colors.surfaceVariant)
            .fontColor(AppTheme.colors.onSurface)
            .onChange((value: string) => {
              this.editWord = value
            })
          Row({ space: 8 }) {
            Button(mobileText(this.language, '保存', 'Save', 'Сохранить', '저장'))
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.onPrimary)
              .backgroundColor(AppTheme.colors.primary)
              .borderRadius(AppShapes.button)
              .height(40)
              .enabled(this.editWord.trim().length > 0)
              .opacity(this.editWord.trim().length > 0 ? 1 : 0.5)
              .onClick(() => {
                this.onSave(this.editWord)
              })
            Button(mobileText(this.language, '取消', 'Cancel', 'Отмена', '취소'))
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.primary)
              .backgroundColor(Color.Transparent)
              .height(40)
              .onClick(() => {
                this.onCancel()
              })
          }
        }
        .width('100%')
        .padding(12)
        .alignItems(HorizontalAlign.Start)
      } else {
        Row() {
          Text(this.item.word)
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontColor(AppTheme.colors.onSurface)
            .layoutWeight(1)
          Button(mobileText(this.language, '编辑', 'Edit', 'Править', '편집'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.primary)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.onStartEdit()
            })
          Text('🗑')
            .fontSize(16)
            .fontColor(AppTheme.colors.error)
            .width(36)
            .height(36)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.onDelete()
            })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 6, bottom: 6 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
  }
}

/** 人设卡片(对应 PersonaCard)。 */
@Component
struct PersonaCard {
  language: MobileLanguage = MobileLanguage.ZH
  persona: PersonaItem = emptyPersonaItem()
  onOpen: () => void = () => {}
  onActivate: () => void = () => {}
  onDeactivate: () => void = () => {}
  onDelete: () => void = () => {}

  build() {
    Column({ space: 8 }) {
      Row() {
        Column() {
          Text(this.persona.name)
            .fontSize(AppTypography.titleMedium.fontSize)
            .fontWeight(AppTypography.titleMedium.fontWeight)
            .fontColor(AppTheme.colors.onSurface)
          if (this.persona.description !== null && this.persona.description !== undefined &&
            this.persona.description.trim().length > 0) {
            Text(this.persona.description)
              .fontSize(AppTypography.bodySmall.fontSize)
              .fontColor(AppTheme.colors.onSurfaceVariant)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.persona.is_active) {
          Row() {
            Text('✓')
              .fontSize(13)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.colors.primary)
            Blank().width(4)
            Text(mobileText(this.language, '使用中', 'Active', 'Активна', '사용 중', '使用中', '使用中'))
              .fontSize(AppTypography.labelMedium.fontSize)
              .fontColor(AppTheme.colors.onPrimaryContainer)
          }
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(AppTheme.colors.primaryContainer)
          .borderRadius(AppShapes.chip)
        }
      }
      .width('100%')

      if (!this.persona.is_builtin) {
        Text(`${mobileText(this.language, '语音输入', 'Voice input', 'Голосовой ввод', '음성 입력', '語音輸入', '語音輸入')}:${enabledText(this.language, this.persona.prompts.transcribe_enabled)}  ${mobileText(this.language, '指令', 'Command', 'Команда', '명령', '指令', '指令')}:${enabledText(this.language, this.persona.prompts.rewrite_enabled)}`)
          .fontSize(AppTypography.bodySmall.fontSize)
          .fontColor(AppTheme.colors.onSurfaceVariant)
      }

      Row({ space: 8 }) {
        if (this.persona.is_active) {
          Button(mobileText(this.language, '停用', 'Disable', 'Выключить', '끄기', '停用', '停用'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onSecondaryContainer)
            .backgroundColor(AppTheme.colors.secondaryContainer)
            .borderRadius(AppShapes.button)
            .height(38)
            .onClick(() => {
              this.onDeactivate()
            })
        } else {
          Button(mobileText(this.language, '启用', 'Enable', 'Включить', '켜기', '啟用', '啟用'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onPrimary)
            .backgroundColor(AppTheme.colors.primary)
            .borderRadius(AppShapes.button)
            .height(38)
            .onClick(() => {
              this.onActivate()
            })
        }
        if (!this.persona.is_builtin) {
          Button(mobileText(this.language, '编辑', 'Edit', 'Править', '편집', '編輯', '編輯'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onSurface)
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: AppTheme.colors.outline })
            .borderRadius(AppShapes.button)
            .height(38)
            .onClick(() => {
              this.onOpen()
            })
          Button(mobileText(this.language, '删除', 'Delete', 'Удалить', '삭제', '刪除', '刪除'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.error)
            .backgroundColor(Color.Transparent)
            .height(38)
            .onClick(() => {
              this.onDelete()
            })
        }
      }
    }
    .width('100%')
    .padding(16)
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      if (!this.persona.is_builtin) {
        this.onOpen()
      }
    })
  }
}

/** 邀请码卡片(对应 InviteCodesScreen 列表项)。 */
@Component
struct InviteCodeCard {
  language: MobileLanguage = MobileLanguage.ZH
  item: InviteCodeItem = { code: '', is_used: false, used_by: null, used_at: null }
  onCopy: (text: string) => void = () => {}

  build() {
    Row() {
      Column() {
        Text(this.item.code)
          .fontSize(AppTypography.titleMedium.fontSize)
          .fontWeight(AppTypography.titleMedium.fontWeight)
          .fontColor(AppTheme.colors.onSurface)
        Text(this.item.is_used
          ? mobileText(this.language, '已使用', 'Used', 'Использован', '사용됨')
          : mobileText(this.language, '未使用', 'Unused', 'Не использован', '미사용'))
          .fontSize(AppTypography.bodySmall.fontSize)
          .fontColor(this.item.is_used ? AppTheme.colors.onSurfaceVariant : AppTheme.colors.primary)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button(mobileText(this.language, '复制', 'Copy', 'Копировать', '복사'))
        .fontSize(AppTypography.bodyMedium.fontSize)
        .fontColor(AppTheme.colors.primary)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.onCopy(this.item.code)
        })
    }
    .width('100%')
    .padding({ left: 16, right: 8, top: 6, bottom: 6 })
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
    .alignItems(VerticalAlign.Center)
  }
}

/** 订阅套餐行(对应 PaymentPlanRow)。 */
@Component
struct PaymentPlanRowView {
  language: MobileLanguage = MobileLanguage.ZH
  plan: PaymentSubscriptionPlan = {
    type: 'subscription',
    plan_code: '',
    name: '',
    credits: 0,
    rank: 0,
    billing_options: []
  }
  options: PaymentBillingOption[] = []
  selectedCycle: string = ''
  checkoutInProgress: string | null = null
  isCurrent: boolean = false
  isLowerTier: boolean = false
  currentPlanPaid: boolean = false
  onCycleChange: (cycle: string) => void = () => {}
  onSubscribe: (option: PaymentBillingOption) => void = () => {}

  private selectedOption(): PaymentBillingOption | null {
    for (let i = 0; i < this.options.length; i++) {
      if (this.options[i].cycle === this.selectedCycle) {
        return this.options[i]
      }
    }
    return this.options.length > 0 ? this.options[0] : null
  }

  private loadingKey(): string {
    const option: PaymentBillingOption | null = this.selectedOption()
    return option !== null ? `${this.plan.plan_code}:${option.cycle}` : ''
  }

  /**
   * 选项级状态判定(2026-07 补差价升级规则):
   * 未付费全可购;服务端下发 purchasable 时以服务端为准
   * (可购且[补差价升级或当前套餐]→ 升级,否则正常订阅;
   *  不可购且 duplicate_purchase → 当前套餐,其余 → 暂不支持降级);
   * 旧后端(purchasable 为 undefined)沿用套餐级判定。
   */
  private optionState(option: PaymentBillingOption): PlanOptionState {
    if (!this.currentPlanPaid) {
      return PlanOptionState.SUBSCRIBE
    }
    if (option.purchasable !== undefined) {
      if (option.purchasable) {
        return isUpgradeOption(option) || this.isCurrent ? PlanOptionState.UPGRADE : PlanOptionState.SUBSCRIBE
      }
      return option.blocked_reason === 'duplicate_purchase' ? PlanOptionState.CURRENT : PlanOptionState.DOWNGRADE
    }
    if (this.isCurrent) {
      return PlanOptionState.CURRENT
    }
    if (this.isLowerTier) {
      return PlanOptionState.DOWNGRADE
    }
    return PlanOptionState.SUBSCRIBE
  }

  private selectedOptionState(): PlanOptionState {
    const option: PaymentBillingOption | null = this.selectedOption()
    return option !== null ? this.optionState(option) : PlanOptionState.SUBSCRIBE
  }

  private canSubscribe(): boolean {
    if (this.selectedOption() === null || this.checkoutInProgress !== null) {
      return false
    }
    const state: PlanOptionState = this.selectedOptionState()
    return state === PlanOptionState.SUBSCRIBE || state === PlanOptionState.UPGRADE
  }

  /** 整卡置灰仅当所有选项均不可购。 */
  private allOptionsBlocked(): boolean {
    if (this.options.length === 0) {
      return false
    }
    for (let i = 0; i < this.options.length; i++) {
      const state: PlanOptionState = this.optionState(this.options[i])
      if (state === PlanOptionState.SUBSCRIBE || state === PlanOptionState.UPGRADE) {
        return false
      }
    }
    return true
  }

  /** 选中项为补差价升级时,价格旁展示"已抵扣未使用部分"小字。 */
  private showUpgradeCreditNote(): boolean {
    const option: PaymentBillingOption | null = this.selectedOption()
    return option !== null && isUpgradeOption(option)
  }

  private planDisplayName(): string {
    return this.plan.name.trim().length > 0 ? this.plan.name : localizedPlanName(this.language, this.plan.plan_code)
  }

  private subscribeButtonText(): string {
    switch (this.selectedOptionState()) {
      case PlanOptionState.UPGRADE:
        return mobileText(this.language, '升级', 'Upgrade', 'Обновить',
          '업그레이드', '升級', '升級')
      case PlanOptionState.CURRENT:
        return mobileText(this.language, '当前套餐', 'Current plan', 'Текущий тариф', '현재 요금제', '當前套餐', '當前套餐')
      case PlanOptionState.DOWNGRADE:
        return mobileText(this.language, '暂不支持降级', 'Downgrade unavailable', 'Понижение недоступно',
          '다운그레이드 불가', '暫不支持降級', '暫不支持降級')
      default:
        return mobileText(this.language, '订阅', 'Subscribe', 'Подписаться', '구독')
    }
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Column() {
          Text(this.planDisplayName())
            .fontSize(AppTypography.titleMedium.fontSize)
            .fontWeight(AppTypography.titleMedium.fontWeight)
            .fontColor(AppTheme.colors.onSurface)
          Text(paymentCreditsText(this.language, this.plan.credits))
            .fontSize(AppTypography.bodySmall.fontSize)
            .fontColor(AppTheme.colors.onSurfaceVariant)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.selectedOption() !== null) {
          Column() {
            Text(priceText(payableCents(this.selectedOption() as PaymentBillingOption),
              (this.selectedOption() as PaymentBillingOption).currency))
              .fontSize(AppTypography.titleMedium.fontSize)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.colors.primary)
            Text(billingCycleTitle(this.language, (this.selectedOption() as PaymentBillingOption).cycle))
              .fontSize(AppTypography.bodySmall.fontSize)
              .fontColor(AppTheme.colors.onSurfaceVariant)
            if (this.showUpgradeCreditNote()) {
              Text(mobileText(this.language, '已抵扣未使用部分', 'Unused portion credited',
                'Зачтён неиспользованный остаток', '미사용분 차감 적용', '已抵扣未使用部分', '已抵扣未使用部分'))
                .fontSize(AppTypography.labelSmall.fontSize)
                .fontColor(AppTheme.colors.onSurfaceVariant)
            }
          }
          .alignItems(HorizontalAlign.End)
        }
      }
      .width('100%')

      if (this.options.length > 1) {
        Row({ space: 8 }) {
          ForEach(this.options, (option: PaymentBillingOption) => {
            Text(billingCycleTitle(this.language, option.cycle))
              .fontSize(AppTypography.labelLarge.fontSize)
              .fontColor(option.cycle === this.selectedCycle
                ? AppTheme.colors.onPrimaryContainer : AppTheme.colors.onSurfaceVariant)
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .backgroundColor(option.cycle === this.selectedCycle
                ? AppTheme.colors.primaryContainer : Color.Transparent)
              .border({
                width: 1,
                color: option.cycle === this.selectedCycle ? Color.Transparent : AppTheme.colors.outline
              })
              .borderRadius(AppShapes.chip)
              .onClick(() => {
                if (this.checkoutInProgress === null) {
                  this.onCycleChange(option.cycle)
                }
              })
          }, (option: PaymentBillingOption): string => `${this.plan.plan_code}|${option.cycle}|${this.selectedCycle}`)
        }
        .width('100%')
      }

      Button() {
        if (this.checkoutInProgress !== null && this.checkoutInProgress === this.loadingKey()) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(AppTheme.colors.onPrimary)
        } else {
          Text(this.subscribeButtonText())
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontColor(AppTheme.colors.onPrimary)
        }
      }
      .width('100%')
      .height(48)
      .borderRadius(AppShapes.button)
      .backgroundColor(AppTheme.colors.primary)
      .enabled(this.canSubscribe())
      .opacity(this.canSubscribe() ? 1 : 0.5)
      .onClick(() => {
        const option: PaymentBillingOption | null = this.selectedOption()
        if (option !== null) {
          this.onSubscribe(option)
        }
      })

      Divider().color(AppTheme.colors.outline)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 整卡置灰仅当所有账期选项均不可购(存在任一可购/可升级选项时保持正常)。
    .opacity(this.allOptionsBlocked() ? 0.6 : 1)
  }
}

/** 人设编辑页(对应 PersonaEditScreen):内部持有编辑态,进入时按 persona 初始化。 */
@Component
struct PersonaEditView {
  language: MobileLanguage = MobileLanguage.ZH
  persona: PersonaItem = emptyPersonaItem()
  @Prop isLoading: boolean = false
  onBack: () => void = () => {}
  onSave: (name: string, desc: string, prompts: PersonaPrompts) => void = () => {}

  @State name: string = ''
  @State desc: string = ''
  @State voicePrompt: string = ''
  @State commandPrompt: string = ''
  @State voiceEnabled: boolean = false
  @State commandEnabled: boolean = false

  aboutToAppear(): void {
    this.name = this.persona.name
    this.desc = this.persona.description !== null && this.persona.description !== undefined
      ? this.persona.description : ''
    this.voicePrompt = this.persona.prompts.transcribe_prompt !== null &&
      this.persona.prompts.transcribe_prompt !== undefined ? this.persona.prompts.transcribe_prompt : ''
    this.commandPrompt = this.persona.prompts.rewrite_prompt !== null &&
      this.persona.prompts.rewrite_prompt !== undefined ? this.persona.prompts.rewrite_prompt : ''
    this.voiceEnabled = this.persona.prompts.transcribe_enabled
    this.commandEnabled = this.persona.prompts.rewrite_enabled
  }

  private buildPrompts(): PersonaPrompts {
    const prompts: PersonaPrompts = {
      transcribe_prompt: this.voicePrompt.trim().length === 0 ? null : this.voicePrompt,
      transcribe_enabled: this.voiceEnabled && this.voicePrompt.trim().length > 0,
      rewrite_prompt: this.commandPrompt.trim().length === 0 ? null : this.commandPrompt,
      rewrite_enabled: this.commandEnabled && this.commandPrompt.trim().length > 0,
      intent_hint: this.persona.prompts.intent_hint,
      intent_enabled: this.persona.prompts.intent_enabled
    }
    return prompts
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Text('‹')
            .fontSize(28)
            .fontColor(AppTheme.colors.onBackground)
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.onBack()
            })
          Column() {
            Text(mobileText(this.language, '编辑人设', 'Edit persona', 'Правка персоны', '페르소나 편집'))
              .fontSize(AppTypography.titleLarge.fontSize)
              .fontWeight(AppTypography.titleLarge.fontWeight)
              .fontColor(AppTheme.colors.onBackground)
            Text(mobileText(this.language, '仅管理本输入法使用的语音输入和指令提示词。',
              'Only this keyboard\'s voice input and command prompts are edited here.',
              'Здесь меняются только подсказки этой клавиатуры для ввода и команд.',
              '이 키보드의 음성 입력과 명령 프롬프트만 수정합니다.'))
              .fontSize(AppTypography.bodySmall.fontSize)
              .fontColor(AppTheme.colors.onSurfaceVariant)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.isLoading) {
          LoadingProgress()
            .width(28)
            .height(28)
            .color(AppTheme.colors.primary)
            .alignSelf(ItemAlign.Center)
        }

        TextInput({
          placeholder: mobileText(this.language, '名称', 'Name', 'Имя', '이름'),
          text: this.name
        })
          .height(52)
          .width('100%')
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.surface)
          .fontColor(AppTheme.colors.onSurface)
          .placeholderColor(AppTheme.colors.onSurfaceVariant)
          .maxLength(PERSONA_NAME_MAX_LENGTH)
          .onChange((value: string) => {
            this.name = value.slice(0, PERSONA_NAME_MAX_LENGTH)
          })

        TextArea({
          placeholder: mobileText(this.language, '描述', 'Description', 'Описание', '설명'),
          text: this.desc
        })
          .height(76)
          .width('100%')
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.surface)
          .fontColor(AppTheme.colors.onSurface)
          .placeholderColor(AppTheme.colors.onSurfaceVariant)
          .maxLength(PERSONA_DESC_MAX_LENGTH)
          .onChange((value: string) => {
            this.desc = value.slice(0, PERSONA_DESC_MAX_LENGTH)
          })

        PersonaPromptEditor({
          language: this.language,
          title: mobileText(this.language, '语音输入提示词', 'Voice input prompt', 'Промпт голосового ввода', '음성 입력 프롬프트'),
          checked: this.voiceEnabled,
          prompt: this.voicePrompt
        })

        PersonaPromptEditor({
          language: this.language,
          title: mobileText(this.language, '指令提示词', 'Command prompt', 'Промпт команды', '명령 프롬프트'),
          checked: this.commandEnabled,
          prompt: this.commandPrompt
        })

        Row({ space: 12 }) {
          Button(mobileText(this.language, '取消', 'Cancel', 'Отмена', '취소'))
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontColor(AppTheme.colors.onSurface)
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: AppTheme.colors.outline })
            .borderRadius(AppShapes.button)
            .layoutWeight(1)
            .height(48)
            .onClick(() => {
              this.onBack()
            })
          Button(mobileText(this.language, '保存', 'Save', 'Сохранить', '저장'))
            .fontSize(AppTypography.bodyLarge.fontSize)
            .fontColor(AppTheme.colors.onPrimary)
            .backgroundColor(AppTheme.colors.primary)
            .borderRadius(AppShapes.button)
            .layoutWeight(1)
            .height(48)
            .enabled(this.name.trim().length > 0)
            .opacity(this.name.trim().length > 0 ? 1 : 0.5)
            .onClick(() => {
              this.onSave(this.name, this.desc, this.buildPrompts())
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }
}

/** 提示词编辑卡(对应 PersonaPromptEditor):@Link 双向绑定回编辑页。 */
@Component
struct PersonaPromptEditor {
  language: MobileLanguage = MobileLanguage.ZH
  title: string = ''
  @Link checked: boolean
  @Link prompt: string

  build() {
    Column({ space: 8 }) {
      Row() {
        Text(this.title)
          .fontSize(AppTypography.titleSmall.fontSize)
          .fontWeight(AppTypography.titleSmall.fontWeight)
          .fontColor(AppTheme.colors.onSurface)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.checked && this.prompt.trim().length > 0 })
          .selectedColor(AppTheme.colors.primary)
          .enabled(this.prompt.trim().length > 0)
          .onChange((on: boolean) => {
            // 对应 onCheckedChange:仅当提示词非空时才允许开启
            this.checked = on && this.prompt.trim().length > 0
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      TextArea({
        placeholder: mobileText(this.language, '提示词', 'Prompt', 'Промпт', '프롬프트'),
        text: this.prompt
      })
        .height(120)
        .width('100%')
        .borderRadius(AppShapes.field)
        .backgroundColor(AppTheme.colors.surfaceVariant)
        .fontColor(AppTheme.colors.onSurface)
        .placeholderColor(AppTheme.colors.onSurfaceVariant)
        .maxLength(PERSONA_PROMPT_MAX_LENGTH)
        .onChange((value: string) => {
          this.prompt = value.slice(0, PERSONA_PROMPT_MAX_LENGTH)
          if (this.prompt.trim().length === 0) {
            this.checked = false
          }
        })

      Text(`${this.prompt.length} / ${PERSONA_PROMPT_MAX_LENGTH}`)
        .fontSize(AppTypography.bodySmall.fontSize)
        .fontColor(AppTheme.colors.onSurfaceVariant)
        .alignSelf(ItemAlign.End)
    }
    .width('100%')
    .padding(14)
    .borderRadius(AppShapes.card)
    .backgroundColor(AppTheme.colors.surface)
    .shadow({ radius: 4, color: '#14000000', offsetY: 1 })
    .alignItems(HorizontalAlign.Start)
  }
}

/** 新建人设弹窗(对应 CreatePersonaDialog):全屏遮罩 + 居中卡片。 */
@Component
struct CreatePersonaDialogView {
  language: MobileLanguage = MobileLanguage.ZH
  onDismiss: () => void = () => {}
  onCreate: (name: string, desc: string, prompts: PersonaPrompts) => void = () => {}

  @State name: string = ''
  @State desc: string = ''
  @State transcribePrompt: string = ''
  @State rewritePrompt: string = ''

  private buildPrompts(): PersonaPrompts {
    const prompts: PersonaPrompts = {
      transcribe_prompt: this.transcribePrompt.trim().length === 0 ? null : this.transcribePrompt,
      transcribe_enabled: this.transcribePrompt.trim().length > 0,
      rewrite_prompt: this.rewritePrompt.trim().length === 0 ? null : this.rewritePrompt,
      rewrite_enabled: this.rewritePrompt.trim().length > 0,
      intent_hint: null,
      intent_enabled: false
    }
    return prompts
  }

  build() {
    Column() {
      Column({ space: 10 }) {
        Text(mobileText(this.language, '新建人设', 'New persona', 'Новая персона', '새 페르소나'))
          .fontSize(AppTypography.titleLarge.fontSize)
          .fontWeight(AppTypography.titleLarge.fontWeight)
          .fontColor(AppTheme.colors.onSurface)

        TextInput({
          placeholder: mobileText(this.language, '名称', 'Name', 'Имя', '이름'),
          text: this.name
        })
          .height(48)
          .width('100%')
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.surfaceVariant)
          .fontColor(AppTheme.colors.onSurface)
          .placeholderColor(AppTheme.colors.onSurfaceVariant)
          .onChange((value: string) => {
            this.name = value
          })

        TextInput({
          placeholder: mobileText(this.language, '描述', 'Description', 'Описание', '설명'),
          text: this.desc
        })
          .height(48)
          .width('100%')
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.surfaceVariant)
          .fontColor(AppTheme.colors.onSurface)
          .placeholderColor(AppTheme.colors.onSurfaceVariant)
          .onChange((value: string) => {
            this.desc = value
          })

        TextArea({
          placeholder: mobileText(this.language, '语音输入提示词', 'Voice input prompt',
            'Промпт голосового ввода', '음성 입력 프롬프트'),
          text: this.transcribePrompt
        })
          .height(76)
          .width('100%')
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.surfaceVariant)
          .fontColor(AppTheme.colors.onSurface)
          .placeholderColor(AppTheme.colors.onSurfaceVariant)
          .onChange((value: string) => {
            this.transcribePrompt = value
          })

        TextArea({
          placeholder: mobileText(this.language, '指令提示词', 'Command prompt', 'Промпт команды', '명령 프롬프트'),
          text: this.rewritePrompt
        })
          .height(76)
          .width('100%')
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.surfaceVariant)
          .fontColor(AppTheme.colors.onSurface)
          .placeholderColor(AppTheme.colors.onSurfaceVariant)
          .onChange((value: string) => {
            this.rewritePrompt = value
          })

        Row({ space: 8 }) {
          Blank().layoutWeight(1)
          Button(mobileText(this.language, '取消', 'Cancel', 'Отмена', '취소'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.primary)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.onDismiss()
            })
          Button(mobileText(this.language, '保存', 'Save', 'Сохранить', '저장'))
            .fontSize(AppTypography.bodyMedium.fontSize)
            .fontColor(AppTheme.colors.onPrimary)
            .backgroundColor(AppTheme.colors.primary)
            .borderRadius(AppShapes.button)
            .enabled(this.name.trim().length > 0)
            .opacity(this.name.trim().length > 0 ? 1 : 0.5)
            .onClick(() => {
              this.onCreate(this.name, this.desc, this.buildPrompts())
            })
        }
        .width('100%')
      }
      .width('88%')
      .padding(20)
      .borderRadius(AppShapes.dialog)
      .backgroundColor(AppTheme.colors.surface)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        // 阻止点击卡片内容时冒泡到遮罩关闭
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.onDismiss()
    })
  }
}
