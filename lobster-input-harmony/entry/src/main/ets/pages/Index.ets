// 对应安卓 ui/MainActivity.kt + ui/LobsterApp.kt:@Entry 根页,按登录态路由 MainPage / AuthPage。
// Compose NavHost(auth/main) → 条件渲染;登录态来源与安卓一致(token 是否存在)。
import { common, ConfigurationConstant } from '@kit.AbilityKit'
import { AppInitializer } from '../common/AppInitializer'
import { AuthPreferences } from '../data/local/AuthPreferences'
import { Logger } from '../core/log/Logger'
import { MainPage, BackRouter } from './MainPage'
import { AuthPage } from './AuthPage'
import { AppTheme, AppTypography } from './theme/AppTheme'

const TAG: string = 'Index'

@Entry
@Component
struct Index {
  /** 基础设施初始化完成前显示启动占位。 */
  @State ready: boolean = false
  /** 对应 LobsterApp rememberSessionLoggedIn()。 */
  @State isLoggedIn: boolean = false
  private backRouter: BackRouter = new BackRouter()

  async aboutToAppear(): Promise<void> {
    const context: common.Context = getContext(this)

    // 按系统深浅色初始化主题(对应 LobsterInputTheme isSystemInDarkTheme)
    try {
      const uiContext: common.UIAbilityContext = context as common.UIAbilityContext
      const dark: boolean = uiContext.config !== undefined &&
        uiContext.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
      AppTheme.setDarkMode(dark)
    } catch (e) {
      Logger.w(TAG, `read colorMode failed: ${(e as Error).message}`)
    }

    // 初始化基础设施(幂等;AppPreferences 就绪后 MobileStrings 即可同步读取语言偏好)
    try {
      AppInitializer.init(context)
    } catch (e) {
      Logger.w(TAG, `AppInitializer init failed: ${(e as Error).message}`)
    }

    await this.refreshLoginState()
    this.ready = true
  }

  /** 登录态 = token 是否存在(对应 AuthSession.isLoggedIn)。 */
  private async refreshLoginState(): Promise<void> {
    try {
      this.isLoggedIn = AuthPreferences.getInstance().isLoggedIn
    } catch (e) {
      Logger.w(TAG, `read login state failed: ${(e as Error).message}`)
      this.isLoggedIn = false
    }
  }

  /**
   * 安卓通过 SharedPreferences 监听 token 变化自动回登录页;
   * 鸿蒙侧在页面重新可见时复查一次登录态(会话过期由接口 401 → 清 token → 此处兜底)。
   */
  onPageShow(): void {
    if (this.ready) {
      this.refreshLoginState()
    }
  }

  /** 系统返回键:主界面内部子页/弹窗优先消费(对应 popBackStack)。 */
  onBackPress(): boolean {
    if (!this.isLoggedIn) {
      return false
    }
    const handler: (() => boolean) | null = this.backRouter.onBack
    return handler !== null ? handler() : false
  }

  build() {
    Column() {
      if (!this.ready) {
        // 启动占位
        Column() {
          Text('龙虾输入法')
            .fontSize(AppTypography.titleLarge.fontSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppTheme.colors.onBackground)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.isLoggedIn) {
        MainPage({
          onLogout: (): void => {
            this.isLoggedIn = false
          },
          backRouter: this.backRouter
        })
      } else {
        AuthPage({
          onLoginSuccess: (): void => {
            this.isLoggedIn = true
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppTheme.colors.background)
  }
}
