// 移植自 Android: core/security/SecureTokenStore.kt
//
// 集中封装登录 token 的加密读写。
//
// 平台替换说明(逻辑语义对齐安卓版):
// - 安卓用 Android Keystore(AES/GCM)加密后把密文写入 SharedPreferences;
// - 鸿蒙用 @kit.AssetStoreKit(系统级关键资产存储,内核托管加密)保存 token 明文,
//   preferences 里的 ApiConfig.KEY_AUTH_TOKEN_ENC 不再存密文,而是存"存储位置标记":
//     "asset:<时间戳>"  → token 在 asset 中;时间戳变化用于跨调用方感知登录态更新
// - asset 写入失败时对齐安卓"加密失败绝不落明文"语义(SecureTokenStore.kt 99-112):
//   清除持久化标记、不把明文写进 preferences;仅保留进程内 memoryOnlyToken,
//   保证本次会话不掉线,进程重启后需重新登录。
// - 读写结果做内存缓存(以标记值为键):isLoggedIn()/authHeader() 会被键盘 UI 高频调用,
//   若每次都走 asset IPC 查询会重演安卓端的 ANR 事故;标记未变直接返回缓存。
// - 所有 asset 异常都被吞掉并降级,绝不崩溃。
// - 没有标记时清除旧版残留的明文 key(不迁移,老用户重新登录即可);
//   旧版降级路径写下的 "plain:<token>" 明文标记视为不安全残留,读到即清除。
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiConfig } from '../network/ApiConfig';
import { Logger } from '../log/Logger';
import { AppPreferences } from '../../data/local/AppPreferences';

const TAG: string = 'SecureTokenStore';

// asset 中的别名(对应安卓 Keystore 别名 lobster_token_key)
const KEY_ALIAS: string = 'lobster_token_key';
const MARK_ASSET_PREFIX: string = 'asset:';
// 旧版降级路径的明文标记前缀:现已不再写入,仅用于识别并清除历史残留。
const MARK_PLAIN_PREFIX: string = 'plain:';
// asset 错误码:数据不存在
const ASSET_NOT_FOUND: number = 24000002;

function stringToBytes(s: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(s);
}

function bytesToString(bytes: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(bytes);
}

export class SecureTokenStore {
  /**
   * 缓存(标记值键控)。标记未变直接返回缓存,不再触碰 asset;
   * 登录态变化(标记变化)会自然 miss 并重新读取。
   */
  private static cachedMark: string | null = null;
  private static cachedPlain: string | null = null;
  /**
   * asset 写入失败时的"仅内存"token(不持久化,对齐安卓"加密失败绝不落明文"):
   * 本次会话内 readToken 仍能返回它(不掉线),进程重启后丢失,需重新登录。
   */
  private static memoryOnlyToken: string | null = null;

  /**
   * 读取 token(同步)。任何异常都降级返回 null(等价于需要重新登录)。
   */
  static readToken(): string | null {
    const prefs = AppPreferences.getInstance();
    const mark = prefs.getStringSync(ApiConfig.KEY_AUTH_TOKEN_ENC, null);
    if (mark !== null) {
      // 命中缓存:标记未变,直接返回上次结果,绝不重复走 asset 查询。
      if (mark === SecureTokenStore.cachedMark) {
        return SecureTokenStore.cachedPlain;
      }
      if (mark.startsWith(MARK_PLAIN_PREFIX)) {
        // 旧版降级路径残留的明文标记:安全对齐后不再支持明文持久化,
        // 读到即清除并按未登录处理(与"旧明文 key 不迁移"策略一致)。
        Logger.w(TAG, '发现旧版明文 token 标记,已清除(需重新登录)');
        prefs.removeSync(ApiConfig.KEY_AUTH_TOKEN_ENC);
        SecureTokenStore.cachedMark = null;
        SecureTokenStore.cachedPlain = null;
        return SecureTokenStore.memoryOnlyToken;
      }
      try {
        const plain = SecureTokenStore.queryAssetToken();
        SecureTokenStore.cachedMark = mark;
        SecureTokenStore.cachedPlain = plain;
        return plain;
      } catch (err) {
        const e = err as BusinessError;
        Logger.w(TAG, `读取 asset token 失败,降级为未登录: ${e.code} ${e.message}`);
        SecureTokenStore.cachedMark = null;
        SecureTokenStore.cachedPlain = null;
        return null;
      }
    }

    // 没有标记:清空缓存,并清除旧版残留的明文 token(不迁移,老用户重新登录即可)。
    // asset 写失败的会话内降级:返回仅内存 token(未持久化,重启即失效)。
    SecureTokenStore.cachedMark = null;
    SecureTokenStore.cachedPlain = null;
    if (prefs.hasSync(ApiConfig.KEY_AUTH_TOKEN)) {
      prefs.removeSync(ApiConfig.KEY_AUTH_TOKEN);
    }
    return SecureTokenStore.memoryOnlyToken;
  }

  /**
   * 写入 token(同步):value 为 null/空时等价于清除;
   * 优先写 asset;失败时对齐安卓"加密失败绝不落明文"语义(SecureTokenStore.kt 99-112):
   * 清除持久化标记、不把明文写进 preferences,仅保留进程内 memoryOnlyToken
   * (本次会话不掉线,进程重启后需重新登录)。
   */
  static writeToken(value: string | null): void {
    if (value === null || value.length === 0) {
      SecureTokenStore.clearToken();
      return;
    }
    const prefs = AppPreferences.getInstance();
    try {
      SecureTokenStore.putAssetToken(value);
      const mark = `${MARK_ASSET_PREFIX}${Date.now()}`;
      prefs.putStringSync(ApiConfig.KEY_AUTH_TOKEN_ENC, mark);
      prefs.removeSync(ApiConfig.KEY_AUTH_TOKEN);
      // 同步刷新缓存,使后续读取直接命中,无需查询 asset。
      SecureTokenStore.cachedMark = mark;
      SecureTokenStore.cachedPlain = value;
      SecureTokenStore.memoryOnlyToken = null;
    } catch (err) {
      const e = err as BusinessError;
      Logger.e(TAG, `写入 asset token 失败,不落明文,仅保留内存缓存(重启后需重新登录): ${e.code} ${e.message}`);
      // 对齐安卓:清除持久化状态,保持一致;明文只留在进程内存。
      prefs.removeSync(ApiConfig.KEY_AUTH_TOKEN_ENC);
      prefs.removeSync(ApiConfig.KEY_AUTH_TOKEN);
      SecureTokenStore.cachedMark = null;
      SecureTokenStore.cachedPlain = null;
      SecureTokenStore.memoryOnlyToken = value;
    }
  }

  /** 清除 token:同时移除 asset 记录、标记 key、旧明文 key 与仅内存降级 token。 */
  static clearToken(): void {
    SecureTokenStore.cachedMark = null;
    SecureTokenStore.cachedPlain = null;
    SecureTokenStore.memoryOnlyToken = null;
    try {
      SecureTokenStore.removeAssetToken();
    } catch (err) {
      const e = err as BusinessError;
      if (e.code !== ASSET_NOT_FOUND) {
        Logger.w(TAG, `清除 asset token 失败(忽略): ${e.code} ${e.message}`);
      }
    }
    const prefs = AppPreferences.getInstance();
    prefs.removeSync(ApiConfig.KEY_AUTH_TOKEN_ENC);
    prefs.removeSync(ApiConfig.KEY_AUTH_TOKEN);
  }

  // ==================== 契约 async 接口(见 PORTING_GUIDE) ====================

  static async save(token: string | null): Promise<void> {
    SecureTokenStore.writeToken(token);
  }

  static async load(): Promise<string | null> {
    return SecureTokenStore.readToken();
  }

  static async clear(): Promise<void> {
    SecureTokenStore.clearToken();
  }

  // ==================== asset 底层操作 ====================

  /** 查询 asset 中的 token;不存在返回 null,其余异常向上抛。 */
  private static queryAssetToken(): string | null {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, stringToBytes(KEY_ALIAS));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = asset.querySync(query);
      if (results.length === 0) {
        return null;
      }
      const secret = results[0].get(asset.Tag.SECRET);
      if (secret === undefined) {
        return null;
      }
      return bytesToString(secret as Uint8Array);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === ASSET_NOT_FOUND) {
        return null;
      }
      throw err as Error;
    }
  }

  /** 写入(覆盖)asset 中的 token:先删旧值(不存在则忽略)再新增。 */
  private static putAssetToken(value: string): void {
    try {
      SecureTokenStore.removeAssetToken();
    } catch (err) {
      const e = err as BusinessError;
      if (e.code !== ASSET_NOT_FOUND) {
        throw err as Error;
      }
    }
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, stringToBytes(KEY_ALIAS));
    attrs.set(asset.Tag.SECRET, stringToBytes(value));
    // 设备首次解锁后可访问:输入法可能在锁屏前后被拉起,放宽到 DEVICE_FIRST_UNLOCKED。
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    asset.addSync(attrs);
  }

  private static removeAssetToken(): void {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, stringToBytes(KEY_ALIAS));
    asset.removeSync(query);
  }
}
