// 对齐 Android: keyboard/typing/coordinator/TypingImeContext.kt
// Android InputConnection/EditorInfo → 鸿蒙 ImeClientApi / inputMethodEngine.EditorAttribute。
import { common } from '@kit.AbilityKit';
import { inputMethodEngine } from '@kit.IMEKit';
import { ImeClientApi } from '../ImeClientApi';

/**
 * 打字模式所需的 IME 宿主能力(依赖倒置,避免 Typing 模块直接耦合 IME 服务实现)。
 * 由 IME 服务层(ets/ime/**)实现。
 */
export interface TypingImeContext {
  /** 宿主上下文(Android androidContext() 对应;用于本地化/偏好等)。 */
  hostContext(): common.Context;

  /** 当前输入连接(Android inputConnection() 对应;无焦点时返回 undefined)。 */
  inputClient(): ImeClientApi | undefined;

  /** 当前输入框属性(Android editorInfo() 对应)。 */
  editorAttribute(): inputMethodEngine.EditorAttribute | undefined;

  isLoggedIn(): boolean;

  authHeader(): string | undefined;

  isCreditsBlocked(): boolean;

  ensureInputAvailable(onReady: () => void): void;

  showTypingMessage(message: string): void;

  performKeyHaptic(): void;

  refreshKeyboardUi(): void;

  onTypingModeChanged(active: boolean): void;

  isMicRecording(): boolean;

  requestExitTypingMode(): void;

  hasRecordPermission(): boolean;
}

export enum TypingBlockedReason {
  LOGIN_REQUIRED,
  CREDITS_EXHAUSTED,
  MIC_PERMISSION
}
