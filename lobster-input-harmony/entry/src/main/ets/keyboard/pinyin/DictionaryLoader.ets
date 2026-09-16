/**
 * 词库 IO 层(鸿蒙新增文件,无安卓对应):算法层(PinyinEngine/PinyinDictionary/UserDictionary)
 * 保持纯逻辑,本文件独占所有 @kit 依赖——
 *  - resourceManager.getRawFileContent 异步读取 rawfile/dict/*.txt 并 UTF-8 解码,喂给 PinyinDictionary
 *    (对齐安卓 context.assets.open;解析分块让出事件循环在 PinyinDictionary 内部完成);
 *  - PreferencesUserDictStorage:UserDictionary 的 @kit.ArkData preferences 存储实现
 *    (库名/键名与安卓 SharedPreferences(ApiConfig.PREFS_NAME) 对齐);
 *  - 组装 PinyinEngine 并触发 loadAsync(热词导入走 HotwordDictionaryBridge,对齐安卓加载顺序)。
 *
 * 用法(IME 控制层):
 *   const loader = new DictionaryLoader(context);
 *   const engine = loader.createEngine();
 *   engine.addLoadListener((state, detail) => { ... });
 *   loader.startLoad(engine);
 */
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { Logger } from '../../core/log/Logger';
import { PinyinDictSource } from './PinyinDictionary';
import { UserDictionary, UserDictStorage } from './UserDictionary';
import { PinyinEngine } from './PinyinEngine';
import { HotwordDictionaryBridge } from './HotwordDictionaryBridge';

const TAG = 'DictionaryLoader';

/** 与安卓 ApiConfig.PREFS_NAME 对齐(用户词典与热词缓存同库)。 */
const PREFS_NAME = 'lobster_input_prefs';

/** UserDictionary 的 preferences 存储实现(对齐安卓 SharedPreferences getString/putString+apply)。 */
export class PreferencesUserDictStorage implements UserDictStorage {
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  private getPrefs(): Promise<preferences.Preferences> {
    const options: preferences.Options = { name: PREFS_NAME };
    return preferences.getPreferences(this.context, options);
  }

  async getString(key: string): Promise<string | null> {
    const prefs = await this.getPrefs();
    const v = await prefs.get(key, '') as string;
    // 对齐安卓 getString(key, null):不存在返回 null
    return v.length === 0 ? null : v;
  }

  async putString(key: string, value: string): Promise<void> {
    const prefs = await this.getPrefs();
    await prefs.put(key, value);
    await prefs.flush();
  }
}

export class DictionaryLoader implements PinyinDictSource {
  private context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  /** 读取 rawfile/dict/<name> 并按 UTF-8 解码为完整文本(对齐安卓 assets.open+bufferedReader)。 */
  async readRawTextFile(name: string): Promise<string> {
    const start = Date.now();
    const data: Uint8Array = await this.context.resourceManager.getRawFileContent(`dict/${name}`);
    const decoder = util.TextDecoder.create('utf-8');
    const text = decoder.decodeToString(data);
    Logger.i(TAG, `readRawTextFile ${name}: ${data.byteLength} bytes in ${Date.now() - start}ms`);
    return text;
  }

  /**
   * 读取 rawfile/dict/<name> 的原始字节(不解码)。custom_dict v2(16.7MB)字节表专用,
   * 由 PinyinEngine 在 READY 后异步挂载 CustomDictionary 时调用
   * (镜像 Android context.assets.open(name).readBytes())。
   */
  async readRawFileBytes(name: string): Promise<Uint8Array> {
    const start = Date.now();
    const data: Uint8Array = await this.context.resourceManager.getRawFileContent(`dict/${name}`);
    Logger.i(TAG, `readRawFileBytes ${name}: ${data.byteLength} bytes in ${Date.now() - start}ms`);
    return data;
  }

  /** 组装已接线的引擎(preferences 存储的 UserDictionary),尚未加载词库。 */
  createEngine(): PinyinEngine {
    return new PinyinEngine(new UserDictionary(new PreferencesUserDictStorage(this.context)));
  }

  /**
   * 触发引擎异步加载(对齐安卓 PinyinEngine.loadAsync 的顺序:
   * 词库 → 用户词典 → 热词导入(HotwordDictionaryBridge.importInto) → READY →
   * 自定义词库 custom_dict v2 异步挂载(不阻塞键盘可用))。
   * 加载状态经 engine.addLoadListener 观察(PinyinLoadState 状态机)。
   */
  startLoad(engine: PinyinEngine): void {
    engine.loadAsync(this, (userDict: UserDictionary): Promise<void> => {
      return HotwordDictionaryBridge.importInto(userDict, this.context);
    });
  }
}
