// 移植自 Android: core/device/DeviceIdentity.kt
//
// 设备唯一标识与硬件指纹工具。
// 字段格式与 MAC/Windows/安卓端保持一致:SHA-256 输出的 64 位小写十六进制字符串。
//
// 平台替换说明:
// - 安卓 ANDROID_ID → 鸿蒙 deviceInfo.ODID(开发者匿名设备标识,同一开发者同一设备稳定,
//   恢复出厂/重装场景会变化,特性与 ANDROID_ID 接近)。ODID 异常为空时降级为
//   本地持久化的随机 UUID(存 preferences,key=device_fallback_id),需先经 init() 装载。
// - Build.FINGERPRINT → deviceInfo.versionId(含设备与系统版本的完整版本标识)
// - Build.BOARD → deviceInfo.productModel
// - Build.HARDWARE → deviceInfo.hardwareModel
// - SUPPORTED_ABIS[0] → deviceInfo.abiList 第一项
import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { AppPreferences } from '../../data/local/AppPreferences';
import { Logger } from '../log/Logger';

const TAG: string = 'DeviceIdentity';
const KEY_FALLBACK_ID: string = 'device_fallback_id';

function sha256(input: string): string {
  const md = cryptoFramework.createMd('SHA256');
  const encoder = new util.TextEncoder();
  const blob: cryptoFramework.DataBlob = { data: encoder.encodeInto(input) };
  md.updateSync(blob);
  const digest = md.digestSync();
  let hex = '';
  for (let i = 0; i < digest.data.length; i++) {
    hex += digest.data[i].toString(16).padStart(2, '0');
  }
  return hex;
}

export class DeviceIdentity {
  /** ODID 为空时使用的持久化随机 UUID(init 时装载/生成)。 */
  private static fallbackId: string = '';

  /**
   * 初始化:仅当 ODID 取不到时才需要 fallback UUID,
   * 但统一在 App/IME 启动时调用一次,保证后续 deviceId() 可同步返回稳定值。
   */
  static init(context: common.Context): void {
    if (DeviceIdentity.fallbackId.length > 0) {
      return;
    }
    const prefs = AppPreferences.getInstance(context);
    let stored = prefs.getStringSync(KEY_FALLBACK_ID, null);
    if (stored === null || stored.length === 0) {
      stored = util.generateRandomUUID();
      prefs.putStringSync(KEY_FALLBACK_ID, stored);
    }
    DeviceIdentity.fallbackId = stored;
  }

  /** 取原始设备标识:优先 ODID,为空则用持久化随机 UUID,再兜底常量。 */
  private static rawId(): string {
    let odid = '';
    try {
      odid = deviceInfo.ODID;
    } catch (err) {
      Logger.w(TAG, `读取 ODID 失败: ${(err as Error).message}`);
    }
    if (odid !== null && odid !== undefined && odid.length > 0) {
      return odid;
    }
    if (DeviceIdentity.fallbackId.length > 0) {
      return DeviceIdentity.fallbackId;
    }
    return 'unknown_odid';
  }

  /**
   * 设备 ID:对设备标识做 SHA-256 哈希。
   * 哈希后格式与 MAC/Win/安卓端(64 位 hex)统一,避免明文上报系统标识符。
   */
  static deviceId(): string {
    return sha256(DeviceIdentity.rawId());
  }

  /**
   * 硬件指纹:组合多个相对稳定的系统级属性后 SHA-256 哈希。
   * 组合项:ODID | versionId | productModel | hardwareModel | 首个 ABI
   * (与安卓 ANDROID_ID | FINGERPRINT | BOARD | HARDWARE | CPU_ABI 逐项对应)。
   */
  static hardwareFingerprint(): string {
    let raw = '';
    try {
      raw = DeviceIdentity.rawId();
    } catch (err) {
      raw = 'unknown';
    }
    let versionId = '';
    let productModel = '';
    let hardwareModel = '';
    let firstAbi = 'unknown_abi';
    try {
      versionId = deviceInfo.versionId;
      productModel = deviceInfo.productModel;
      hardwareModel = deviceInfo.hardwareModel;
      const abiList: string = deviceInfo.abiList;
      if (abiList !== null && abiList !== undefined && abiList.length > 0) {
        const parts = abiList.split(',');
        if (parts.length > 0 && parts[0].length > 0) {
          firstAbi = parts[0];
        }
      }
    } catch (err) {
      Logger.w(TAG, `读取硬件信息失败: ${(err as Error).message}`);
    }
    const components: string[] = [raw, versionId, productModel, hardwareModel, firstAbi];
    return sha256(components.join('|'));
  }
}
