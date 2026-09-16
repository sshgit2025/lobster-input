// 对齐 Android: keyboard/typing/coordinator/ClipboardStore.kt
// Android ClipboardManager → @kit.BasicServicesKit pasteboard;SharedPreferences → AppPreferences。
// AppPreferences 为 async 接口,这里用内存缓存保持 Android 同步读写语义:
// load() 在 IME 启动时预载,读走缓存,写为缓存先行 + 异步落盘(fire-and-forget)。
import { pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { AppPreferences } from '../../../data/local/AppPreferences';
import { Logger } from '../../../core/log/Logger';

const TAG = 'ClipboardStore';

/**
 * 剪贴板历史 + 快捷短语(prefs 持久化)。
 * 系统剪贴板只暴露当前剪贴内容,故每次打开剪贴板面板时快照当前内容入历史(去重)。
 * 密码框由调用方禁用,不在此记录。
 */
export class ClipboardStore {
  private readonly prefs: AppPreferences;
  private historyCache: string[] = [];
  private phrasesCache?: string[];

  constructor(context: common.Context) {
    this.prefs = AppPreferences.getInstance(context);
  }

  /** 预载持久化数据到内存缓存(IME 启动时调用一次)。 */
  async load(): Promise<void> {
    try {
      const h = (await this.prefs.getString(ClipboardStore.KEY_HISTORY, '')) ?? '';
      this.historyCache = h.split(ClipboardStore.SEP).filter((it: string) => it.length > 0);
      const p = (await this.prefs.getString(ClipboardStore.KEY_PHRASES, '')) ?? '';
      const custom = p.split(ClipboardStore.SEP).filter((it: string) => it.length > 0);
      this.phrasesCache = p.length > 0 ? custom : undefined;
    } catch (e) {
      Logger.w(TAG, `load failed: ${e}`);
    }
  }

  private persistHistory(): void {
    this.prefs.putString(ClipboardStore.KEY_HISTORY, this.historyCache.join(ClipboardStore.SEP))
      .catch((e: Error) => Logger.w(TAG, `persist history failed: ${e.message}`));
  }

  /** 快照当前系统剪贴板到历史(最多 20,最新在前)。返回历史列表。 */
  snapshotAndGet(): string[] {
    try {
      const pb = pasteboard.getSystemPasteboard();
      let text: string | undefined = undefined;
      if (pb.hasDataSync()) {
        const data = pb.getDataSync();
        const primary = data.getPrimaryText();
        if (primary !== undefined) text = primary.trim();
      }
      if (text !== undefined && text.length > 0) {
        const list: string[] = this.history();
        const idx = list.indexOf(text);
        if (idx >= 0) list.splice(idx, 1);
        list.unshift(text);
        while (list.length > ClipboardStore.MAX) list.splice(list.length - 1, 1);
        this.historyCache = list;
        this.persistHistory();
      }
    } catch (e) {
      // 剪贴板读取失败(权限/内容不可用):忽略,返回既有历史(对齐 Kotlin runCatching)
    }
    return this.history();
  }

  history(): string[] {
    return this.historyCache.slice();
  }

  clearHistory(): void {
    this.historyCache = [];
    this.prefs.remove(ClipboardStore.KEY_HISTORY)
      .catch((e: Error) => Logger.w(TAG, `clear history failed: ${e.message}`));
  }

  removeHistory(item: string): void {
    const list: string[] = this.history();
    const idx = list.indexOf(item);
    if (idx >= 0) list.splice(idx, 1);
    this.historyCache = list;
    this.persistHistory();
  }

  /** 快捷短语:用户自定义 + 内置默认。 */
  quickPhrases(): string[] {
    return this.phrasesCache ?? ClipboardStore.DEFAULT_PHRASES;
  }

  static readonly KEY_HISTORY: string = 'ime_clipboard_history';
  static readonly KEY_PHRASES: string = 'ime_quick_phrases';
  private static readonly SEP: string = '\u0001'; // 与 Android 存储分隔符(U+0001)一致,数据格式互通
  private static readonly MAX: number = 20;
  private static readonly DEFAULT_PHRASES: string[] = [
    '好的,收到', '稍等一下', '在的', '谢谢', '辛苦了', '马上处理', '已收到,谢谢'
  ];
}
