// 移植自 Android: core/update/AndroidUpdateManager.kt
//
// 鸿蒙端不支持 APK 侧载 OTA(应用分发走应用市场),按移植公约:
// - 保留:更新清单拉取(FEED_URL)、清单解析、版本号比较(versionCode 数值比较)、
//   当前安装版本读取、多语言错误文案;
// - 移除:downloadApk / installApk / canRequestPackageInstalls / openInstallPermissionSettings /
//   APK sha256 校验 / 包名与版本校验 / 更新缓存目录清理(鸿蒙端无下载缓存);
// - 新增:marketUpdateHint() 返回"请前往应用市场更新"的本地化提示,UI 检测到新版本时展示。
import { http } from '@kit.NetworkKit';
import { bundleManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ApiConfig } from '../network/ApiConfig';
import { MobileStrings, MobileLanguage } from '../locale/MobileStrings';
import { Logger } from '../log/Logger';

const TAG: string = 'UpdateManager';

/** 对应 Kotlin AndroidInstalledVersion。 */
export interface InstalledVersion {
  versionCode: number;
  versionName: string;
}

/** 对应 Kotlin AndroidUpdateManifest,字段名与更新清单 JSON 一致。 */
export interface UpdateManifest {
  version_code: number;
  version_name: string;
  apk_url: string;
  apk_sha256: string | null;
  release_notes: string | null;
  force: boolean; // 默认 false
  published_at: string | null;
}

/** 对应 Kotlin sealed interface AndroidUpdateCheckResult:updateAvailable=false 即 NoUpdate。 */
export interface UpdateCheckResult {
  updateAvailable: boolean;
  manifest: UpdateManifest | null;
}

function asRecord(o: Object): Record<string, Object> {
  return o as Record<string, Object>;
}

function parseUpdateManifest(json: string): UpdateManifest {
  const rec = asRecord(JSON.parse(json) as object);
  const versionCodeRaw: Object | undefined = rec['version_code'];
  const versionNameRaw: Object | undefined = rec['version_name'];
  const apkUrlRaw: Object | undefined = rec['apk_url'];
  const apkSha256Raw: Object | undefined = rec['apk_sha256'];
  const releaseNotesRaw: Object | undefined = rec['release_notes'];
  const forceRaw: Object | undefined = rec['force'];
  const publishedAtRaw: Object | undefined = rec['published_at'];
  const result: UpdateManifest = {
    version_code: typeof versionCodeRaw === 'number' ? versionCodeRaw : 0,
    version_name: typeof versionNameRaw === 'string' ? versionNameRaw : '',
    apk_url: typeof apkUrlRaw === 'string' ? apkUrlRaw : '',
    apk_sha256: typeof apkSha256Raw === 'string' ? apkSha256Raw : null,
    release_notes: typeof releaseNotesRaw === 'string' ? releaseNotesRaw : null,
    force: typeof forceRaw === 'boolean' ? forceRaw : false,
    published_at: typeof publishedAtRaw === 'string' ? publishedAtRaw : null,
  };
  return result;
}

export class UpdateManager {
  /**
   * 检查更新:拉取更新清单并与当前安装版本比较(versionCode 数值比较,与安卓一致)。
   * 无更新时返回 { updateAvailable: false, manifest: null }。
   */
  async checkForUpdate(): Promise<UpdateCheckResult> {
    const body = await this.fetchFeed();
    let manifest: UpdateManifest | null = null;
    try {
      manifest = parseUpdateManifest(body);
    } catch (err) {
      manifest = null;
    }
    if (manifest === null || manifest.version_code <= 0) {
      throw new Error(
        this.updateText('更新清单格式无效', 'Invalid update feed', 'Некорректный файл обновления',
          '업데이트 정보 형식이 올바르지 않습니다')
      );
    }
    const installed = await this.currentInstalledVersion();
    if (manifest.version_code > installed.versionCode) {
      const result: UpdateCheckResult = { updateAvailable: true, manifest: manifest };
      return result;
    }
    const noUpdate: UpdateCheckResult = { updateAvailable: false, manifest: null };
    return noUpdate;
  }

  /** 读取当前安装版本(对应安卓 currentInstalledVersion,经 bundleManager 获取)。 */
  async currentInstalledVersion(): Promise<InstalledVersion> {
    const bundleInfo = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const result: InstalledVersion = {
      versionCode: bundleInfo.versionCode,
      versionName: bundleInfo.versionName,
    };
    return result;
  }

  /** 检测到新版本时的引导文案:鸿蒙端不做应用内下载安装,提示前往应用市场更新。 */
  marketUpdateHint(): string {
    return this.updateText(
      '发现新版本，请前往应用市场更新',
      'A new version is available. Please update from AppGallery.',
      'Доступна новая версия. Обновите приложение в AppGallery.',
      '새 버전이 있습니다. 앱 마켓에서 업데이트하세요.'
    );
  }

  /** 拉取更新清单原文(独立 http 客户端,超时对齐安卓 updateHttpClient:连接 30s / 读 90s)。 */
  private async fetchFeed(): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const requestOptions: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 30 * 1000,
        readTimeout: 90 * 1000,
      };
      const response = await httpRequest.request(ApiConfig.Update.FEED_URL, requestOptions);
      const code = response.responseCode;
      if (code < 200 || code >= 300) {
        throw new Error(
          this.updateText(`检查更新失败：HTTP ${code}`, `Update check failed: HTTP ${code}`,
            `Проверка обновлений не удалась: HTTP ${code}`, `업데이트 확인 실패: HTTP ${code}`)
        );
      }
      return typeof response.result === 'string' ? response.result : '';
    } catch (err) {
      const e = err as BusinessError;
      Logger.w(TAG, `检查更新失败: ${e.code} ${e.message}`);
      throw err as Error;
    } finally {
      httpRequest.destroy();
    }
  }

  /** 多语言更新文案(对应安卓 updateText,按当前语言取值)。 */
  private updateText(zh: string, en: string, ru: string, ko: string): string {
    const lang = MobileStrings.currentLanguage();
    if (lang === MobileLanguage.EN) {
      return en;
    }
    if (lang === MobileLanguage.RU) {
      return ru;
    }
    if (lang === MobileLanguage.KO) {
      return ko;
    }
    return zh;
  }
}
