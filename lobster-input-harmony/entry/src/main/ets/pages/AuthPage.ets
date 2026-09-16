// 对应安卓 ui/auth/AuthScreen.kt(301 行):登录/注册(邮箱验证码)+ 邀请码验证全流程。
// 由 Index.ets 按登录态条件渲染;登录成功回调 onLoginSuccess。
import { common } from '@kit.AbilityKit'
import { MobileStrings, MobileLanguage } from '../core/locale/MobileStrings'
import { DeviceIdentity } from '../core/device/DeviceIdentity'
import { AuthViewModel, AuthUiModel, AuthUiState } from './viewmodel/AuthViewModel'
import { AppTheme, AppShapes, AppTypography } from './theme/AppTheme'

/** 与 AuthScreen.kt 底部私有 mobileText 一致的多语言内联文案。 */
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

@Component
export struct AuthPage {
  /** 登录成功回调(对应 AuthScreen onLoginSuccess)。 */
  onLoginSuccess: () => void = () => {}

  @State language: MobileLanguage = MobileLanguage.ZH
  @State ui: AuthUiModel = new AuthUiModel()
  @State email: string = ''
  @State code: string = ''
  @State inviteCode: string = ''
  @State showInviteInput: boolean = false
  private viewModel: AuthViewModel | null = null

  async aboutToAppear(): Promise<void> {
    const context: common.Context = getContext(this)
    this.language = MobileStrings.currentLanguage()
    const vm: AuthViewModel = new AuthViewModel(context, this.ui)
    vm.onSuccess = (): void => {
      this.onLoginSuccess()
    }
    vm.onRequireInvite = (): void => {
      this.showInviteInput = true
    }
    this.viewModel = vm
    // 若最近发码邮箱仍在冷却期内,预填并恢复倒计时(对应 pendingCooldownEmail + LaunchedEffect(email))
    const pending: string = await vm.pendingCooldownEmail()
    if (pending.length > 0) {
      this.email = pending
    }
    vm.refreshCooldown(this.email)
  }

  aboutToDisappear(): void {
    if (this.viewModel !== null) {
      this.viewModel.dispose()
    }
  }

  private isLoading(): boolean {
    return this.ui.state === AuthUiState.Loading
  }

  /** 邀请码验证(对应 AuthScreen 验证按钮:现场取设备标识后提交)。 */
  private async onVerifyInviteClick(): Promise<void> {
    const deviceId: string = DeviceIdentity.deviceId()
    const fingerprint: string = DeviceIdentity.hardwareFingerprint()
    this.viewModel?.verifyInvite(this.email, this.inviteCode, deviceId, fingerprint)
  }

  build() {
    Column() {
      // Logo:龙虾钳图标(lobster_claw)
      Column() {
        Image($r('app.media.lobster_claw'))
          .width(52)
          .height(52)
          .objectFit(ImageFit.Contain)
      }
      .width(88)
      .height(88)
      .borderRadius(24)
      .backgroundColor(AppTheme.colors.primaryContainer)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .shadow({ radius: 4, color: '#14000000', offsetY: 1 })

      Blank().height(20)

      Text(MobileStrings.keyboardTitle())
        .fontSize(AppTypography.headlineMedium.fontSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppTheme.colors.onBackground)
        .textAlign(TextAlign.Center)

      Blank().height(8)

      Text(mobileText(this.language, '登录后开启智能语音输入', 'Sign in to start smart voice input',
        'Войдите, чтобы начать голосовой ввод', '로그인하여 스마트 음성 입력을 시작하세요'))
        .fontSize(AppTypography.bodyMedium.fontSize)
        .fontColor(AppTheme.colors.onSurfaceVariant)
        .textAlign(TextAlign.Center)

      Blank().height(28)

      // 登录卡片
      Column() {
        if (!this.showInviteInput) {
          this.LoginForm()
        } else {
          this.InviteForm()
        }

        // 错误提示
        if (this.ui.state === AuthUiState.Error) {
          Blank().height(16)
          Row() {
            Text('!')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.colors.onErrorContainer)
              .width(18)
              .textAlign(TextAlign.Center)
            Blank().width(8)
            Text(this.ui.errorMessage)
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.onErrorContainer)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.errorContainer)
        }

        // 成功提示(验证码已发送)
        if (this.ui.state === AuthUiState.CodeSent) {
          Blank().height(16)
          Row() {
            Text('✓')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppTheme.colors.onPrimaryContainer)
              .width(18)
              .textAlign(TextAlign.Center)
            Blank().width(8)
            Text(mobileText(this.language, '验证码已发送', 'Code sent', 'Код отправлен', '인증 코드가 전송되었습니다'))
              .fontSize(AppTypography.bodyMedium.fontSize)
              .fontColor(AppTheme.colors.onPrimaryContainer)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
          .borderRadius(AppShapes.field)
          .backgroundColor(AppTheme.colors.primaryContainer)
        }
      }
      .width('100%')
      .padding(20)
      .borderRadius(AppShapes.large)
      .backgroundColor(AppTheme.colors.surface)
      .shadow({ radius: 6, color: '#1A000000', offsetY: 2 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.colors.background)
    .padding({ left: 24, right: 24, top: 24, bottom: 24 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 邮箱 + 验证码 + 登录按钮。 */
  @Builder
  LoginForm() {
    // 邮箱输入
    TextInput({
      placeholder: mobileText(this.language, '邮箱', 'Email', 'Почта', '이메일'),
      text: this.email
    })
      .type(InputType.Email)
      .height(52)
      .borderRadius(AppShapes.field)
      .backgroundColor(AppTheme.colors.surfaceVariant)
      .fontColor(AppTheme.colors.onSurface)
      .placeholderColor(AppTheme.colors.onSurfaceVariant)
      .onChange((value: string) => {
        this.email = value
        // 邮箱变化时按本地持久化时间戳恢复/刷新发码倒计时(退出 APP 重进仍生效)
        this.viewModel?.refreshCooldown(value)
      })

    Blank().height(14)

    // 验证码输入 + 尾部发送按钮
    Row() {
      TextInput({
        placeholder: mobileText(this.language, '验证码', 'Code', 'Код', '인증 코드'),
        text: this.code
      })
        .type(InputType.Number)
        .height(52)
        .layoutWeight(1)
        .borderRadius(AppShapes.field)
        .backgroundColor(AppTheme.colors.surfaceVariant)
        .fontColor(AppTheme.colors.onSurface)
        .placeholderColor(AppTheme.colors.onSurfaceVariant)
        .onChange((value: string) => {
          this.code = value
        })
      Blank().width(8)
      Button(this.ui.cooldownSeconds > 0
        ? mobileText(this.language, `重新发送(${this.ui.cooldownSeconds}s)`, `Resend(${this.ui.cooldownSeconds}s)`,
          `Повтор(${this.ui.cooldownSeconds}s)`, `재전송(${this.ui.cooldownSeconds}s)`)
        : mobileText(this.language, '发送验证码', 'Send code', 'Отправить код', '코드 보내기'))
        .fontSize(AppTypography.labelLarge.fontSize)
        .fontColor(AppTheme.colors.primary)
        .backgroundColor(Color.Transparent)
        .height(52)
        .enabled(this.email.length > 0 && this.ui.cooldownSeconds <= 0 && !this.isLoading())
        .opacity(this.email.length > 0 && this.ui.cooldownSeconds <= 0 && !this.isLoading() ? 1 : 0.4)
        .onClick(() => {
          this.viewModel?.sendCode(this.email)
        })
    }
    .width('100%')

    Blank().height(24)

    // 登录按钮
    Button() {
      if (this.isLoading()) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(AppTheme.colors.onPrimary)
      } else {
        Text(mobileText(this.language, '登录', 'Sign in', 'Войти', '로그인'))
          .fontSize(AppTypography.titleMedium.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.colors.onPrimary)
      }
    }
    .width('100%')
    .height(52)
    .borderRadius(AppShapes.button)
    .backgroundColor(AppTheme.colors.primary)
    .enabled(this.email.length > 0 && this.code.length > 0 && !this.isLoading())
    .opacity(this.email.length > 0 && this.code.length > 0 && !this.isLoading() ? 1 : 0.5)
    .onClick(() => {
      this.viewModel?.login(this.email, this.code)
    })
  }

  /** 邀请码输入 + 验证按钮。 */
  @Builder
  InviteForm() {
    Text(mobileText(this.language, '需要邀请码才能继续', 'Invite code required',
      'Нужен код приглашения', '초대 코드가 필요합니다'))
      .fontSize(AppTypography.titleMedium.fontSize)
      .fontWeight(FontWeight.Medium)
      .fontColor(AppTheme.colors.onSurface)

    Blank().height(16)

    TextInput({
      placeholder: mobileText(this.language, '邀请码', 'Invite code', 'Код приглашения', '초대 코드'),
      text: this.inviteCode
    })
      .height(52)
      .borderRadius(AppShapes.field)
      .backgroundColor(AppTheme.colors.surfaceVariant)
      .fontColor(AppTheme.colors.onSurface)
      .placeholderColor(AppTheme.colors.onSurfaceVariant)
      .onChange((value: string) => {
        this.inviteCode = value
      })

    Blank().height(24)

    Button() {
      if (this.isLoading()) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(AppTheme.colors.onPrimary)
      } else {
        Text(mobileText(this.language, '验证邀请码', 'Verify invite', 'Проверить код', '초대 코드 확인'))
          .fontSize(AppTypography.titleMedium.fontSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppTheme.colors.onPrimary)
      }
    }
    .width('100%')
    .height(52)
    .borderRadius(AppShapes.button)
    .backgroundColor(AppTheme.colors.primary)
    .enabled(this.inviteCode.length > 0 && !this.isLoading())
    .opacity(this.inviteCode.length > 0 && !this.isLoading() ? 1 : 0.5)
    .onClick(() => {
      this.onVerifyInviteClick()
    })
  }
}
