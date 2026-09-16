// 对应安卓 LobsterInputApp.kt(Application.onCreate 的全局初始化)+ Hilt 单例装配。
// 鸿蒙没有全局 Application 类,EntryAbility 与 IME 的 InputMethodExtensionAbility
// 各自在 onCreate 中调用 AppInitializer.init(context) 完成基础设施初始化(可重复调用,幂等)。
import { common } from '@kit.AbilityKit';
import { AppPreferences } from '../data/local/AppPreferences';
import { DeviceIdentity } from '../core/device/DeviceIdentity';
import { FileLog } from '../core/log/FileLog';
import { Logger } from '../core/log/Logger';

const TAG: string = 'AppInitializer';

export class AppInitializer {
  private static initialized: boolean = false;
  private static appContext: common.Context | null = null;

  /**
   * 全局初始化:必须在任何业务模块(网络/存储/多语言)使用前调用。
   * - AppPreferences:键值存储单例(MobileStrings/AuthSession/SecureTokenStore 等全部依赖)
   * - FileLog:落盘日志目录
   * - DeviceIdentity:设备标识 fallback UUID 装载
   */
  static init(context: common.Context): void {
    if (AppInitializer.initialized) {
      return;
    }
    // 等价安卓 LobsterInputApp.instance = this:持有应用级 context 供全局使用。
    AppInitializer.appContext = context.getApplicationContext();
    AppPreferences.init(AppInitializer.appContext);
    FileLog.init(AppInitializer.appContext);
    DeviceIdentity.init(AppInitializer.appContext);
    AppInitializer.initialized = true;
    Logger.i(TAG, '全局基础设施初始化完成');
  }

  /** 等价安卓 LobsterInputApp.instance:获取应用级 Context(未初始化时抛错)。 */
  static getContext(): common.Context {
    const ctx = AppInitializer.appContext;
    if (ctx === null) {
      throw new Error('AppInitializer 未初始化:请先在 Ability.onCreate 中调用 AppInitializer.init(context)');
    }
    return ctx;
  }
}
