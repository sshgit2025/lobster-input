// 公共基础设施:@kit.ArkData preferences 单例封装(契约见 PORTING_GUIDE)。
// 对应安卓 SharedPreferences(文件名 ApiConfig.PREFS_NAME)。
// - 契约方法(async):getString/putString/getBoolean/putBoolean/getNumber/putNumber/remove
// - 额外提供 *Sync 同步方法,对齐安卓 SharedPreferences 的同步读写语义,
//   供 MobileStrings/AuthSession/MobileHistoryStore 等原本同步的调用方使用。
//   putXxxSync 语义等价安卓 .apply():内存立即生效,磁盘异步落盘。
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ApiConfig } from '../../core/network/ApiConfig';
import { Logger } from '../../core/log/Logger';

const TAG: string = 'AppPreferences';

export class AppPreferences {
  private static instance: AppPreferences | null = null;

  private pref: preferences.Preferences;

  private constructor(context: common.Context) {
    const options: preferences.Options = { name: ApiConfig.PREFS_NAME };
    this.pref = preferences.getPreferencesSync(context, options);
  }

  /** 统一初始化入口(EntryAbility / IME Ability 启动时调用一次)。 */
  static init(context: common.Context): AppPreferences {
    if (AppPreferences.instance === null) {
      AppPreferences.instance = new AppPreferences(context);
    }
    return AppPreferences.instance;
  }

  /**
   * 获取单例。首次调用必须传 context(或先调 init);
   * 之后可不带 context 直接获取。
   */
  static getInstance(context?: common.Context): AppPreferences {
    if (AppPreferences.instance === null) {
      if (context === undefined) {
        throw new Error('AppPreferences 未初始化:请先调用 AppPreferences.init(context)');
      }
      AppPreferences.instance = new AppPreferences(context);
    }
    return AppPreferences.instance;
  }

  // ==================== 契约 async 方法 ====================

  async getString(key: string, defValue: string | null = null): Promise<string | null> {
    return this.getStringSync(key, defValue);
  }

  async putString(key: string, value: string): Promise<void> {
    this.pref.putSync(key, value);
    await this.pref.flush();
  }

  async getBoolean(key: string, defValue: boolean = false): Promise<boolean> {
    return this.getBooleanSync(key, defValue);
  }

  async putBoolean(key: string, value: boolean): Promise<void> {
    this.pref.putSync(key, value);
    await this.pref.flush();
  }

  async getNumber(key: string, defValue: number = 0): Promise<number> {
    return this.getNumberSync(key, defValue);
  }

  async putNumber(key: string, value: number): Promise<void> {
    this.pref.putSync(key, value);
    await this.pref.flush();
  }

  async remove(key: string): Promise<void> {
    this.pref.deleteSync(key);
    await this.pref.flush();
  }

  // ==================== 同步方法(对齐安卓 SharedPreferences 语义) ====================

  hasSync(key: string): boolean {
    return this.pref.hasSync(key);
  }

  getStringSync(key: string, defValue: string | null = null): string | null {
    if (!this.pref.hasSync(key)) {
      return defValue;
    }
    const v = this.pref.getSync(key, '');
    return typeof v === 'string' ? v : defValue;
  }

  putStringSync(key: string, value: string): void {
    this.pref.putSync(key, value);
    this.flushAsync();
  }

  getBooleanSync(key: string, defValue: boolean = false): boolean {
    if (!this.pref.hasSync(key)) {
      return defValue;
    }
    const v = this.pref.getSync(key, defValue);
    return typeof v === 'boolean' ? v : defValue;
  }

  putBooleanSync(key: string, value: boolean): void {
    this.pref.putSync(key, value);
    this.flushAsync();
  }

  getNumberSync(key: string, defValue: number = 0): number {
    if (!this.pref.hasSync(key)) {
      return defValue;
    }
    const v = this.pref.getSync(key, defValue);
    return typeof v === 'number' ? v : defValue;
  }

  putNumberSync(key: string, value: number): void {
    this.pref.putSync(key, value);
    this.flushAsync();
  }

  removeSync(key: string): void {
    this.pref.deleteSync(key);
    this.flushAsync();
  }

  /** 显式落盘(一般无需调用,putXxxSync 已异步落盘)。 */
  async flush(): Promise<void> {
    await this.pref.flush();
  }

  /** 等价安卓 .apply():异步落盘,失败仅记日志不抛错。 */
  private flushAsync(): void {
    this.pref.flush().catch((err: Error) => {
      Logger.w(TAG, `preferences flush 失败: ${err.message}`);
    });
  }
}
