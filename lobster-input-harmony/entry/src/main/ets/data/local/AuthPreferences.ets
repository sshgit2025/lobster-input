// 移植自 Android: data/local/AuthPreferences.kt
// 差异:安卓由 Hilt 注入 @Singleton + Context;鸿蒙端用 getInstance() 单例,
// 底层复用全局 AppPreferences(同一 preferences 文件)与 SecureTokenStore。
import { ApiConfig } from '../../core/network/ApiConfig';
import { SecureTokenStore } from '../../core/security/SecureTokenStore';
import { AppPreferences } from './AppPreferences';
import { AuthSession } from './AuthSession';

export class AuthPreferences {
  private static instance: AuthPreferences | null = null;

  static getInstance(): AuthPreferences {
    if (AuthPreferences.instance === null) {
      AuthPreferences.instance = new AuthPreferences();
    }
    return AuthPreferences.instance;
  }

  private prefs(): AppPreferences {
    return AppPreferences.getInstance();
  }

  get authToken(): string | null {
    return SecureTokenStore.readToken();
  }

  set authToken(value: string | null) {
    SecureTokenStore.writeToken(value);
  }

  get userEmail(): string | null {
    return this.prefs().getStringSync(ApiConfig.KEY_USER_EMAIL, null);
  }

  set userEmail(value: string | null) {
    if (value === null) {
      this.prefs().removeSync(ApiConfig.KEY_USER_EMAIL);
    } else {
      this.prefs().putStringSync(ApiConfig.KEY_USER_EMAIL, value);
    }
  }

  get userTier(): string | null {
    return this.prefs().getStringSync(ApiConfig.KEY_USER_TIER, null);
  }

  set userTier(value: string | null) {
    if (value === null) {
      this.prefs().removeSync(ApiConfig.KEY_USER_TIER);
    } else {
      this.prefs().putStringSync(ApiConfig.KEY_USER_TIER, value);
    }
  }

  get isLoggedIn(): boolean {
    const t = this.authToken;
    return t !== null && t.length > 0;
  }

  /** 记录一次成功发码,写入邮箱与冷却到期时间戳(持久化,跨进程有效)。 */
  markCodeSent(email: string, cooldownSeconds: number): void {
    this.prefs().putStringSync(ApiConfig.KEY_SEND_CODE_EMAIL, email);
    this.prefs().putNumberSync(ApiConfig.KEY_SEND_CODE_EXPIRES_AT, Date.now() + cooldownSeconds * 1000);
  }

  /** 返回指定邮箱当前剩余的发码冷却秒数(0 表示可再次发送)。 */
  sendCodeRemainingSeconds(email: string): number {
    if (email.length === 0) {
      return 0;
    }
    if (this.prefs().getStringSync(ApiConfig.KEY_SEND_CODE_EMAIL, null) !== email) {
      return 0;
    }
    const expiresAt = this.prefs().getNumberSync(ApiConfig.KEY_SEND_CODE_EXPIRES_AT, 0);
    const remainingMs = expiresAt - Date.now();
    return remainingMs > 0 ? Math.floor((remainingMs + 999) / 1000) : 0;
  }

  /** 若最近发码邮箱仍在冷却期内,返回该邮箱,用于登录页预填并恢复倒计时。 */
  pendingSendCodeEmail(): string | null {
    const email = this.prefs().getStringSync(ApiConfig.KEY_SEND_CODE_EMAIL, null);
    if (email === null) {
      return null;
    }
    return this.sendCodeRemainingSeconds(email) > 0 ? email : null;
  }

  clear(): void {
    AuthSession.clear();
  }

  getAuthHeader(): string {
    return `Bearer ${this.authToken ?? ''}`;
  }
}
