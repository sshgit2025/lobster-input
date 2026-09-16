// 对齐 Android: keyboard/typing/coordinator/TypingSessionHost.kt(253 行)
import { common } from '@kit.AbilityKit';
import { MobileLanguage, MobileStrings } from '../../../core/locale/MobileStrings';
import { PinyinLoadState } from '../../pinyin/PinyinLoadState';
import { PinyinFuzzySettings } from '../../pinyin/PinyinFuzzy';
import { InputLang, KbStr, TypingKeyboardHost } from '../KeyModels';
import { ComposingTextBridge } from '../composing/ComposingTextBridge';
import { TypingUndoManager } from '../composing/TypingUndoManager';
import { EditorActionModel, EditorInfoAction } from '../editor/EditorActionModel';
import { EditorInfoResolver } from '../editor/EditorInfoResolver';
import { IME_TEXT_MAX } from '../ImeClientApi';
import { ClipboardStore } from './ClipboardStore';
import { TypingImeContext } from './TypingImeContext';
import { TypingPreferences } from './TypingPreferences';

/** App 界面语言组解析结果(Kotlin Pair<String, InputLang> 的等价物)。 */
interface LangGroupInfo {
  group: string;
  def: InputLang;
}

/**
 * TypingKeyboardHost 实现:上屏、组合预览、Enter 动作、撤销、本地化。
 */
export class TypingSessionHost implements TypingKeyboardHost {
  private readonly context: common.Context;
  private readonly ime: TypingImeContext;
  private readonly preferences: TypingPreferences;
  private readonly composingBridge: ComposingTextBridge;
  private readonly undoManager: TypingUndoManager;
  private editorAction: EditorActionModel;
  private statusCallback?: (message?: string) => void;
  private inputBlockedCallback?: (blocked: boolean) => void;
  private readonly clipboardStore: ClipboardStore;

  constructor(context: common.Context, ime: TypingImeContext, preferences: TypingPreferences,
    composingBridge: ComposingTextBridge, undoManager: TypingUndoManager,
    editorAction: EditorActionModel = EditorActionModel.DEFAULT,
    statusCallback?: (message?: string) => void,
    inputBlockedCallback?: (blocked: boolean) => void) {
    this.context = context;
    this.ime = ime;
    this.preferences = preferences;
    this.composingBridge = composingBridge;
    this.undoManager = undoManager;
    this.editorAction = editorAction;
    this.statusCallback = statusCallback;
    this.inputBlockedCallback = inputBlockedCallback;
    this.clipboardStore = new ClipboardStore(context);
  }

  /** 鸿蒙新增:预载偏好/剪贴板持久化缓存(IME 服务启动时 await 一次)。 */
  async init(): Promise<void> {
    await this.preferences.load();
    await this.clipboardStore.load();
  }

  refreshEditorAction(): void {
    this.editorAction = EditorInfoResolver.resolve(this.context, this.ime.editorAttribute());
  }

  setStatusCallback(callback: (message?: string) => void): void {
    this.statusCallback = callback;
  }

  setInputBlockedCallback(callback: (blocked: boolean) => void): void {
    this.inputBlockedCallback = callback;
  }

  onCommit(text: string): void {
    this.composingBridge.clear();
    this.ime.inputClient()?.commitText(text);
    this.undoManager.record(text);
  }

  // 韩语组字预览:组合中音节直接写目标框(setComposing 通道,业界标准的光标下划线预览)
  onComposingText(text: string): void {
    this.ime.inputClient()?.setComposing(text);
  }

  onFinishComposing(): void {
    this.ime.inputClient()?.finishComposing();
  }

  onCommitPair(opening: string, closing: string): void {
    this.composingBridge.clear();
    const ic = this.ime.inputClient();
    if (ic === undefined) {
      this.undoManager.record(opening);
      return;
    }
    ic.beginBatchEdit();
    ic.commitText(opening + closing);
    // Android:getTextBeforeCursor 失败(null)时按 opening+closing 长度兜底
    let pos = ic.getTextBeforeCursor(IME_TEXT_MAX).length;
    if (pos < opening.length + closing.length) pos = opening.length + closing.length;
    ic.setSelection(pos - closing.length, pos - closing.length);
    ic.endBatchEdit();
    // 撤销时按整体回退;记录两字符长度
    this.undoManager.record(opening + closing);
  }

  hasTextAfterCursor(): boolean {
    const ic = this.ime.inputClient();
    if (ic === undefined) return false;
    return ic.getTextAfterCursor(1).length > 0;
  }

  textBeforeCursor(maxChars: number): string {
    const ic = this.ime.inputClient();
    if (ic === undefined) return '';
    return ic.getTextBeforeCursor(maxChars);
  }

  onMoveCursor(dx: number): void {
    const ic = this.ime.inputClient();
    if (ic === undefined) return;
    if (dx === 0) return;
    const pos = ic.getTextBeforeCursor(IME_TEXT_MAX).length;
    const after = ic.getTextAfterCursor(IME_TEXT_MAX).length;
    let target = pos + dx;
    if (target < 0) target = 0;
    if (target > pos + after) target = pos + after;
    ic.setSelection(target, target);
  }

  onDeleteBeforeCursor(): void {
    const ic = this.ime.inputClient();
    if (ic === undefined) return;
    const selected = ic.getSelectedText();
    if (selected.length > 0) {
      ic.commitText('');
    } else {
      ic.deleteSurroundingText(1, 0);
    }
  }

  onEnter(): void {
    this.composingBridge.clear();
    const ic = this.ime.inputClient();
    if (ic === undefined) return;
    switch (this.editorAction.action) {
      case EditorInfoAction.SEARCH:
        ic.performEditorAction(EditorInfoAction.SEARCH);
        break;
      case EditorInfoAction.SEND:
        ic.performEditorAction(EditorInfoAction.SEND);
        break;
      case EditorInfoAction.GO:
        ic.performEditorAction(EditorInfoAction.GO);
        break;
      case EditorInfoAction.DONE:
        ic.performEditorAction(EditorInfoAction.DONE);
        break;
      case EditorInfoAction.NEXT:
        ic.performEditorAction(EditorInfoAction.NEXT);
        break;
      case EditorInfoAction.PREVIOUS:
        ic.performEditorAction(EditorInfoAction.PREVIOUS);
        break;
      case EditorInfoAction.NEWLINE: {
        // commitText 失败时降级为回车键事件(Android sendKeyEvent(KEYCODE_ENTER) 等价)
        if (!ic.commitText('\n')) {
          ic.sendEnterKeyEvent();
        }
        break;
      }
      default:
        break;
    }
  }

  onReturnToVoice(): void {
    this.ime.requestExitTypingMode();
  }

  onKeyboardMicStart(): void { /* 由 KeyboardMicCoordinator 处理 */
  }

  onKeyboardMicStop(): void { /* 由 KeyboardMicCoordinator 处理 */
  }

  isChineseModeDefault(): boolean {
    return this.preferences.chineseMode;
  }

  persistChineseMode(chinese: boolean): void {
    this.preferences.chineseMode = chinese;
  }

  inputLangDefault(): InputLang {
    return InputLang.fromCode(this.preferences.inputLang);
  }

  persistInputLang(lang: InputLang): void {
    this.preferences.inputLang = lang.code;
    // 中英偏好联动(向后兼容旧逻辑读取点);俄/韩不动 chineseMode
    if (lang === InputLang.ZH || lang === InputLang.EN) this.preferences.chineseMode = lang === InputLang.ZH;
  }

  /** App 界面语言 → 语言组(中英组含粤语/繁体)与组默认输入语种。 */
  private appLangGroup(): LangGroupInfo {
    const lang = MobileStrings.currentLanguage();
    if (lang === MobileLanguage.RU) return { group: 'ru', def: InputLang.RU };
    if (lang === MobileLanguage.KO) return { group: 'ko', def: InputLang.KO };
    if (lang === MobileLanguage.EN) return { group: 'zhen', def: InputLang.EN };
    return { group: 'zhen', def: InputLang.ZH }; // zh / zh-Hant / yue 均属中文
  }

  groupDefaultLang(): InputLang {
    return this.appLangGroup().def;
  }

  consumeLangGroupChange(): boolean {
    const info = this.appLangGroup();
    const last = this.preferences.langGroup;
    this.preferences.langGroup = info.group;
    // 首次(无记录):中英组不算切换;俄/韩界面首启也要落到对应语种键盘
    if (last === undefined && info.group !== 'zhen') {
      this.preferences.inputLang = info.def.code;
      return true;
    }
    // 组内互切(中英互换界面语言)不清暂存
    if (last === undefined || last === info.group) return false;
    // 跨组切换:清空暂存、恢复初始化——输入语种重置为新组默认
    // (zh/繁/粤界面→中文,en界面→英文,ru→俄语,ko→韩语),中英偏好同步对齐
    this.preferences.inputLang = info.def.code;
    if (info.def === InputLang.ZH || info.def === InputLang.EN) {
      this.preferences.chineseMode = info.def === InputLang.ZH;
    }
    return true;
  }

  isNineGridDefault(): boolean {
    return this.preferences.nineGrid;
  }

  persistNineGrid(nine: boolean): void {
    this.preferences.nineGrid = nine;
  }

  onKeyFeedback(): void {
    this.ime.performKeyHaptic();
  }

  localize(key: KbStr): string {
    switch (key) {
      case KbStr.RETURN_VOICE:
        return MobileStrings.returnVoice();
      case KbStr.SPACE:
        return MobileStrings.spaceKey();
      case KbStr.CH:
        return MobileStrings.imeChineseLabel();
      case KbStr.EN:
        return MobileStrings.imeEnglishLabel();
      case KbStr.NINEGRID:
        return MobileStrings.nineGridLabel();
      case KbStr.QWERTY:
        return MobileStrings.qwertyLabel();
      case KbStr.SYMBOL:
        return MobileStrings.symbolKeyLabel();
      case KbStr.SWITCH_QWERTY:
        return MobileStrings.switchQwertyLabel();
      case KbStr.PINYIN:
        return MobileStrings.pinyinKeyLabel();
      case KbStr.ABC:
        return MobileStrings.abcKeyLabel();
      case KbStr.SYLLABLE:
        return MobileStrings.syllableSepKey();
      case KbStr.UNDO:
        return MobileStrings.undo();
      default:
        return '';
    }
  }

  enterKeyLabel(): string {
    return this.editorAction.label;
  }

  isPasswordField(): boolean {
    return this.editorAction.isPassword;
  }

  isNumericField(): boolean {
    return this.editorAction.isNumeric;
  }

  isEnglishField(): boolean {
    return this.editorAction.isEnglish;
  }

  isMicAvailable(): boolean {
    return this.ime.isLoggedIn();
  }

  canRememberTypingMode(): boolean {
    return this.preferences.rememberTypingMode;
  }

  lastModeKeyboard(): boolean {
    return this.preferences.lastModeKeyboard;
  }

  setLastModeKeyboard(value: boolean): void {
    this.preferences.lastModeKeyboard = value;
  }

  fuzzySettings(): PinyinFuzzySettings {
    return this.preferences.fuzzySettings();
  }

  recordRecentEmoji(emoji: string): void {
    this.preferences.recordRecentEmoji(emoji);
  }

  recentEmojis(): string[] {
    return this.preferences.recentEmojis();
  }

  recordRecentSymbol(symbol: string): void {
    this.preferences.recordRecentSymbol(symbol);
  }

  recentSymbols(): string[] {
    return this.preferences.recentSymbols();
  }

  // 密码框不读剪贴板(隐私)
  clipboardHistory(): string[] {
    return this.isPasswordField() ? [] : this.clipboardStore.snapshotAndGet();
  }

  quickPhrases(): string[] {
    return this.isPasswordField() ? [] : this.clipboardStore.quickPhrases();
  }

  removeClipboardItem(item: string): void {
    this.clipboardStore.removeHistory(item);
  }

  clearClipboard(): void {
    this.clipboardStore.clearHistory();
  }

  updateComposingPreview(text: string): void {
    this.composingBridge.update(text);
  }

  clearComposingPreview(): void {
    this.composingBridge.clear();
  }

  showStatus(message?: string): void {
    if (this.statusCallback !== undefined) this.statusCallback(message);
  }

  setInputBlocked(blocked: boolean): void {
    if (this.inputBlockedCallback !== undefined) this.inputBlockedCallback(blocked);
  }

  canUndo(): boolean {
    return this.undoManager.canUndo();
  }

  undoLastCommit(): void {
    const last = this.undoManager.pop();
    if (last === undefined) return;
    const ic = this.ime.inputClient();
    if (ic === undefined) return;
    ic.deleteSurroundingText(last.length, 0);
    // 不再弹"已撤销"状态提示:它会让候选栏多出一行、顶高输入面板,体验差
  }

  notifyEngineState(state: PinyinLoadState, detail?: string): void {
    let msg: string | undefined;
    switch (state) {
      case PinyinLoadState.LOADING:
        msg = MobileStrings.pinyinDictLoading();
        break;
      case PinyinLoadState.FAILED:
        msg = detail ?? MobileStrings.pinyinDictFailed();
        break;
      case PinyinLoadState.READY:
        msg = undefined;
        break;
      case PinyinLoadState.IDLE:
        msg = undefined;
        break;
      default:
        msg = undefined;
        break;
    }
    this.showStatus(msg);
    this.setInputBlocked(state === PinyinLoadState.LOADING || state === PinyinLoadState.FAILED);
  }
}
