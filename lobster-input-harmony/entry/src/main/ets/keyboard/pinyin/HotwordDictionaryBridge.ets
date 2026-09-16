/**
 * 将 App 主进程同步的热词写入键盘用户词典。
 * 移植自 Android: keyboard/pinyin/HotwordDictionaryBridge.kt(逐行对齐)。
 * MainViewModel 在热词增删改后调用 [persistHotwords];引擎启动时 [importInto] 导入调频。
 *
 * 持久化:@kit.ArkData preferences,库名与安卓 ApiConfig.PREFS_NAME 对齐(lobster_input_prefs)。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { UserDictionary } from './UserDictionary';

/** 与安卓 ApiConfig.PREFS_NAME 对齐。 */
const PREFS_NAME = 'lobster_input_prefs';

export class HotwordDictionaryBridge {

  static readonly PREFS_KEY = 'ime_hotwords_cache';

  private static getPrefs(context: common.Context): Promise<preferences.Preferences> {
    const options: preferences.Options = { name: PREFS_NAME };
    return preferences.getPreferences(context, options);
  }

  static async persistHotwords(context: common.Context, words: string[]): Promise<void> {
    // 对齐 Kotlin: trim → 过滤空 → distinct(保序)
    const seen = new Set<string>();
    const cleaned: string[] = [];
    for (const raw of words) {
      const w = raw.trim();
      if (w.length === 0 || seen.has(w)) {
        continue;
      }
      seen.add(w);
      cleaned.push(w);
    }
    const prefs = await HotwordDictionaryBridge.getPrefs(context);
    await prefs.put(HotwordDictionaryBridge.PREFS_KEY, cleaned.join('\n'));
    await prefs.flush();
  }

  static async readHotwords(context: common.Context): Promise<string[]> {
    const prefs = await HotwordDictionaryBridge.getPrefs(context);
    const raw = await prefs.get(HotwordDictionaryBridge.PREFS_KEY, '') as string;
    if (raw.length === 0) {
      return [];
    }
    const out: string[] = [];
    for (const piece of raw.split('\n')) {
      const w = piece.trim();
      if (w.length > 0) {
        out.push(w);
      }
    }
    return out;
  }

  static async importInto(userDict: UserDictionary, context: common.Context, baseBoost: number = 8): Promise<void> {
    const words = await HotwordDictionaryBridge.readHotwords(context);
    for (const word of words) {
      for (let i = 0; i < baseBoost; i++) {
        userDict.learn(word);
      }
    }
  }
}
