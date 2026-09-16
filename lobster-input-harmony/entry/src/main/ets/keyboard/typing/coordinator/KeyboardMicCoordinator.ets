// 对齐 Android: keyboard/typing/coordinator/KeyboardMicCoordinator.kt
import { MobileStrings } from '../../../core/locale/MobileStrings';
import { TypingKeyboardViewApi } from '../KeyModels';
import { TypingImeContext } from './TypingImeContext';
import { TypingSessionHost } from './TypingSessionHost';

/**
 * 键盘内流式麦克风能力契约(Android KeyboardRealtimeMic 对应,
 * 由 IME 服务层的流式识别实现注入)。
 */
export interface KeyboardRealtimeMicApi {
  /** 启动流式识别(auth 为鉴权头)。 */
  start(auth: string): void;

  /** 停止录音并结束识别。 */
  stop(): void;
}

/**
 * 键盘内流式麦克风协调器:登录/积分/权限校验、错误提示、与按键互斥。
 */
export class KeyboardMicCoordinator {
  private readonly ime: TypingImeContext;
  private readonly sessionHost: TypingSessionHost;
  private readonly keyboardMic: KeyboardRealtimeMicApi;
  typingView?: TypingKeyboardViewApi;

  constructor(ime: TypingImeContext, sessionHost: TypingSessionHost, keyboardMic: KeyboardRealtimeMicApi) {
    this.ime = ime;
    this.sessionHost = sessionHost;
    this.keyboardMic = keyboardMic;
  }

  isActive(): boolean {
    return this.ime.isMicRecording();
  }

  onRecordStart(): void {
    const ctx = this.ime.hostContext();
    if (this.ime.isMicRecording()) return;
    if (!this.ime.isLoggedIn()) {
      this.typingView?.stopMicRecordingUI();
      this.sessionHost.showStatus(MobileStrings.loginRequired());
      this.ime.requestExitTypingMode();
      return;
    }
    if (!this.ime.hasRecordPermission()) {
      this.typingView?.stopMicRecordingUI();
      this.sessionHost.showStatus(MobileStrings.micPermission());
      return;
    }
    this.ime.ensureInputAvailable(() => {
      if (this.ime.isCreditsBlocked()) {
        this.typingView?.stopMicRecordingUI();
        this.sessionHost.showStatus(MobileStrings.creditsExhausted());
        return;
      }
      const auth = this.ime.authHeader();
      if (auth === undefined) {
        this.typingView?.stopMicRecordingUI();
        this.sessionHost.showStatus(MobileStrings.loginRequired());
        return;
      }
      this.sessionHost.clearComposingPreview();
      // 不再整盘阻塞按键:录音中按任意键即结束识别(由打字键盘视图拦截)
      this.keyboardMic.start(auth);
    });
  }

  onRecordEnd(): void {
    this.keyboardMic.stop();
  }

  onMicError(message: string): void {
    this.typingView?.stopMicRecordingUI();
    const text = message.trim().length > 0 ? message : MobileStrings.keyboardMicFailed();
    this.sessionHost.showStatus(text);
  }

  onMicActiveChanged(active: boolean): void {
    if (!active) this.typingView?.stopMicRecordingUI();
  }
}
