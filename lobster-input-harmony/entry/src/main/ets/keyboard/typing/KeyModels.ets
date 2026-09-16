// 对齐 Android: keyboard/typing/KeyModels.kt
import { PinyinLoadState } from '../pinyin/PinyinLoadState';

/** 键类型。 */
export enum KeyType {
  LETTER, T9, DELETE, SPACE, ENTER, SHIFT,
  LANG, LAYOUT,
  NUM, SYMBOL, ALPHA, SYM_CHAR, SYM_PAGE,
  SYLLABLE, UNDO, EMOJI, CLIP,
  /** 模式轮换键(中文九宫格→中文26键→英文→俄语→韩语循环,全布局常驻,自绘循环箭头图标)。 */
  MODE_CYCLE,
  /** 分类符号板入口(最近/中文/英文/括号/数学/序号/货币/箭头)。 */
  SYM_BOARD,
  /** 9 宫格 1 键(@#):候选栏展示固定高频符号候选(对齐豆包)。 */
  SYM_CANDS,
  GAP
}

/**
 * 键盘输入语种。中英文为核心语种(LANG 键互切);俄/韩为扩展语种(独立布局,
 * 齿轮工具页直达 + App 界面语言为俄/韩时进入 LANG 轮换序列)。
 * (Kotlin enum 带属性 → ArkTS 用类 + 静态实例,引用相等性与 Kotlin enum 一致。)
 */
export class InputLang {
  static readonly ZH: InputLang = new InputLang('zh', '中', '中文');
  static readonly EN: InputLang = new InputLang('en', 'EN', 'English');
  static readonly RU: InputLang = new InputLang('ru', 'РУ', 'Русский');
  static readonly KO: InputLang = new InputLang('ko', '한', '한국어');

  readonly code: string;
  readonly keyLabel: string;
  readonly nativeName: string;

  private constructor(code: string, keyLabel: string, nativeName: string) {
    this.code = code;
    this.keyLabel = keyLabel;
    this.nativeName = nativeName;
  }

  static entries(): InputLang[] {
    return [InputLang.ZH, InputLang.EN, InputLang.RU, InputLang.KO];
  }

  static fromCode(code?: string): InputLang {
    const all = InputLang.entries();
    for (let i = 0; i < all.length; i++) {
      if (all[i].code === code) return all[i];
    }
    return InputLang.ZH;
  }
}

/** KeySpec 可选字段(Kotlin 具名参数 → ArkTS options 对象)。 */
export interface KeySpecOptions {
  sub?: string;
  weight?: number;
  value?: string;
  longValue?: string;
  shiftValue?: string;
}

/**
 * 一个键的描述(数据驱动布局)。longValue:长按时输出的字符(9宫格键长按出数字、26键字母行长按出数字、
 * 俄语 е 长按出 ё)。shiftValue:shift 按下时的输入/显示字符(韩语双辅音 ㅂ→ㅃ 等;拉丁/西里尔大小写不走此字段)。
 */
export class KeySpec {
  readonly type: KeyType;
  readonly main: string;
  readonly sub?: string;
  readonly weight: number;
  readonly value?: string;
  readonly longValue?: string;
  readonly shiftValue?: string;

  constructor(type: KeyType, main: string = '', options?: KeySpecOptions) {
    this.type = type;
    this.main = main;
    this.sub = options?.sub;
    this.weight = options?.weight ?? 1;
    this.value = options?.value;
    this.longValue = options?.longValue;
    this.shiftValue = options?.shiftValue;
  }
}

/** 需要本地化的键盘文案。 */
export enum KbStr {
  RETURN_VOICE, SPACE, CH, EN, NINEGRID, QWERTY,
  SYMBOL, SWITCH_QWERTY, PINYIN, ABC, SYLLABLE, UNDO
}

/**
 * 键盘与宿主 IME 的对接接口。
 * (Kotlin 接口默认实现在 ArkTS 不可用 → 全部方法必选,由 TypingSessionHost 完整实现。)
 */
export interface TypingKeyboardHost {
  onCommit(text: string): void;
  /** 智能标点配对上屏:插入 opening+closing 后把光标置于二者之间。 */
  onCommitPair(opening: string, closing: string): void;
  /** 组合预览写入目标框(韩语组字音节,setComposing 通道;拼音不走此通道)。 */
  onComposingText(text: string): void;
  /** 定稿目标框中的组合预览(finishComposing)。 */
  onFinishComposing(): void;
  /** 移动光标(dx<0 左移,dx>0 右移)。 */
  onMoveCursor(dx: number): void;
  /** 光标后是否还有文字(1 键符号候选的成套插入判定:光标后无文字才成套插入括号/书名号)。 */
  hasTextAfterCursor(): boolean;
  /** 光标前 ≤maxChars 字符(标点联想 v2 的句内上下文;取不到返回空串,调用方走降级路径)。 */
  textBeforeCursor(maxChars: number): string;
  onDeleteBeforeCursor(): void;
  onEnter(): void;
  onReturnToVoice(): void;
  onKeyboardMicStart(): void;
  onKeyboardMicStop(): void;
  isChineseModeDefault(): boolean;
  persistChineseMode(chinese: boolean): void;
  isNineGridDefault(): boolean;
  persistNineGrid(nine: boolean): void;
  /** 当前默认输入语种(持久化的用户选择;跨语言组切换后为组默认语种)。 */
  inputLangDefault(): InputLang;
  persistInputLang(lang: InputLang): void;
  /** 当前 App 界面语言组的默认输入语种(中英组按界面语言:zh/繁/粤→中文,en→英文;ru→俄语;ko→韩语)。 */
  groupDefaultLang(): InputLang;
  /**
   * App 界面语言组变化检测(消费式):跨组切换(中英组↔俄↔韩)返回 true 并把持久化输入语种
   * 重置为新组默认;组内互切(中英文互切)返回 false 不动任何暂存状态。
   */
  consumeLangGroupChange(): boolean;
  onKeyFeedback(): void;
  localize(key: KbStr): string;
  enterKeyLabel(): string;
  isPasswordField(): boolean;
  /** 数字/电话/日期时间输入框:进入时自动切换到数字键盘页。 */
  isNumericField(): boolean;
  /** 邮箱/URI/密码类 ASCII 输入框:进入时自动切换英文模式(会话内,不覆盖用户偏好)。 */
  isEnglishField(): boolean;
  /** 键盘麦克风是否可用(未登录时置灰禁用,键盘仍可打字)。 */
  isMicAvailable(): boolean;
  canUndo(): boolean;
  undoLastCommit(): void;
  recordRecentEmoji(emoji: string): void;
  recentEmojis(): string[];
  /** 分类符号板「最近使用」(键盘/语音两处共用同一存储)。 */
  recordRecentSymbol(symbol: string): void;
  recentSymbols(): string[];
  clipboardHistory(): string[];
  quickPhrases(): string[];
  removeClipboardItem(item: string): void;
  clearClipboard(): void;
}

/**
 * 打字键盘视图对协调层暴露的能力(Android 直接引用 TypingKeyboardView 类;
 * 鸿蒙侧 UI 为 ArkUI @Component,由 UI agent 实现本接口并注入协调器)。
 */
export interface TypingKeyboardViewApi {
  /** 复位组合串/候选(拉起输入法、进入打字模式时调用)。 */
  resetComposing(): void;
  /** 输入框 Enter 动作变化后刷新回车键文案。 */
  refreshEnterKey(): void;
  /** 键盘会话结束(键盘收起):清除会话级模式粘性。 */
  onSessionEnd(): void;
  /** 拼音词库加载状态变化。 */
  onEngineLoadState(state: PinyinLoadState, detail?: string): void;
  /** 强制结束麦克风录音 UI(校验失败/错误/外部停止)。 */
  stopMicRecordingUI(): void;
}
