// 对齐 Android: keyboard/typing/coordinator/TypingPreferences.kt
// SharedPreferences(同步) → AppPreferences(异步)。用内存缓存保持 Android 同步读写语义:
// load() 在 IME 启动时预载全部键,读走缓存,写为缓存先行 + 异步落盘(fire-and-forget)。
import { common } from '@kit.AbilityKit';
import { AppPreferences } from '../../../data/local/AppPreferences';
import { Logger } from '../../../core/log/Logger';
import { PinyinFuzzySettings } from '../../pinyin/PinyinFuzzy';

const TAG = 'TypingPreferences';

/** 打字键盘用户偏好(中/英、布局、是否记住键盘模式、模糊音/纠错、最近 emoji)。 */
export class TypingPreferences {
  private readonly prefs: AppPreferences;
  private readonly boolCache: Map<string, boolean> = new Map<string, boolean>();
  private readonly strCache: Map<string, string> = new Map<string, string>();

  constructor(context: common.Context) {
    this.prefs = AppPreferences.getInstance(context);
  }

  /** 预载持久化数据到内存缓存(IME 启动时调用一次)。 */
  async load(): Promise<void> {
    try {
      const boolKeys: string[] = [
        TypingPreferences.KEY_CHINESE, TypingPreferences.KEY_NINEGRID,
        TypingPreferences.KEY_REMEMBER_MODE, TypingPreferences.KEY_LAST_MODE_KB,
        TypingPreferences.KEY_FUZZY_ZZH, TypingPreferences.KEY_FUZZY_CCH, TypingPreferences.KEY_FUZZY_SSH,
        TypingPreferences.KEY_FUZZY_LN, TypingPreferences.KEY_FUZZY_FH, TypingPreferences.KEY_FUZZY_RL,
        TypingPreferences.KEY_FUZZY_ANANG, TypingPreferences.KEY_FUZZY_ENENG, TypingPreferences.KEY_FUZZY_INING,
        TypingPreferences.KEY_CORRECTION
      ];
      for (let i = 0; i < boolKeys.length; i++) {
        const key = boolKeys[i];
        // 仅缓存已持久化的键;未设置的键不进缓存,由各读取方自带的安卓默认值兜底:
        // chineseMode 默认 true、flag()/getFlag() 默认 false(含纠错键,对齐 Android flag()),
        // fuzzySettings 内的纠错单独默认 true(对齐 Android getBoolean(KEY_CORRECTION, true))。
        // 若在此处把默认值写进缓存,会抹掉"纠错键两条读取路径默认值不同"的安卓语义。
        if (this.prefs.hasSync(key)) {
          this.boolCache.set(key, await this.prefs.getBoolean(key, false));
        }
      }
      const strKeys: string[] = [
        TypingPreferences.KEY_INPUT_LANG, TypingPreferences.KEY_LANG_GROUP,
        TypingPreferences.KEY_RECENT_EMOJI, TypingPreferences.KEY_RECENT_SYMBOL
      ];
      for (let i = 0; i < strKeys.length; i++) {
        const key = strKeys[i];
        const v = await this.prefs.getString(key, TypingPreferences.UNSET);
        if (v !== null && v !== TypingPreferences.UNSET) this.strCache.set(key, v);
      }
    } catch (e) {
      Logger.w(TAG, `load failed: ${e}`);
    }
  }

  private persistBool(key: string, value: boolean): void {
    this.prefs.putBoolean(key, value).catch((e: Error) => Logger.w(TAG, `persist ${key} failed: ${e.message}`));
  }

  private persistStr(key: string, value: string): void {
    this.prefs.putString(key, value).catch((e: Error) => Logger.w(TAG, `persist ${key} failed: ${e.message}`));
  }

  get chineseMode(): boolean {
    return this.boolCache.get(TypingPreferences.KEY_CHINESE) ?? true;
  }

  set chineseMode(value: boolean) {
    this.boolCache.set(TypingPreferences.KEY_CHINESE, value);
    this.persistBool(TypingPreferences.KEY_CHINESE, value);
  }

  /** 输入语种 code(zh/en/ru/ko)。缺省从旧 chineseMode 偏好推导(平滑升级)。 */
  get inputLang(): string {
    return this.strCache.get(TypingPreferences.KEY_INPUT_LANG) ?? (this.chineseMode ? 'zh' : 'en');
  }

  set inputLang(value: string) {
    this.strCache.set(TypingPreferences.KEY_INPUT_LANG, value);
    this.persistStr(TypingPreferences.KEY_INPUT_LANG, value);
  }

  /** 上次已知的 App 界面语言组(zhen/ru/ko),用于跨组切换检测。 */
  get langGroup(): string | undefined {
    return this.strCache.get(TypingPreferences.KEY_LANG_GROUP);
  }

  set langGroup(value: string | undefined) {
    if (value === undefined) {
      this.strCache.delete(TypingPreferences.KEY_LANG_GROUP);
      this.prefs.remove(TypingPreferences.KEY_LANG_GROUP)
        .catch((e: Error) => Logger.w(TAG, `remove lang group failed: ${e.message}`));
    } else {
      this.strCache.set(TypingPreferences.KEY_LANG_GROUP, value);
      this.persistStr(TypingPreferences.KEY_LANG_GROUP, value);
    }
  }

  get nineGrid(): boolean {
    return this.boolCache.get(TypingPreferences.KEY_NINEGRID) ?? false;
  }

  set nineGrid(value: boolean) {
    this.boolCache.set(TypingPreferences.KEY_NINEGRID, value);
    this.persistBool(TypingPreferences.KEY_NINEGRID, value);
  }

  /** 跨输入框是否保持键盘模式(默认 false:每次聚焦回语音)。 */
  get rememberTypingMode(): boolean {
    return this.boolCache.get(TypingPreferences.KEY_REMEMBER_MODE) ?? false;
  }

  set rememberTypingMode(value: boolean) {
    this.boolCache.set(TypingPreferences.KEY_REMEMBER_MODE, value);
    this.persistBool(TypingPreferences.KEY_REMEMBER_MODE, value);
  }

  /** 记住上次是语音还是键盘模式(默认 false=语音;用户手动切换后持久化,下次拉起恢复)。 */
  get lastModeKeyboard(): boolean {
    return this.boolCache.get(TypingPreferences.KEY_LAST_MODE_KB) ?? false;
  }

  set lastModeKeyboard(value: boolean) {
    this.boolCache.set(TypingPreferences.KEY_LAST_MODE_KB, value);
    this.persistBool(TypingPreferences.KEY_LAST_MODE_KB, value);
  }

  /** 开关键读取,缺省一律 false(对齐 Android flag(),含纠错键 KEY_CORRECTION)。 */
  private flag(key: string): boolean {
    return this.boolCache.get(key) ?? false;
  }

  setFlag(key: string, value: boolean): void {
    this.boolCache.set(key, value);
    this.persistBool(key, value);
  }

  getFlag(key: string): boolean {
    return this.flag(key);
  }

  /** 最近使用 emoji(最多 24,最新在前)。 */
  recentEmojis(): string[] {
    const raw = this.strCache.get(TypingPreferences.KEY_RECENT_EMOJI);
    if (raw === undefined) return [];
    return raw.split(TypingPreferences.EMOJI_SEP).filter((it: string) => it.length > 0);
  }

  recordRecentEmoji(emoji: string): void {
    if (emoji.length === 0) return;
    const list: string[] = this.recentEmojis();
    const idx = list.indexOf(emoji);
    if (idx >= 0) list.splice(idx, 1);
    list.unshift(emoji);
    while (list.length > 24) list.splice(list.length - 1, 1);
    const joined = list.join(TypingPreferences.EMOJI_SEP);
    this.strCache.set(TypingPreferences.KEY_RECENT_EMOJI, joined);
    this.persistStr(TypingPreferences.KEY_RECENT_EMOJI, joined);
  }

  /** 最近使用符号(最多 16,最新在前;键盘/语音符号板共用)。 */
  recentSymbols(): string[] {
    const raw = this.strCache.get(TypingPreferences.KEY_RECENT_SYMBOL);
    if (raw === undefined) return [];
    return raw.split(TypingPreferences.EMOJI_SEP).filter((it: string) => it.length > 0);
  }

  recordRecentSymbol(symbol: string): void {
    if (symbol.length === 0) return;
    const list: string[] = this.recentSymbols();
    const idx = list.indexOf(symbol);
    if (idx >= 0) list.splice(idx, 1);
    list.unshift(symbol);
    while (list.length > 16) list.splice(list.length - 1, 1);
    const joined = list.join(TypingPreferences.EMOJI_SEP);
    this.strCache.set(TypingPreferences.KEY_RECENT_SYMBOL, joined);
    this.persistStr(TypingPreferences.KEY_RECENT_SYMBOL, joined);
  }

  /** 由各模糊音/纠错开关组装出引擎所需配置。 */
  fuzzySettings(): PinyinFuzzySettings {
    const s = new PinyinFuzzySettings();
    s.zZh = this.flag(TypingPreferences.KEY_FUZZY_ZZH);
    s.cCh = this.flag(TypingPreferences.KEY_FUZZY_CCH);
    s.sSh = this.flag(TypingPreferences.KEY_FUZZY_SSH);
    s.lN = this.flag(TypingPreferences.KEY_FUZZY_LN);
    s.fH = this.flag(TypingPreferences.KEY_FUZZY_FH);
    s.rL = this.flag(TypingPreferences.KEY_FUZZY_RL);
    s.anAng = this.flag(TypingPreferences.KEY_FUZZY_ANANG);
    s.enEng = this.flag(TypingPreferences.KEY_FUZZY_ENENG);
    s.inIng = this.flag(TypingPreferences.KEY_FUZZY_INING);
    // 纠错默认开启:它只在候选不足时兜底纠正错拼,不污染正常输入,无需用户配置
    s.correction = this.boolCache.get(TypingPreferences.KEY_CORRECTION) ?? true;
    return s;
  }

  static readonly KEY_CHINESE: string = 'ime_typing_chinese_mode';
  static readonly KEY_INPUT_LANG: string = 'ime_typing_input_lang';
  static readonly KEY_LANG_GROUP: string = 'ime_typing_lang_group';
  static readonly KEY_NINEGRID: string = 'ime_typing_ninegrid';
  static readonly KEY_REMEMBER_MODE: string = 'ime_typing_remember_mode';
  static readonly KEY_LAST_MODE_KB: string = 'ime_typing_last_mode_keyboard';
  static readonly KEY_FUZZY_ZZH: string = 'ime_fuzzy_zzh';
  static readonly KEY_FUZZY_CCH: string = 'ime_fuzzy_cch';
  static readonly KEY_FUZZY_SSH: string = 'ime_fuzzy_ssh';
  static readonly KEY_FUZZY_LN: string = 'ime_fuzzy_ln';
  static readonly KEY_FUZZY_FH: string = 'ime_fuzzy_fh';
  static readonly KEY_FUZZY_RL: string = 'ime_fuzzy_rl';
  static readonly KEY_FUZZY_ANANG: string = 'ime_fuzzy_anang';
  static readonly KEY_FUZZY_ENENG: string = 'ime_fuzzy_eneng';
  static readonly KEY_FUZZY_INING: string = 'ime_fuzzy_ining';
  static readonly KEY_CORRECTION: string = 'ime_fuzzy_correction';
  static readonly KEY_RECENT_EMOJI: string = 'ime_recent_emoji';
  static readonly KEY_RECENT_SYMBOL: string = 'ime_recent_symbol';
  // 分隔符与 Android 一致(U+0001),存储格式互通
  private static readonly EMOJI_SEP: string = '\u0001';
  // getString 的"缺省哨兵"(区分空串与未设置)
  private static readonly UNSET: string = ' __unset__';
}
