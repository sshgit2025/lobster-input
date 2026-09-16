// 对应安卓 ui/auth/AuthViewModel.kt(133 行)。
// sealed class AuthUiState → 字符串枚举 + errorMessage 字段;
// StateFlow → 页面持有 @State AuthUiModel 实例并把(代理后的)引用传入本 ViewModel。
import { common } from '@kit.AbilityKit'
import { AuthRepository } from '../../data/repository/AuthRepository'
import { AuthPreferences } from '../../data/local/AuthPreferences'
import { ApiConfig } from '../../core/network/ApiConfig'
import { MobileStrings } from '../../core/locale/MobileStrings'
import { DeviceIdentity } from '../../core/device/DeviceIdentity'
import { AuthResponse, displayMessage } from '../../data/model/ApiModels'

/** 对应 Kotlin sealed class AuthUiState 的六种状态。 */
export enum AuthUiState {
  Idle = 'idle',
  Loading = 'loading',
  CodeSent = 'codeSent',
  RequireInvite = 'requireInvite',
  Success = 'success',
  Error = 'error'
}

/** 页面可观察的认证状态聚合(uiState/requireInvite/cooldownSeconds/isLoggedIn 各 StateFlow 的合体)。 */
export class AuthUiModel {
  state: AuthUiState = AuthUiState.Idle
  /** state === Error 时的错误文案(对应 AuthUiState.Error.message)。 */
  errorMessage: string = ''
  requireInvite: boolean = false
  /** 发送验证码剩余冷却秒数(0 表示可发送),基于本地持久化时间戳,退出重进仍生效。 */
  cooldownSeconds: number = 0
  isLoggedIn: boolean = false
}

export class AuthViewModel {
  private context: common.Context
  private ui: AuthUiModel
  private authRepository: AuthRepository
  private authPreferences: AuthPreferences
  /** 冷却倒计时定时器句柄(对应 cooldownJob)。 */
  private cooldownTimer: number = -1
  /** 登录成功回调(对应 AuthScreen LaunchedEffect(uiState) → Success 分支)。 */
  onSuccess: () => void = () => {}
  /** 需要邀请码回调(对应 RequireInvite 分支)。 */
  onRequireInvite: () => void = () => {}

  constructor(context: common.Context, ui: AuthUiModel) {
    this.context = context
    this.ui = ui
    this.authRepository = AuthRepository.getInstance()
    this.authPreferences = AuthPreferences.getInstance()
  }

  /** 页面销毁时停表,避免泄漏。 */
  dispose(): void {
    this.stopCooldownTicker()
  }

  async initLoggedIn(): Promise<void> {
    this.ui.isLoggedIn = await this.authRepository.isLoggedIn()
  }

  /** 登录页若最近发码邮箱仍在冷却期内,返回该邮箱用于预填(无则返回空串)。 */
  async pendingCooldownEmail(): Promise<string> {
    const email: string | null = await this.authPreferences.pendingSendCodeEmail()
    return email !== null ? email : ''
  }

  /** 根据本地持久化时间戳,恢复指定邮箱当前的发码倒计时。 */
  async refreshCooldown(email: string): Promise<void> {
    const seconds: number = await this.authPreferences.sendCodeRemainingSeconds(email)
    this.startCooldownTicker(seconds)
  }

  private stopCooldownTicker(): void {
    if (this.cooldownTimer !== -1) {
      clearInterval(this.cooldownTimer)
      this.cooldownTimer = -1
    }
  }

  private startCooldownTicker(seconds: number): void {
    this.stopCooldownTicker()
    if (seconds <= 0) {
      this.ui.cooldownSeconds = 0
      return
    }
    this.ui.cooldownSeconds = seconds
    this.cooldownTimer = setInterval(() => {
      const next: number = this.ui.cooldownSeconds - 1
      this.ui.cooldownSeconds = next > 0 ? next : 0
      if (this.ui.cooldownSeconds <= 0) {
        this.stopCooldownTicker()
      }
    }, 1000)
  }

  async sendCode(email: string): Promise<void> {
    if (this.ui.cooldownSeconds > 0) {
      return
    }
    this.ui.state = AuthUiState.Loading
    try {
      await this.authRepository.sendCode(email)
      await this.authPreferences.markCodeSent(email, ApiConfig.SEND_CODE_COOLDOWN_SEC)
      this.startCooldownTicker(ApiConfig.SEND_CODE_COOLDOWN_SEC)
      this.ui.state = AuthUiState.CodeSent
    } catch (e) {
      this.ui.errorMessage = displayMessage(e as Error, MobileStrings.sendCodeFailed())
      this.ui.state = AuthUiState.Error
    }
  }

  async login(email: string, code: string): Promise<void> {
    this.ui.state = AuthUiState.Loading
    try {
      const deviceId: string = DeviceIdentity.deviceId()
      const fingerprint: string = DeviceIdentity.hardwareFingerprint()
      const response: AuthResponse = await this.authRepository.login(email, code, deviceId, fingerprint)
      this.ui.requireInvite = response.require_invite

      if (response.require_invite) {
        this.ui.state = AuthUiState.RequireInvite
        this.onRequireInvite()
      } else {
        this.ui.isLoggedIn = true
        this.ui.state = AuthUiState.Success
        this.onSuccess()
      }
    } catch (e) {
      this.ui.errorMessage = displayMessage(e as Error, MobileStrings.loginFailed())
      this.ui.state = AuthUiState.Error
    }
  }

  async verifyInvite(email: string, inviteCode: string, deviceId: string, hardwareFingerprint: string): Promise<void> {
    this.ui.state = AuthUiState.Loading
    try {
      await this.authRepository.verifyInvite(email, inviteCode, deviceId, hardwareFingerprint)
      this.ui.isLoggedIn = true
      this.ui.state = AuthUiState.Success
      this.onSuccess()
    } catch (e) {
      this.ui.errorMessage = displayMessage(e as Error, MobileStrings.inviteVerifyFailed())
      this.ui.state = AuthUiState.Error
    }
  }

  resetState(): void {
    this.ui.state = AuthUiState.Idle
  }
}
