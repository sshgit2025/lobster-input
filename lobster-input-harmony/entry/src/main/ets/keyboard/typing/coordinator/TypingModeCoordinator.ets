// 对齐 Android: keyboard/typing/coordinator/TypingModeCoordinator.kt
// 差异:Android createTypingView(Context) 直接 new View;鸿蒙 UI 为 ArkUI 声明式组件,
// 由 IME 服务层创建视图后通过 typingView setter 注入(接口 TypingKeyboardViewApi)。
import { PinyinEngine } from '../../pinyin/PinyinEngine';
import { PinyinLoadState } from '../../pinyin/PinyinLoadState';
import { TypingKeyboardViewApi } from '../KeyModels';
import { ComposingTextBridge } from '../composing/ComposingTextBridge';
import { KeyboardMicCoordinator } from './KeyboardMicCoordinator';
import { TypingSessionHost } from './TypingSessionHost';

/**
 * 打字模式总协调器:组装 SessionHost、ComposingBridge、MicCoordinator 与打字键盘视图。
 */
export class TypingModeCoordinator {
  private readonly sessionHost: TypingSessionHost;
  private readonly composingBridge: ComposingTextBridge;
  private readonly micCoordinator: KeyboardMicCoordinator;
  readonly engine: PinyinEngine;

  private _typingView?: TypingKeyboardViewApi;

  get typingView(): TypingKeyboardViewApi | undefined {
    return this._typingView;
  }

  set typingView(value: TypingKeyboardViewApi | undefined) {
    this._typingView = value;
    this.micCoordinator.typingView = value;
  }

  private _active: boolean = false;

  get active(): boolean {
    return this._active;
  }

  private readonly loadListener: (state: PinyinLoadState, detail: string | null) => void =
    (state: PinyinLoadState, detail: string | null) => {
      this._typingView?.onEngineLoadState(state, detail ?? undefined);
      this.sessionHost.notifyEngineState(state, detail ?? undefined);
    };

  constructor(sessionHost: TypingSessionHost, composingBridge: ComposingTextBridge,
    micCoordinator: KeyboardMicCoordinator, engine: PinyinEngine) {
    this.sessionHost = sessionHost;
    this.composingBridge = composingBridge;
    this.micCoordinator = micCoordinator;
    this.engine = engine;
    this.engine.addLoadListener(this.loadListener);
    this.engine.setFuzzy(this.sessionHost.fuzzySettings());
  }

  enter(): void {
    this._active = true;
    this.sessionHost.refreshEditorAction();
    this.engine.setFuzzy(this.sessionHost.fuzzySettings());
    this._typingView?.resetComposing();
    this._typingView?.refreshEnterKey();
  }

  exit(): void {
    this._active = false;
    this.composingBridge.clear();
  }

  onStartInputView(): void {
    this.sessionHost.refreshEditorAction();
    this._typingView?.refreshEnterKey();
    // 每次拉起输入法都清理上次未完成的 composing/候选(失焦再聚焦不该残留);与"记住模式"无关
    this._typingView?.resetComposing();
  }

  /** 键盘窗口收起(会话结束):清除会话级模式粘性(数字页粘性/英文框自动切换)。 */
  onSessionEnd(): void {
    this._typingView?.onSessionEnd();
  }

  resetComposing(): void {
    this._typingView?.resetComposing();
  }
}
