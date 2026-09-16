// 移植自 Android: data/local/AuthSession.kt
// 差异:安卓每个方法带 Context;鸿蒙端 AppPreferences/SecureTokenStore 为全局单例,无需 context 参数。
import { ApiConfig } from '../../core/network/ApiConfig';
import { SecureTokenStore } from '../../core/security/SecureTokenStore';
import { AppPreferences } from './AppPreferences';

export class AuthSession {
  static isLoggedIn(): boolean {
    const t = AuthSession.token();
    return t !== null && t.trim().length > 0;
  }

  static authHeader(): string | null {
    const t = AuthSession.token();
    if (t !== null && t.trim().length > 0) {
      return `Bearer ${t}`;
    }
    return null;
  }

  static clear(): void {
    SecureTokenStore.clearToken();
    const prefs = AppPreferences.getInstance();
    prefs.removeSync(ApiConfig.KEY_USER_EMAIL);
    prefs.removeSync(ApiConfig.KEY_USER_TIER);
  }

  /** 仅当传入的 authHeader 与当前登录态一致(或为空)时才清除,避免旧请求 401 清掉新登录态。 */
  static clearIfCurrent(authHeader: string | null): boolean {
    const current = AuthSession.authHeader();
    if (authHeader === null || authHeader.trim().length === 0 || current === authHeader) {
      AuthSession.clear();
      return true;
    }
    return false;
  }

  private static token(): string | null {
    return SecureTokenStore.readToken();
  }
}
