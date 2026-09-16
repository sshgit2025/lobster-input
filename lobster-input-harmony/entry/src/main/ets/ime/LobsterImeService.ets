/**
 * LobsterImeService.ets — 安卓 keyboard/LobsterIME.kt(输入法服务主体,3221 行)的 HarmonyOS 完整移植。
 *
 * 架构差异说明(业务逻辑逐段对齐,不删功能):
 *  - InputMethodService → InputMethodExtensionAbility(入口在 LobsterImeAbility.ets)+ 本单例服务;
 *  - InputConnection → InputClientAdapter(内部组合缓冲模拟 setComposingText,见该文件头注释);
 *  - onCreateInputView 的整棵视图树 → UI 层 KeyboardRoot 组件(ets/ime/view/KeyboardRoot.ets),
 *    本服务实现 ImeBusDelegate(UI → 逻辑回调,bindDelegate)并经 ImeBus 具名方法驱动渲染
 *    (rebuildKeyboard / setPanelMode / setOrbState / showStatus / updateMicLevel...);
 *  - onStartInputView/onFinishInputView/onWindowHidden → inputMethodAbility 的
 *    inputStart / inputStop / keyboardShow / keyboardHide 事件映射(见 registerImeEngineListeners);
 *  - Hilt/懒注入 → 直接 import 单例或显式构造;协程 scope.launch → async 方法;
 *    Handler.postDelayed → setTimeout/setInterval;synchronized 锁在单线程 JS 下移除(保留注释)。
 */
import { inputMethodEngine, inputMethod, InputMethodSubtype, InputMethodExtensionContext } from '@kit.IMEKit';
import { common, Want, abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import { display } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FileLog } from '../core/log/FileLog';
import { Logger } from '../core/log/Logger';
import { ApiConfig } from '../core/network/ApiConfig';
import { ApiService } from '../core/network/ApiService';
import { RealtimeAsrErrorKind, RealtimeAsrWebSocketClient } from '../core/network/RealtimeAsrWebSocketClient';
import { AudioRecorder } from '../core/audio/AudioRecorder';
import { RealtimeAudioStreamer } from '../core/audio/RealtimeAudioStreamer';
import { MobileHistoryStore } from '../core/history/MobileHistoryStore';
import { MobileStrings } from '../core/locale/MobileStrings';
import { AppPreferences } from '../data/local/AppPreferences';
import { AuthSession } from '../data/local/AuthSession';
import {
  ActionType,
  AndroidQuickAction,
  AndroidQuickActionRequest,
  ApiErrorResponse,
  ApiException,
  ApiExceptionKind,
  AudioProcessResponse,
  parseApiErrorResponse,
  PersonaItem,
  PersonaPrompts,
  PersonaUpdateBody,
  TextProcessRequest,
  TextQuickActionResponse
} from '../data/model/ApiModels';
import { KeyboardRealtimeMic, KeyboardRealtimeMicCallbacks } from '../keyboard/KeyboardRealtimeMic';
import { TypewriterReveal } from '../keyboard/TypewriterReveal';
import { Candidate } from '../keyboard/pinyin/PinyinEngine';
import { DictionaryLoader } from '../keyboard/pinyin/DictionaryLoader';
import { PinyinLoadState } from '../keyboard/pinyin/PinyinLoadState';
import { SymbolData } from '../keyboard/typing/SymbolData';
import { ImeClientApi } from '../keyboard/typing/ImeClientApi';
import { KeyboardController } from '../keyboard/typing/KeyboardController';
import { KeyboardLayoutFactory } from '../keyboard/typing/KeyboardLayoutFactory';
import { KeySpec, KeyType, TypingKeyboardViewApi } from '../keyboard/typing/KeyModels';
import { ComposingTextBridge } from '../keyboard/typing/composing/ComposingTextBridge';
import { TypingUndoManager } from '../keyboard/typing/composing/TypingUndoManager';
import { KeyboardMicCoordinator, KeyboardRealtimeMicApi } from '../keyboard/typing/coordinator/KeyboardMicCoordinator';
import { TypingImeContext } from '../keyboard/typing/coordinator/TypingImeContext';
import { TypingModeCoordinator } from '../keyboard/typing/coordinator/TypingModeCoordinator';
import { TypingPreferences } from '../keyboard/typing/coordinator/TypingPreferences';
import { TypingSessionHost } from '../keyboard/typing/coordinator/TypingSessionHost';
import { ImeBus, ImeBusDelegate, ImePanelMode, ImeVoicePanelUiState } from './ImeBus';
import { InputClientAdapter } from './InputClientAdapter';

const TAG = 'LobsterImeService';

// ==================== 枚举与常量(对应 LobsterIME.kt 同名定义) ====================

enum Operation {
  TRANSCRIBE = 'transcribe',
  REWRITE = 'rewrite'
}

/**
 * 录音捕获模式 —— 录音控制层唯一的权威同步状态。
 * 所有手势/按钮做决策时都以它为准,从根本上消除状态竞态。
 * - IDLE:     无录音。
 * - SYNC:     同步录音(单击麦克风、或点「指令」触发;再次单击麦克风停止并送识别)。
 *             与「实时流式 ASR」开关完全无关 ——「指令」永远走这条路径。
 * - REALTIME: 实时流式录音(长按麦克风触发;松手停止)。仅在开关开启、且空闲时由长按发起。
 */
enum CaptureMode {
  IDLE = 'idle',
  SYNC = 'sync',
  REALTIME = 'realtime'
}

enum BlockedReason {
  LOGIN_REQUIRED = 'login_required',
  CREDITS_EXHAUSTED = 'credits_exhausted'
}

enum RewriteTarget {
  NONE = 'none',
  SELECTED_TEXT = 'selected_text',
  LAST_INSERTED = 'last_inserted'
}

enum VoiceCommand {
  NEWLINE = 'newline',
  BACKSPACE = 'backspace',
  UNDO_LAST = 'undo_last'
}

enum PersonaModule {
  TRANSCRIBE = 'transcribe',
  REWRITE = 'rewrite'
}

const PREF_HAND_LAYOUT = 'ime_right_hand_layout';
const PREF_FAST_MODE = 'ime_fast_mode_enabled';
const BACKSPACE_REPEAT_INTERVAL_MS = 58;
/** 安卓 ViewConfiguration.getLongPressTimeout() 的等价常量(默认 400ms)。 */
const LONG_PRESS_TIMEOUT_MS = 400;
const REALTIME_AUDIO_BUFFER_LIMIT_BYTES = 2500000;
const KEYBOARD_PANEL_HEIGHT_DP = 286;
const PERSONA_PANEL_HEIGHT_DP = 266;
const MAX_SURROUNDING_TEXT_DELETE_CHARS = 100000;

/** 输入不可用异常(登录失效/积分耗尽),对应 Kotlin InputUnavailableException。 */
class InputUnavailableException extends Error {
  reason: BlockedReason;

  constructor(reason: BlockedReason, message: string) {
    super(message);
    this.reason = reason;
  }
}

/** API 失败信息归一化结果(HTTP 状态码 + 业务错误码 + 文案)。 */
interface ApiFailureInfo {
  statusCode: number;
  code: string | null;
  message: string | null;
}

/**
 * 语音面板完整状态快照(原并行移植期 ImeUiState 的本地等价定义):
 * refreshKeyboardUi 每次拷贝为 ImeBus.ImeVoicePanelUiState 响应式快照,
 * 驱动 VoicePanelView(快捷指令行/符号板/人设板/不可用面板)全量刷新。
 */
export interface ImeVoicePanelState {
  typingActive: boolean;
  loggedIn: boolean;
  unavailable: boolean;
  blockedReasonCredits: boolean;
  statusText: string;
  isError: boolean;
  recording: boolean;
  processing: boolean;
  accountStatusLoading: boolean;
  recordEnabled: boolean;
  audioLevel: number;
  undoEnabled: boolean;
  restoreEnabled: boolean;
  rewriteEnabled: boolean;
  fastModeEnabled: boolean;
  realtimeRecognitionEnabled: boolean;
  rightHandLayout: boolean;
  symbolPanelVisible: boolean;
  personaPanelVisible: boolean;
  voiceSymbolCategory: string;
  recentSymbols: string[];
  personas: PersonaItem[];
  personaDetail: PersonaItem | null;
  personasLoading: boolean;
  personasRefreshing: boolean;
  pendingPersonaActionId: string | null;
}

function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

function clamp01(v: number): number {
  if (v < 0) {
    return 0;
  }
  if (v > 1) {
    return 1;
  }
  return v;
}

function isPromptConfigured(prompt: string | null | undefined): boolean {
  return prompt !== null && prompt !== undefined && prompt.trim().length > 0;
}

function operationApiValue(op: Operation): string {
  return op === Operation.REWRITE ? 'rewrite' : 'transcribe';
}

// ==================== 打字层宿主上下文(对应 Kotlin typingImeContext 匿名对象) ====================

/**
 * 打字模式所需的 IME 宿主能力实现(依赖倒置,Typing 模块不直接耦合本服务)。
 * ArkTS 不支持带方法的匿名对象,故落为顶层类。
 */
class TypingImeContextImpl implements TypingImeContext {
  private svc: LobsterImeService;

  constructor(svc: LobsterImeService) {
    this.svc = svc;
  }

  /** 宿主 Context(对应 Kotlin androidContext())。 */
  hostContext(): common.Context {
    return this.svc.requireContext();
  }

  inputClient(): ImeClientApi | undefined {
    return this.svc.clientAdapter ?? undefined;
  }

  editorAttribute(): inputMethodEngine.EditorAttribute | undefined {
    return this.svc.currentEditorInfo ?? undefined;
  }

  isLoggedIn(): boolean {
    return this.svc.authHeaderOrNull() !== null;
  }

  authHeader(): string | undefined {
    return this.svc.authHeaderOrNull() ?? undefined;
  }

  isCreditsBlocked(): boolean {
    return this.svc.isCreditsBlockedNow();
  }

  ensureInputAvailable(onReady: () => void): void {
    this.svc.ensureInputAvailableForAction(onReady);
  }

  showTypingMessage(message: string): void {
    this.svc.busTypingStatus(message);
  }

  performKeyHaptic(): void {
    this.svc.performKeyHaptic();
  }

  refreshKeyboardUi(): void {
    this.svc.refreshKeyboardUi();
  }

  onTypingModeChanged(active: boolean): void {
    // 对齐安卓:空实现
  }

  isMicRecording(): boolean {
    return this.svc.isKeyboardMicActive();
  }

  requestExitTypingMode(): void {
    this.svc.exitKeyboardMode();
  }

  hasRecordPermission(): boolean {
    return this.svc.checkRecordPermission();
  }
}

/** 键盘内流式麦克风回调(对应 Kotlin keyboardMicCallbacks 匿名对象)。 */
class KeyboardRealtimeMicCallbacksImpl implements KeyboardRealtimeMicCallbacks {
  private svc: LobsterImeService;

  constructor(svc: LobsterImeService) {
    this.svc = svc;
  }

  language(): string {
    return MobileStrings.currentLanguage().code;
  }

  /** 契约签名:返回原生 InputClient(键盘内流式识别直接操作原生客户端做预览替换)。 */
  inputConnection(): inputMethodEngine.InputClient | null {
    return this.svc.rawInputClient;
  }

  onActiveChanged(active: boolean): void {
    this.svc.onKeyboardMicActiveChanged(active);
  }

  onError(kind: RealtimeAsrErrorKind, message: string): void {
    this.svc.onKeyboardMicError(kind, message);
  }
}

/**
 * KeyboardRealtimeMic → KeyboardMicCoordinator 的能力契约桥
 * (ArkTS 无结构化类型,KeyboardRealtimeMic 未声明 implements KeyboardRealtimeMicApi,
 * 用最小包装类做名义适配,不改契约文件)。
 */
class KeyboardRealtimeMicApiImpl implements KeyboardRealtimeMicApi {
  private mic: KeyboardRealtimeMic;

  constructor(mic: KeyboardRealtimeMic) {
    this.mic = mic;
  }

  start(auth: string): void {
    this.mic.start(auth);
  }

  stop(): void {
    this.mic.stop();
  }
}

/**
 * TypingKeyboardViewApi 适配器:安卓侧 typingView 是真实 View,鸿蒙侧 UI 由 ImeBus 状态驱动,
 * 视图能力回落到 KeyboardController(逻辑复位)与 ImeBus(渲染刷新)。
 */
class TypingKeyboardViewAdapter implements TypingKeyboardViewApi {
  private controller: KeyboardController;

  constructor(controller: KeyboardController) {
    this.controller = controller;
  }

  /** 复位组合串/候选(controller.reset 内部会 rebuildKeyboard + refreshCandidates)。 */
  resetComposing(): void {
    this.controller.reset();
  }

  /** Enter 动作变化 → 重建键区(rebuildKeyboard 会重新代入 controller.enterKeyLabel())。 */
  refreshEnterKey(): void {
    ImeBus.getInstance().rebuildKeyboard();
  }

  onSessionEnd(): void {
    this.controller.onSessionEnd();
  }

  onEngineLoadState(state: PinyinLoadState, detail?: string): void {
    this.controller.onEngineLoadState(state, detail);
  }

  stopMicRecordingUI(): void {
    ImeBus.getInstance().stopMicRecordingUI();
  }
}

/**
 * ImeBusDelegate 实现(UI → 逻辑层对接):
 * 控制器查询/动作转发 KeyboardController;麦克风走 KeyboardMicCoordinator;
 * 录音球手势与触感反馈走服务本体(对应安卓各 View 的 listener 装配)。
 */
class ImeBusDelegateImpl implements ImeBusDelegate {
  private svc: LobsterImeService;

  constructor(svc: LobsterImeService) {
    this.svc = svc;
  }

  private controller(): KeyboardController | null {
    return this.svc.typingControllerOrNull();
  }

  buildKeyRows(): KeySpec[][] {
    return this.svc.buildKeyRowsForUi();
  }

  // ---- 控制器查询 ----

  isToolsPage(): boolean {
    return this.controller()?.isToolsPage() ?? false;
  }

  isEmojiPage(): boolean {
    return this.controller()?.isEmojiPage() ?? false;
  }

  isClipPage(): boolean {
    return this.controller()?.isClipPage() ?? false;
  }

  isSymBoardPage(): boolean {
    return this.controller()?.isSymBoardPage() ?? false;
  }

  isChineseMode(): boolean {
    return this.controller()?.isChineseMode() ?? true;
  }

  isNineGrid(): boolean {
    return this.controller()?.layoutState().nineGrid ?? false;
  }

  currentLangCode(): string {
    return this.controller()?.currentLang().code ?? 'zh';
  }

  isShiftActive(): boolean {
    return this.controller()?.isShiftActive() ?? false;
  }

  isCapsLock(): boolean {
    return this.controller()?.isCapsLock() ?? false;
  }

  isPasswordField(): boolean {
    return this.controller()?.isPasswordField() ?? false;
  }

  isMicAvailable(): boolean {
    return this.controller()?.isMicAvailable() ?? false;
  }

  canUndo(): boolean {
    return this.controller()?.canUndo() ?? false;
  }

  returnVoiceText(): string {
    return this.controller()?.returnVoiceText() ?? '';
  }

  layoutSwitchText(): string {
    return this.controller()?.layoutSwitchText() ?? '';
  }

  // ---- 子页数据 ----

  recentEmojis(): string[] {
    return this.controller()?.recentEmojis() ?? [];
  }

  recentSymbols(): string[] {
    return this.controller()?.recentSymbols() ?? [];
  }

  clipboardHistory(): string[] {
    return this.controller()?.clipboardHistory() ?? [];
  }

  quickPhrases(): string[] {
    return this.controller()?.quickPhrases() ?? [];
  }

  // ---- 动作 ----

  handleKey(spec: KeySpec): void {
    this.controller()?.handleKey(spec);
  }

  handleSimpleKey(type: KeyType): void {
    this.controller()?.handleKey(new KeySpec(type));
  }

  handleLongPress(spec: KeySpec): void {
    this.controller()?.handleLongPress(spec);
  }

  onDeletePressDown(): void {
    this.controller()?.onDeletePressDown();
  }

  onDeletePressUp(): void {
    this.controller()?.onDeletePressUp();
  }

  moveCursor(steps: number): void {
    this.controller()?.moveCursor(steps);
  }

  selectCandidate(c: Candidate): void {
    this.controller()?.selectCandidate(c);
  }

  forgetCandidate(c: Candidate): void {
    this.controller()?.forgetCandidate(c);
  }

  selectT9Pinyin(pinyin: string): void {
    this.controller()?.selectT9Pinyin(pinyin);
  }

  selectEmoji(emoji: string): void {
    this.controller()?.selectEmoji(emoji);
  }

  selectClip(text: string): void {
    this.controller()?.selectClip(text);
  }

  selectSymbol(symbol: string): void {
    this.controller()?.selectSymbol(symbol);
  }

  removeClipboardItem(item: string): void {
    this.controller()?.removeClipboardItem(item);
  }

  clearClipboard(): void {
    this.controller()?.clearClipboard();
  }

  runTool(tool: string): void {
    this.controller()?.runTool(tool);
  }

  openTools(): void {
    this.controller()?.openTools();
  }

  returnToVoice(): void {
    this.controller()?.returnToVoice();
  }

  refreshCandidates(): void {
    this.controller()?.refreshCandidates();
  }

  // ---- 麦克风(候选栏,KeyboardMicCoordinator)----

  isMicActive(): boolean {
    return this.svc.isKeyboardMicActive();
  }

  onMicRecordStart(): void {
    this.svc.micCoordinatorOrNull()?.onRecordStart();
  }

  onMicRecordEnd(): void {
    this.svc.micCoordinatorOrNull()?.onRecordEnd();
  }

  // ---- 录音球(语音面板)----
  // RecordOrbView 同时上报 touch(Down/Up)与 click:Down 走长按拦截决策,
  // Up 只收尾"被拦截的实时长按"(onMicPressCancel 语义),单击统一由 click(onOrbTap)触发,
  // 与安卓 OnTouchListener 返回 true 消费事件后 click 不再触发的行为等价。

  onOrbTap(): void {
    this.svc.onMicTap();
  }

  onOrbTouchDown(): void {
    this.svc.onMicPressDown();
  }

  onOrbTouchUp(): void {
    this.svc.onMicPressCancel();
  }

  // ---- 语音面板动作(VoicePanelView 各按钮 → 服务「语音面板动作入口」公开方法)----

  enterKeyboardMode(): void {
    this.svc.enterKeyboardMode();
  }

  toggleHandLayout(): void {
    this.svc.toggleHandLayout();
  }

  togglePersonaPanel(): void {
    this.svc.togglePersonaPanel();
  }

  toggleSymbolPanel(): void {
    this.svc.toggleSymbolPanel();
  }

  commitTextWithHistory(text: string): void {
    this.svc.commitTextWithHistory(text);
  }

  onBackspacePressDown(): void {
    this.svc.onBackspacePressDown();
  }

  onBackspacePressUp(): void {
    this.svc.onBackspacePressUp();
  }

  onBackspacePressCancel(): void {
    this.svc.onBackspacePressCancel();
  }

  handleNewline(): void {
    this.svc.handleNewline();
  }

  handleUndo(): void {
    this.svc.handleUndo();
  }

  handleRewrite(): void {
    this.svc.handleRewrite();
  }

  handleQuickAction(action: AndroidQuickAction): void {
    this.svc.handleQuickAction(action);
  }

  handleClearInputText(): void {
    this.svc.handleClearInputText();
  }

  toggleFastMode(): void {
    this.svc.toggleFastMode();
  }

  handleRestoreVoiceText(): void {
    this.svc.handleRestoreVoiceText();
  }

  selectSymbolCategory(id: string): void {
    this.svc.selectSymbolCategory(id);
  }

  commitSymbol(value: string): void {
    this.svc.commitSymbol(value);
  }

  showInputMethodPicker(): void {
    this.svc.showInputMethodPicker();
  }

  openMainApp(): void {
    this.svc.openMainApp();
  }

  refreshPersonas(): void {
    this.svc.refreshPersonas();
  }

  openPersonaDetail(id: string): void {
    this.svc.openPersonaDetail(id);
  }

  onPersonaBack(): void {
    this.svc.onPersonaBack();
  }

  onPersonaActivate(id: string): void {
    this.svc.onPersonaActivate(id);
  }

  onPersonaToggleModule(id: string, module: string): void {
    this.svc.onPersonaToggleModule(id, module);
  }

  // ---- 反馈 ----

  performHaptic(kind: string): void {
    this.svc.performKeyHaptic();
  }
}

// ==================== 服务主体 ====================

export class LobsterImeService {
  private static instance: LobsterImeService | null = null;

  static getInstance(): LobsterImeService {
    if (LobsterImeService.instance === null) {
      LobsterImeService.instance = new LobsterImeService();
    }
    return LobsterImeService.instance;
  }

  private constructor() {
    this.realtimeTypewriter = new TypewriterReveal((shown: string): void => {
      this.applyRealtimePreview(shown);
    });
  }

  // ---------- 运行时句柄 ----------
  private context: common.Context | null = null;
  private panel: inputMethodEngine.Panel | null = null;
  private kbController: inputMethodEngine.KeyboardController | null = null;
  clientAdapter: InputClientAdapter | null = null;
  /** 原生 InputClient(KeyboardRealtimeMicCallbacks 契约需要原生句柄做预览替换)。 */
  rawInputClient: inputMethodEngine.InputClient | null = null;
  currentEditorInfo: inputMethodEngine.EditorAttribute | null = null;

  // ---------- 依赖(Kotlin lateinit/lazy → 显式构造) ----------
  private audioRecorder: AudioRecorder | null = null;
  private realtimeStreamer: RealtimeAudioStreamer | null = null;
  private keyboardMic: KeyboardRealtimeMic | null = null;
  private historyStore: MobileHistoryStore | null = null;
  private prefs: AppPreferences | null = null;

  // ---------- 语音模式状态(与 Kotlin 字段一一对应) ----------
  private captureMode: CaptureMode = CaptureMode.IDLE;
  private isProcessing: boolean = false;
  private audioLevel: number = 0;
  private statusText: string = '';
  private errorMessage: string = '';
  private lastInsertedText: string = '';
  private voiceRestoreText: string = '';
  private operationTextHistory: string[] = [];
  private recordingRemainingSec: number = ApiConfig.DEFAULT_MAX_DURATION_SEC;
  private pendingOperation: Operation = Operation.TRANSCRIBE;
  private pendingRewriteOriginal: string = '';
  private pendingRewriteTarget: RewriteTarget = RewriteTarget.NONE;
  private fastModeEnabled: boolean = false;
  private realtimeRecognitionEnabled: boolean = false;
  /** 实时收尾流程(松手后上传/取最终结果)是否在进行,用于防重入与预览门控。 */
  private realtimeFinishing: boolean = false;
  /** 麦克风长按手势当前是否按住(用于实时录音的按下/松手配对)。 */
  private realtimePressActive: boolean = false;
  private realtimeAudioLevel: number = 0;
  private realtimeRemainingSec: number = ApiConfig.DEFAULT_MAX_DURATION_SEC;
  private realtimeTranscript: string = '';
  private realtimeTranscriptLanguage: string = '';
  private realtimePreviewLength: number = 0;
  private realtimePreviewComposing: boolean = false;
  private realtimeAcceptingPreview: boolean = false;
  /** 实时识别打字机平滑层:只平滑"预览显示",不参与最终提交(最终仍由 commitRealtimeFinalText 整段提交)。 */
  private realtimeTypewriter: TypewriterReveal;
  private realtimeWsClient: RealtimeAsrWebSocketClient | null = null;
  private realtimeConnectPromise: Promise<void> | null = null;
  private realtimeConnectJobActive: boolean = false;
  private realtimeConnectError: string | null = null;
  // 待发实时音频缓冲(Kotlin 用 ArrayDeque + 锁;JS 单线程,数组即可)
  private realtimePendingAudio: ArrayBuffer[] = [];
  private realtimePendingAudioBytes: number = 0;
  private inputViewActive: boolean = false;
  private symbolPanelVisible: boolean = false;
  private personaPanelVisible: boolean = false;
  private rightHandLayout: boolean = true;
  private blockedReason: BlockedReason | null = null;
  private liveCreditsRemaining: number | null = null;
  private accountStatusLoading: boolean = false;
  private personasLoading: boolean = false;
  private personasRefreshing: boolean = false;
  private pendingPersonaActionId: string | null = null;
  private personaDetail: PersonaItem | null = null;
  private personas: PersonaItem[] = [];

  // ---------- 退格长按连发 ----------
  private backspaceRepeatActive: boolean = false;
  private backspaceLongPressTriggered: boolean = false;
  private backspaceRepeatSession: number = 0;
  private backspaceLongPressTimer: number = -1;
  private backspaceRepeatTimer: number = -1;

  // ---------- 麦克风球手势(对应 Kotlin OnTouchListener 的拦截决策) ----------
  private micGestureIntercepted: boolean = false;

  // ---------- 打字键盘模式(协调器分层) ----------
  private typingCoordinator: TypingModeCoordinator | null = null;
  private typingSessionHost: TypingSessionHost | null = null;
  private micCoordinator: KeyboardMicCoordinator | null = null;
  private typingImeContext: TypingImeContextImpl | null = null;
  private typingPrefs: TypingPreferences | null = null;
  private composingBridge: ComposingTextBridge = new ComposingTextBridge();
  /** 打字键盘状态中枢(ImeBusDelegate 的查询/动作转发目标)。 */
  private keyboardController: KeyboardController | null = null;
  /** 键区布局工厂(delegate.buildKeyRows 使用)。 */
  private layoutFactory: KeyboardLayoutFactory | null = null;

  /** 语音模式符号面板当前分类(与键盘模式符号板共用 SymbolData 数据与最近使用存储)。 */
  private voiceSymbolCategory: string = SymbolData.RECENT_ID;
  private recentSymbolsCache: string[] = [];

  /** 键盘是否正忙:有录音在进行,或正在等待服务端结果。统一替代散落的多标志组合判断。 */
  private get isBusy(): boolean {
    return this.captureMode !== CaptureMode.IDLE || this.isProcessing;
  }

  // ==================== 生命周期(对应 LobsterIME.onCreate / onDestroy) ====================

  onCreate(context: common.Context): void {
    this.context = context;
    try {
      FileLog.init(context);
    } catch (e) {
      Logger.w(TAG, 'FileLog.init failed: ' + (e as Error).message);
    }
    this.audioRecorder = new AudioRecorder(context);
    this.realtimeStreamer = new RealtimeAudioStreamer(context);
    this.keyboardMic = new KeyboardRealtimeMic(this.realtimeStreamer, new KeyboardRealtimeMicCallbacksImpl(this));
    this.historyStore = new MobileHistoryStore();
    this.prefs = AppPreferences.getInstance(context);
    this.ensureTypingStack();
    this.loadStartupPreferences();
    this.installAudioLevelMirrors();
    this.registerImeEngineListeners();
    this.bindUiActions();
    this.createPanelAndContent();
  }

  onDestroy(): void {
    // 对应 Kotlin onDestroy():停连发、关 WS、释放流式录音器、取消协程作用域
    this.stopBackspaceRepeat();
    const client = this.realtimeWsClient;
    if (client !== null) {
      this.realtimeWsClient = null;
      client.close();
    }
    const streamer = this.realtimeStreamer;
    if (streamer !== null) {
      streamer.release();
    }
    const panel = this.panel;
    if (panel !== null) {
      this.panel = null;
      try {
        inputMethodEngine.getInputMethodAbility().destroyPanel(panel);
      } catch (e) {
        Logger.w(TAG, 'destroyPanel failed: ' + (e as Error).message);
      }
    }
  }

  requireContext(): common.Context {
    const ctx = this.context;
    if (ctx === null) {
      throw new Error('LobsterImeService context not ready');
    }
    return ctx;
  }

  /** 对应 Kotlin onCreate 中的 SharedPreferences 读取(鸿蒙 preferences 为异步)。 */
  private loadStartupPreferences(): void {
    const prefs = this.prefs;
    if (prefs === null) {
      return;
    }
    prefs.getBoolean(PREF_HAND_LAYOUT, true).then((v: boolean): void => {
      this.rightHandLayout = v;
      this.refreshKeyboardUi();
    });
    prefs.getBoolean(PREF_FAST_MODE, false).then((v: boolean): void => {
      this.fastModeEnabled = v;
      this.refreshKeyboardUi();
    });
    prefs.getBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, false).then((v: boolean): void => {
      this.realtimeRecognitionEnabled = v;
      this.refreshKeyboardUi();
    });
  }

  /**
   * 对应 Kotlin onCreate 中的 4 个 StateFlow 采集器:
   * 只把录音器的声浪/倒计时镜像到 UI,不参与控制决策(控制状态以 captureMode 为唯一权威)。
   */
  private installAudioLevelMirrors(): void {
    const recorder = this.audioRecorder;
    const streamer = this.realtimeStreamer;
    if (recorder === null || streamer === null) {
      return;
    }
    recorder.onAudioLevelChanged = (level: number): void => {
      // 高频回调:只更新麦克风球能量,不做整面板刷新。
      this.audioLevel = level;
      this.busAudioLevel(clamp01(level / 100));
    };
    recorder.onRemainingSecondsChanged = (remaining: number): void => {
      this.recordingRemainingSec = remaining;
      if (this.captureMode === CaptureMode.SYNC) {
        this.refreshKeyboardUi();
      }
    };
    streamer.onAudioLevelChanged = (level: number): void => {
      // 高频回调:只更新麦克风球能量,不做整面板刷新。
      this.realtimeAudioLevel = level;
      this.busAudioLevel(clamp01(level / 100));
      const mic = this.keyboardMic;
      if (mic !== null && mic.isActive) {
        this.busMicLevel(clamp01(level / 100));
      }
    };
    streamer.onRemainingSecondsChanged = (remaining: number): void => {
      this.realtimeRemainingSec = remaining;
      const mic = this.keyboardMic;
      if (mic !== null && mic.isActive) {
        const max = Math.max(streamer.maxDurationSec, 1);
        this.busMicProgress(remaining / max);
      }
      if (this.captureMode === CaptureMode.REALTIME) {
        this.refreshKeyboardUi();
      }
    };
    recorder.onMaxDurationReached = (filePath: string): void => {
      if (!this.isProcessing) {
        this.processAudio(filePath, this.pendingOperation);
      } else {
        this.captureMode = CaptureMode.IDLE;
        this.deleteAudioFile(filePath);
        this.refreshKeyboardUi();
      }
    };
  }

  // ==================== 输入事件绑定(onStartInputView / onFinishInputView / onWindowHidden 映射) ====================

  private registerImeEngineListeners(): void {
    const ability = inputMethodEngine.getInputMethodAbility();
    // 编辑器聚焦 → 对应安卓 onStartInputView(含框间焦点跳转,每次都触发)
    ability.on('inputStart', (kb: inputMethodEngine.KeyboardController, client: inputMethodEngine.InputClient): void => {
      this.onInputStart(kb, client);
    });
    // 编辑器脱离 → 对应安卓 onFinishInputView(finishingInput=true)
    ability.on('inputStop', (): void => {
      this.onFinishInputViewEquivalent();
      this.clientAdapter = null;
      this.rawInputClient = null;
      this.kbController = null;
      this.currentEditorInfo = null;
    });
    ability.on('keyboardShow', (): void => {
      this.inputViewActive = true;
    });
    // 键盘窗口真正收起 → 对应安卓 onFinishInputView + onWindowHidden(会话结束)
    ability.on('keyboardHide', (): void => {
      this.onFinishInputViewEquivalent();
      this.onWindowHiddenEquivalent();
    });
    // 输入法子类型切换(安卓端未使用 subtype,这里保留事件挂接以对齐平台生命周期)
    ability.on('setSubtype', (subtype: InputMethodSubtype): void => {
      Logger.i(TAG, 'setSubtype: ' + subtype.id);
    });

    // KeyboardDelegate:选区/全文镜像,喂给 InputClientAdapter 以模拟 getSelectedText
    const delegate = inputMethodEngine.getKeyboardDelegate();
    delegate.on('selectionChange', (oldBegin: number, oldEnd: number, newBegin: number, newEnd: number): void => {
      const adapter = this.clientAdapter;
      if (adapter !== null) {
        adapter.onSelectionChange(newBegin, newEnd);
      }
    });
    delegate.on('textChange', (text: string): void => {
      const adapter = this.clientAdapter;
      if (adapter !== null) {
        adapter.onTextChange(text);
      }
    });
    delegate.on('editorAttributeChanged', (attr: inputMethodEngine.EditorAttribute): void => {
      this.currentEditorInfo = attr;
      const adapter = this.clientAdapter;
      if (adapter !== null) {
        adapter.setEnterKeyType(attr.enterKeyType);
      }
    });
  }

  private onInputStart(kb: inputMethodEngine.KeyboardController, client: inputMethodEngine.InputClient): void {
    this.kbController = kb;
    this.rawInputClient = client;
    this.clientAdapter = new InputClientAdapter(client);
    this.onInputStartAsync(client);
  }

  private async onInputStartAsync(client: inputMethodEngine.InputClient): Promise<void> {
    try {
      const attr = await client.getEditorAttribute();
      this.currentEditorInfo = attr;
      const adapter = this.clientAdapter;
      if (adapter !== null) {
        adapter.setEnterKeyType(attr.enterKeyType);
      }
    } catch (e) {
      Logger.w(TAG, 'getEditorAttribute failed: ' + (e as Error).message);
      this.currentEditorInfo = null;
    }
    await this.onStartInputViewEquivalent();
  }

  /** 对应安卓 onStartInputView(info, restarting)。 */
  private async onStartInputViewEquivalent(): Promise<void> {
    this.inputViewActive = true;
    const prefs = this.prefs;
    if (prefs !== null) {
      this.realtimeRecognitionEnabled = await prefs.getBoolean(ApiConfig.KEY_REALTIME_RECOGNITION, false);
    }
    this.clearTemporaryTextHistory();
    this.errorMessage = '';
    this.statusText = this.canRewrite() ? MobileStrings.rewriteHint() : this.defaultTranscribeHint();
    // 安卓在此重建符号板/人设板/快捷键行(文案跟随语言);鸿蒙 UI 由 ImeBus 状态驱动,
    // 文案由 UI 层实时取 MobileStrings,这里只刷新数据快照。
    this.refreshSymbolPanelState();
    this.ensureTypingStack();
    const coordinator = this.typingCoordinator;
    const sessionHost = this.typingSessionHost;
    if (coordinator !== null) {
      coordinator.onStartInputView();
    }
    // 拉起面板清空打字候选栏的残留错误提示(如上次的「Timed out…」),避免常驻不消失
    if (sessionHost !== null) {
      sessionHost.showStatus(undefined);
    }
    // 记住上次模式:拉起时恢复到用户上次手动选择的语音/键盘模式(初次默认语音)。
    // 类型感知例外(不覆盖用户模式偏好):
    //  - 数字/电话/日期框:强制键盘模式(数字键盘页),语音输数字不友好;
    //  - 邮箱/URI/密码框:强制键盘模式(英文),语音输账号密码不友好且密码有合规隐患。
    if (coordinator !== null && sessionHost !== null) {
      const typedField = sessionHost.isNumericField() || sessionHost.isEnglishField() ||
        sessionHost.isPasswordField();
      if (typedField || sessionHost.lastModeKeyboard()) {
        if (!coordinator.active) {
          this.enterKeyboardMode(!typedField);
        }
      } else if (coordinator.active) {
        this.exitKeyboardMode();
      }
    }
    this.refreshKeyboardUi();
    this.refreshAccountStateForPanel();
  }

  /** 对应安卓 onFinishInputView(finishingInput)。 */
  private onFinishInputViewEquivalent(): void {
    this.inputViewActive = false;
    const mic = this.keyboardMic;
    if (mic !== null && mic.isActive) {
      mic.stop();
    }
    // 结束输入即清理未完成的 composing/候选,避免下次聚焦残留
    const coordinator = this.typingCoordinator;
    if (coordinator !== null) {
      coordinator.resetComposing();
    }
  }

  /** 对应安卓 onWindowHidden():清除会话级模式粘性(数字页粘性/英文框自动切换)。 */
  private onWindowHiddenEquivalent(): void {
    const coordinator = this.typingCoordinator;
    if (coordinator !== null) {
      coordinator.onSessionEnd();
    }
  }

  // ==================== 软键盘 Panel(替代 onCreateInputView 的窗口载体) ====================

  private createPanelAndContent(): void {
    this.createPanelAsync();
  }

  private async createPanelAsync(): Promise<void> {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const info: inputMethodEngine.PanelInfo = {
        type: inputMethodEngine.PanelType.SOFT_KEYBOARD,
        flag: inputMethodEngine.PanelFlag.FLG_FIXED
      };
      const panel = await inputMethodEngine.getInputMethodAbility().createPanel(ctx, info);
      this.panel = panel;
      await panel.setUiContent('ime/KeyboardPanelPage');
      this.resizePanelToKeyboardHeight();
    } catch (e) {
      Logger.e(TAG, 'createPanel failed: ' + (e as Error).message);
    }
  }

  /** 面板固定高度 286vp(对应安卓 KEYBOARD_PANEL_HEIGHT_DP / FixedHeightImeRoot)。 */
  private resizePanelToKeyboardHeight(): void {
    const panel = this.panel;
    if (panel === null) {
      return;
    }
    try {
      const d = display.getDefaultDisplaySync();
      const heightPx = Math.round(KEYBOARD_PANEL_HEIGHT_DP * d.densityPixels);
      panel.resize(d.width, heightPx);
    } catch (e) {
      Logger.w(TAG, 'panel resize failed: ' + (e as Error).message);
    }
  }

  // ==================== 登录态与账户可用性 ====================

  private isLoggedIn(): boolean {
    return AuthSession.isLoggedIn();
  }

  private getAuthHeader(): string | null {
    return AuthSession.authHeader();
  }

  authHeaderOrNull(): string | null {
    return this.getAuthHeader();
  }

  isCreditsBlockedNow(): boolean {
    return this.blockedReason === BlockedReason.CREDITS_EXHAUSTED;
  }

  isKeyboardMicActive(): boolean {
    const mic = this.keyboardMic;
    return mic !== null && mic.isActive;
  }

  private refreshAccountStateForPanel(): void {
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.liveCreditsRemaining = null;
      this.showUnavailable(BlockedReason.LOGIN_REQUIRED);
      return;
    }
    this.verifyAccountState(authHeader, null, true);
  }

  ensureInputAvailableForAction(onReady: () => void): void {
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.liveCreditsRemaining = null;
      this.showUnavailable(BlockedReason.LOGIN_REQUIRED);
      return;
    }
    if (this.liveCreditsRemaining === null || this.liveCreditsRemaining === 0) {
      this.verifyAccountState(authHeader, onReady, this.liveCreditsRemaining === null);
      return;
    }
    this.clearUnavailableState();
    onReady();
  }

  private verifyAccountState(authHeader: string, onReady: (() => void) | null, allowFallback: boolean): void {
    if (this.accountStatusLoading) {
      return;
    }
    this.accountStatusLoading = true;
    this.errorMessage = '';
    this.statusText = MobileStrings.checkingAccount();
    this.refreshKeyboardUi();
    this.verifyAccountStateAsync(authHeader, onReady, allowFallback);
  }

  private async verifyAccountStateAsync(
    authHeader: string,
    onReady: (() => void) | null,
    allowFallback: boolean
  ): Promise<void> {
    try {
      const info = await ApiService.getInstance().getPlanInfo(authHeader);
      const remaining = info.credits_remaining;
      this.rememberLiveCredits(remaining);
      if (remaining > 0) {
        this.clearUnavailableState();
        if (onReady !== null) {
          onReady();
        }
      } else {
        this.showUnavailable(BlockedReason.CREDITS_EXHAUSTED);
      }
      return;
    } catch (e) {
      const failure = this.parseApiFailure(e as Error);
      if (failure.statusCode === 401 || failure.code === 'USER_BANNED') {
        AuthSession.clearIfCurrent(authHeader);
        this.liveCreditsRemaining = null;
        this.showUnavailable(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired());
        return;
      }
      if (failure.code === 'CREDITS_EXHAUSTED') {
        this.rememberLiveCredits(0);
        this.showUnavailable(BlockedReason.CREDITS_EXHAUSTED);
        return;
      }
      // 网络异常/其它错误:allowFallback 时放行动作(与安卓一致,避免离线场景卡死入口)
      if (allowFallback && onReady !== null) {
        this.clearUnavailableState();
        onReady();
      } else if (onReady !== null) {
        this.showError(failure.message ?? MobileStrings.accountCheckFailed(failure.statusCode));
      }
    } finally {
      this.accountStatusLoading = false;
      this.refreshKeyboardUi();
    }
  }

  private rememberLiveCredits(remaining: number | null): void {
    if (remaining === null) {
      return;
    }
    this.liveCreditsRemaining = remaining;
    this.blockedReason = remaining <= 0 ? BlockedReason.CREDITS_EXHAUSTED : null;
  }

  private showUnavailable(reason: BlockedReason, message: string | null = null): void {
    this.blockedReason = reason;
    this.errorMessage = '';
    this.statusText = message ?? MobileStrings.inputUnavailableTitle(reason === BlockedReason.CREDITS_EXHAUSTED);
    this.refreshKeyboardUi();
  }

  private clearUnavailableState(): void {
    this.blockedReason = null;
    this.errorMessage = '';
    this.statusText = this.canRewrite() ? MobileStrings.rewriteHint() : this.defaultTranscribeHint();
    this.refreshKeyboardUi();
  }

  // ==================== 麦克风球手势(对应 RecordOrbView 的 click + touch 拦截) ====================

  /**
   * 对应 Kotlin setOnTouchListener 的拦截决策:
   * 仅当 实时开关开启 且 当前不是同步录音 时,由长按手势接管(按下=开始实时,松手=结束);
   * 其余情况一律走单击(onMicTap):① 同步模式永远是单击开始/停止;
   * ② 即便实时开关开启,「指令」发起的同步录音也能用单击可靠停止(此时 captureMode == SYNC)。
   */
  onMicPressDown(): void {
    if (!this.realtimeRecognitionEnabled || this.captureMode === CaptureMode.SYNC) {
      this.micGestureIntercepted = false;
      return;
    }
    this.micGestureIntercepted = true;
    this.onRealtimePressDown();
  }

  /**
   * 按下-抬起的完整配对入口(拦截 → 结束实时;未拦截 → 单击)。
   * 注:当前鸿蒙 UI 的录音球把"抬起"与"单击"拆成 onOrbTouchUp(→ onMicPressCancel)与
   * onOrbTap(→ onMicTap)两个事件,两者组合与本方法语义等价;保留本方法供合并手势的宿主使用。
   */
  onMicPressUp(): void {
    if (this.micGestureIntercepted) {
      this.micGestureIntercepted = false;
      this.onRealtimeRelease();
      return;
    }
    this.onMicTap();
  }

  onMicPressCancel(): void {
    if (this.micGestureIntercepted) {
      this.micGestureIntercepted = false;
      this.onRealtimeRelease();
    }
  }

  /** 麦克风单击:同步录音的开始/停止入口(同步模式,或停止「指令」发起的同步录音)。 */
  onMicTap(): void {
    // 同步录音进行中(含「指令」发起):单击停止并送识别。
    if (this.captureMode === CaptureMode.SYNC) {
      this.stopRecording();
      return;
    }
    // 实时模式下单击不发起同步(实时由长按触发);键盘忙时一律忽略。
    if (this.realtimeRecognitionEnabled || this.isBusy) {
      return;
    }

    if (!this.checkRecordPermission()) {
      this.requestRecordPermission();
      this.showError(MobileStrings.micPermission());
      return;
    }

    this.ensureInputAvailableForAction((): void => {
      this.startRecording(Operation.TRANSCRIBE);
    });
  }

  /** 麦克风长按按下:发起实时流式录音(仅实时开关开启且空闲时)。 */
  private onRealtimePressDown(): void {
    if (!this.realtimeRecognitionEnabled || this.isBusy) {
      return;
    }

    this.realtimePressActive = true;
    if (!this.checkRecordPermission()) {
      this.realtimePressActive = false;
      this.requestRecordPermission();
      this.showError(MobileStrings.micPermission());
      return;
    }

    this.ensureInputAvailableForAction((): void => {
      this.startRealtimeRecognition();
    });
  }

  /** 麦克风长按松手:结束实时流式录音。 */
  private onRealtimeRelease(): void {
    this.realtimePressActive = false;
    if (this.captureMode === CaptureMode.REALTIME || this.realtimeWsClient !== null) {
      this.stopRealtimeRecognition();
    }
  }

  // ==================== 麦克风权限 ====================

  checkRecordPermission(): boolean {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
      );
      const tokenId = bundleInfo.appInfo.accessTokenId;
      const status = atManager.checkAccessTokenSync(tokenId, 'ohos.permission.MICROPHONE');
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (e) {
      Logger.w(TAG, 'checkRecordPermission failed: ' + (e as Error).message);
      return false;
    }
  }

  /**
   * 尝试拉起系统麦克风授权弹窗(安卓端 IME 仅检查不请求;鸿蒙可在扩展上下文尝试,
   * 失败静默 —— 用户可在主应用/设置中授权)。
   */
  private requestRecordPermission(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      atManager.requestPermissionsFromUser(ctx, ['ohos.permission.MICROPHONE'])
        .then((): void => {
          this.refreshKeyboardUi();
        })
        .catch((e: Error): void => {
          Logger.w(TAG, 'requestPermissionsFromUser failed: ' + e.message);
        });
    } catch (e) {
      Logger.w(TAG, 'requestRecordPermission failed: ' + (e as Error).message);
    }
  }

  // ==================== 同步录音(单击模式 / 「指令」改写) ====================

  private startRecording(operation: Operation): void {
    const streamer = this.realtimeStreamer;
    const recorder = this.audioRecorder;
    if (streamer === null || recorder === null) {
      return;
    }
    // 麦克风交接保险:同步录音必须独占麦克风。无条件先停实时流(幂等),
    // 杜绝实时流残留的采集器与同步采集器同时占用麦克风导致首帧阻塞/崩溃。
    streamer.stop();
    // 进入同步捕获(权威同步状态,立即生效)。「指令」改写录音也走这里,与实时开关无关。
    this.captureMode = CaptureMode.SYNC;
    this.errorMessage = '';
    if (operation === Operation.TRANSCRIBE) {
      this.pendingRewriteOriginal = '';
      this.pendingRewriteTarget = RewriteTarget.NONE;
    }
    this.statusText = operation === Operation.REWRITE
      ? MobileStrings.tapAgainRewrite()
      : MobileStrings.tapAgainTranscribe();
    this.pendingOperation = operation;
    this.recordingRemainingSec = recorder.maxDurationSec;
    this.refreshKeyboardUi();

    recorder.startRecording().then((filePath: string | null): void => {
      if (filePath === null) {
        this.captureMode = CaptureMode.IDLE;
        this.restoreRewriteIfNeeded();
        this.showError(MobileStrings.recordingStartFailed());
      }
    }).catch((e: Error): void => {
      Logger.e(TAG, 'startRecording failed: ' + e.message);
      this.captureMode = CaptureMode.IDLE;
      this.restoreRewriteIfNeeded();
      this.showError(MobileStrings.recordingStartFailed());
    });
  }

  private stopRecording(): void {
    const recorder = this.audioRecorder;
    if (recorder === null) {
      return;
    }
    let filePath: string | null = null;
    try {
      filePath = recorder.stopRecording();
    } catch (e) {
      Logger.e(TAG, 'stopRecording failed: ' + (e as Error).message);
      filePath = null;
    }
    if (filePath !== null) {
      this.processAudio(filePath, this.pendingOperation);
    } else {
      this.captureMode = CaptureMode.IDLE;
      this.restoreRewriteIfNeeded();
      this.refreshKeyboardUi();
    }
  }

  // ==================== 实时流式识别(长按模式) ====================

  private startRealtimeRecognition(): void {
    if (!this.realtimePressActive) {
      return;
    }
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.realtimePressActive = false;
      this.showUnavailable(BlockedReason.LOGIN_REQUIRED);
      return;
    }
    const streamer = this.realtimeStreamer;
    if (streamer === null) {
      return;
    }

    const language = MobileStrings.currentLanguage().code;
    const client = this.createRealtimeClient(authHeader, language);
    this.pendingOperation = Operation.TRANSCRIBE;
    this.pendingRewriteOriginal = '';
    this.pendingRewriteTarget = RewriteTarget.NONE;
    this.realtimeTranscript = '';
    this.realtimeTranscriptLanguage = '';
    this.realtimeConnectError = null;
    this.realtimeAcceptingPreview = client.isReady;
    this.clearRealtimePreview();
    this.clearRealtimeAudioBuffer();
    this.errorMessage = '';
    this.realtimeWsClient = client;
    this.realtimeRemainingSec = streamer.maxDurationSec;
    // 进入实时捕获(权威同步状态,立即生效)。
    this.captureMode = CaptureMode.REALTIME;
    this.statusText = MobileStrings.releaseToSend();
    this.refreshKeyboardUi();

    streamer.start(
      (bytes: ArrayBuffer): void => {
        this.handleRealtimeAudioChunk(client, bytes);
      },
      (): void => {
        this.realtimePressActive = false;
        this.stopRealtimeRecognition();
      }
    ).then((started: boolean): void => {
      if (!started) {
        this.captureMode = CaptureMode.IDLE;
        if (this.realtimeWsClient === client) {
          this.realtimeWsClient = null;
        }
        this.realtimeAcceptingPreview = false;
        this.clearRealtimeAudioBuffer();
        this.showError(MobileStrings.recordingStartFailed());
        this.refreshKeyboardUi();
        return;
      }
      if (client.isReady) {
        this.flushBufferedRealtimeAudio(client);
      } else {
        this.startRealtimeClientConnection(client);
      }
      this.refreshKeyboardUi();
    });
  }

  private stopRealtimeRecognition(): void {
    if (this.realtimeFinishing) {
      return;
    }
    const streamer = this.realtimeStreamer;

    // 隐患2 修复:无论是否有活动 WS 会话,都先停止流式录音并释放麦克风,
    // 让 captureMode 立即回到 IDLE,避免「会话已空但流仍在跑」导致状态卡死、麦克风占用。
    this.realtimeAcceptingPreview = false;
    if (streamer !== null) {
      streamer.stop();
    }
    this.captureMode = CaptureMode.IDLE;
    // 停止录音:立即把预览补齐到完整目标,避免停在"揭示一半"的残缺文本;
    // 最终仍由 commitRealtimeFinalText 用后端权威整句替换,业务结果不受影响。
    this.realtimeTypewriter.flush();

    const client = this.realtimeWsClient;
    // BUG修复(与安卓同源):WS 中途断连(failActiveRealtimeConnection 已置空 client)时,识别预览
    // 还留在输入框里,旧逻辑直接 return——既不投递 LLM 也不清预览。现在只要有已识别文本,
    // 即使 WS 已断也照常投递 processRealtimeText(纯文本兜底通道)。
    if (client === null && this.realtimeTranscript.trim().length === 0) {
      FileLog.w('VoiceRT', 'release: ws=null transcript=empty, nothing to process');
      this.realtimeTypewriter.reset();
      this.clearRealtimeAudioBuffer();
      this.clearRealtimePreview();
      this.refreshKeyboardUi();
      return;
    }

    this.realtimeFinishing = true;
    this.isProcessing = true;
    this.errorMessage = '';
    this.statusText = MobileStrings.realtimeFinishing();
    this.refreshKeyboardUi();

    this.finishRealtimeAsync(client);
  }

  /** 对应 Kotlin stopRealtimeRecognition 内的 scope.launch 收尾协程。 */
  private async finishRealtimeAsync(client: RealtimeAsrWebSocketClient | null): Promise<void> {
    try {
      let transcript: string = '';
      let sessionId: string | null = null;
      if (client !== null) {
        await this.awaitRealtimeClientReady(client);
        this.flushBufferedRealtimeAudio(client);
        transcript = this.realtimeTranscript.trim();
        if (!client.requestFinish()) {
          throw new Error(MobileStrings.processFailed());
        }
        sessionId = client.asrSessionId;
      } else {
        transcript = this.realtimeTranscript.trim();
        FileLog.w('VoiceRT', 'release: ws=null, fallback transcript-only len=' + transcript.length);
      }
      FileLog.i('VoiceRT', 'processRealtimeText call: fastMode=' + this.fastModeEnabled +
        ' len=' + transcript.length + ' session=' + (sessionId ?? 'null'));
      const authHeader = this.getAuthHeader();
      if (authHeader === null) {
        throw new InputUnavailableException(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired());
      }
      const response = await this.requestRealtimeText(
        authHeader, transcript, sessionId, transcript, this.realtimeTranscriptLanguage
      );
      if (client !== null) {
        client.close();
      }
      FileLog.i('VoiceRT', 'processRealtimeText ok: action=' + response.action_type.toString() +
        ' resultLen=' + this.outputTextAudio(response).length);
      this.handleAudioResponse(response, Operation.TRANSCRIBE);
    } catch (err) {
      const e = err as Error;
      if (e instanceof InputUnavailableException) {
        FileLog.e('VoiceRT', 'processRealtimeText unavailable: ' + e.reason + ' ' + e.message);
        this.historyAddFailed(operationApiValue(Operation.TRANSCRIBE), e.message !== '' ? e.message : MobileStrings.processFailed(), null);
        this.clearRealtimePreview();
        this.showUnavailable(e.reason, e.message);
      } else {
        FileLog.e('VoiceRT', 'processRealtimeText failed: ' + e.message);
        this.historyAddFailed(operationApiValue(Operation.TRANSCRIBE), e.message !== '' ? e.message : MobileStrings.processFailed(), null);
        this.clearRealtimePreview();
        this.showError(e.message !== '' ? e.message : MobileStrings.processFailed());
      }
    } finally {
      if (client !== null) {
        client.close();
      }
      this.clearRealtimeAudioBuffer();
      this.realtimeWsClient = null;
      this.realtimeFinishing = false;
      this.realtimeAcceptingPreview = false;
      this.isProcessing = false;
      this.realtimeTranscript = '';
      this.realtimeTranscriptLanguage = '';
      this.realtimeTypewriter.reset();
      this.refreshKeyboardUi();
    }
  }

  private createRealtimeClient(authHeader: string, language: string): RealtimeAsrWebSocketClient {
    let clientRef: RealtimeAsrWebSocketClient | null = null;
    const client = new RealtimeAsrWebSocketClient(
      authHeader,
      language,
      (text: string, detectedLanguage: string): void => {
        // onPartial(WS 回调已在主线程事件循环,无需 uiHandler.post)
        const activeClient = clientRef;
        if (activeClient === null) {
          return;
        }
        if (!this.shouldAcceptRealtimePreview(activeClient)) {
          return;
        }
        this.realtimeTranscriptLanguage = detectedLanguage;
        this.replaceRealtimePreview(text);
      },
      (text: string, detectedLanguage: string): void => {
        // onCompleted
        const activeClient = clientRef;
        if (activeClient === null) {
          return;
        }
        if (!this.shouldAcceptRealtimePreview(activeClient)) {
          return;
        }
        this.realtimeTranscriptLanguage = detectedLanguage;
        this.replaceRealtimePreview(text);
      },
      (kind: RealtimeAsrErrorKind, message: string): void => {
        // onError
        const activeClient = clientRef;
        if (activeClient === null) {
          return;
        }
        if (this.realtimeWsClient === activeClient) {
          // 链路层错误的原始文案是底层英文(如 Software caused connection abort),换成本地化提示
          const display = kind === RealtimeAsrErrorKind.NETWORK
            ? MobileStrings.networkError()
            : (message.trim().length > 0 ? message : MobileStrings.processFailed());
          this.realtimeConnectError = display;
          if (!this.realtimeFinishing) {
            this.failActiveRealtimeConnection(activeClient, display);
          }
        }
      }
    );
    clientRef = client;
    return client;
  }

  private startRealtimeClientConnection(client: RealtimeAsrWebSocketClient): void {
    if (client.isReady) {
      return;
    }
    if (this.realtimeWsClient === client && this.realtimeConnectJobActive) {
      return;
    }
    this.realtimeConnectError = null;
    this.realtimeConnectJobActive = true;
    this.realtimeConnectPromise = this.runRealtimeConnect(client);
  }

  private async runRealtimeConnect(client: RealtimeAsrWebSocketClient): Promise<void> {
    try {
      await client.connect();
      if (this.realtimeWsClient === client) {
        this.realtimeConnectError = null;
        this.realtimeAcceptingPreview = !this.realtimeFinishing && !this.isProcessing;
        this.flushBufferedRealtimeAudio(client);
        this.refreshKeyboardUi();
      }
    } catch (err) {
      // 连接阶段异常是链路层问题(超时/断链),不透传底层原文;
      // 服务端业务错误会先经 onError(SERVER) 路径写入 realtimeConnectError(已完成文案决策)
      const message = this.realtimeConnectError ?? MobileStrings.networkError();
      this.realtimeConnectError = message;
      if (this.realtimeWsClient === client) {
        if (!this.realtimeFinishing) {
          this.failActiveRealtimeConnection(client, message);
        }
      } else {
        client.close();
      }
    } finally {
      this.realtimeConnectJobActive = false;
    }
  }

  private async awaitRealtimeClientReady(client: RealtimeAsrWebSocketClient): Promise<void> {
    if (!client.isReady) {
      this.startRealtimeClientConnection(client);
      const job = this.realtimeConnectPromise;
      if (job !== null) {
        await job;
      }
    }
    if (!client.isReady) {
      throw new Error(this.realtimeConnectError ?? MobileStrings.processFailed());
    }
  }

  private handleRealtimeAudioChunk(client: RealtimeAsrWebSocketClient, bytes: ArrayBuffer): void {
    if (this.realtimeWsClient !== client) {
      return;
    }
    if (client.isReady) {
      this.flushBufferedRealtimeAudio(client);
      if (!client.sendAudio(bytes)) {
        this.bufferRealtimeAudio(bytes);
      }
      return;
    }
    this.bufferRealtimeAudio(bytes);
  }

  private bufferRealtimeAudio(bytes: ArrayBuffer): void {
    // Kotlin 侧有 synchronized 锁;JS 单线程,无需加锁
    while (this.realtimePendingAudioBytes + bytes.byteLength > REALTIME_AUDIO_BUFFER_LIMIT_BYTES &&
      this.realtimePendingAudio.length > 0) {
      const removed = this.realtimePendingAudio.shift();
      if (removed !== undefined) {
        this.realtimePendingAudioBytes -= removed.byteLength;
      }
    }
    if (bytes.byteLength <= REALTIME_AUDIO_BUFFER_LIMIT_BYTES) {
      this.realtimePendingAudio.push(bytes);
      this.realtimePendingAudioBytes += bytes.byteLength;
    }
  }

  private flushBufferedRealtimeAudio(client: RealtimeAsrWebSocketClient): void {
    if (!client.isReady) {
      return;
    }
    const chunks: ArrayBuffer[] = [];
    while (this.realtimePendingAudio.length > 0) {
      const chunk = this.realtimePendingAudio.shift();
      if (chunk === undefined) {
        break;
      }
      chunks.push(chunk);
    }
    this.realtimePendingAudioBytes = 0;
    for (let index = 0; index < chunks.length; index++) {
      if (!client.sendAudio(chunks[index])) {
        this.bufferRealtimeAudio(chunks[index]);
        for (let remainingIndex = index + 1; remainingIndex < chunks.length; remainingIndex++) {
          this.bufferRealtimeAudio(chunks[remainingIndex]);
        }
        return;
      }
    }
  }

  private clearRealtimeAudioBuffer(): void {
    this.realtimePendingAudio = [];
    this.realtimePendingAudioBytes = 0;
  }

  private failActiveRealtimeConnection(client: RealtimeAsrWebSocketClient, message: string): void {
    if (this.realtimeWsClient !== client) {
      return;
    }
    FileLog.e('VoiceRT', 'ws failed mid-session: ' + message + ' transcriptLen=' + this.realtimeTranscript.length);
    const streamer = this.realtimeStreamer;
    if (streamer !== null) {
      streamer.stop();
    }
    this.clearRealtimeAudioBuffer();
    this.realtimeAcceptingPreview = false;
    this.realtimeWsClient = null;
    client.close();

    // 弱网断链但已有识别文本:不丢用户内容,交给既有 ws=null 纯文本兜底管线
    // (stopRealtimeRecognition 对 client==null 且 transcript 非空的分支)处理。对齐安卓。
    if (this.realtimeTranscript.trim().length > 0) {
      if (this.realtimePressActive) {
        // 用户仍按住:保持 REALTIME 捕获态提示网络中断,松手后走兜底加工
        this.statusText = message;
        this.refreshKeyboardUi();
      } else {
        this.stopRealtimeRecognition();
      }
      return;
    }

    this.captureMode = CaptureMode.IDLE;
    this.realtimeFinishing = false;
    this.isProcessing = false;
    this.realtimePressActive = false;
    this.showError(message);
  }

  private chooseRealtimeTranscript(finalText: string, liveFallback: string): string {
    const finalTrimmed = finalText.trim();
    const fallback = liveFallback.trim();
    if (fallback.length === 0) {
      return finalTrimmed;
    }
    if (finalTrimmed.length === 0) {
      return fallback;
    }
    if (fallback.length > finalTrimmed.length &&
      (fallback.startsWith(finalTrimmed) || fallback.includes(finalTrimmed))) {
      return fallback;
    }
    return finalTrimmed;
  }

  // ==================== 音频上传与文本加工 ====================

  private processAudio(filePath: string, operation: Operation): void {
    // 录音已结束(单击停止或到达最大时长),进入处理态。
    this.captureMode = CaptureMode.IDLE;
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.restoreRewriteIfNeeded();
      this.deleteAudioFile(filePath);
      this.showUnavailable(BlockedReason.LOGIN_REQUIRED);
      return;
    }

    this.isProcessing = true;
    this.errorMessage = '';
    this.statusText = MobileStrings.processing(operation === Operation.REWRITE);
    this.refreshKeyboardUi();

    this.processAudioAsync(filePath, authHeader, operation);
  }

  private async processAudioAsync(filePath: string, authHeader: string, operation: Operation): Promise<void> {
    try {
      const response = await this.uploadAudio(filePath, authHeader, operation);
      this.handleAudioResponse(response, operation);
    } catch (err) {
      const e = err as Error;
      const selected = this.pendingRewriteOriginal.trim().length > 0 ? this.pendingRewriteOriginal : null;
      if (e instanceof InputUnavailableException) {
        this.historyAddFailed(operationApiValue(operation), e.message !== '' ? e.message : MobileStrings.processFailed(), selected);
        this.restoreRewriteIfNeeded();
        this.showUnavailable(e.reason, e.message);
      } else {
        this.historyAddFailed(operationApiValue(operation), e.message !== '' ? e.message : MobileStrings.processFailed(), selected);
        this.restoreRewriteIfNeeded();
        this.showError(e.message !== '' ? e.message : MobileStrings.processFailed());
      }
    } finally {
      this.isProcessing = false;
      this.refreshKeyboardUi();
      this.deleteAudioFile(filePath);
    }
  }

  private async uploadAudio(filePath: string, authHeader: string, operation: Operation): Promise<AudioProcessResponse> {
    const selectedText = operation === Operation.REWRITE && this.pendingRewriteOriginal.trim().length > 0
      ? this.pendingRewriteOriginal
      : null;
    const clipboardHistory = await this.recentContextForServer();
    const fastMode = (operation === Operation.TRANSCRIBE && this.fastModeEnabled) ? 'true' : 'false';
    // 等价安卓 file.name:multipart 上传文件名取路径末段
    const fileName = filePath.substring(filePath.lastIndexOf('/') + 1);

    try {
      const response = await ApiService.getInstance().processAudio(
        authHeader,
        filePath,
        fileName,
        operationApiValue(operation),
        selectedText,
        clipboardHistory,
        fastMode
      );
      return response;
    } catch (err) {
      throw this.audioApiError(err as Error, authHeader);
    }
  }

  private async requestRealtimeText(
    authHeader: string,
    transcript: string,
    asrSessionId: string | null,
    clientAsrText: string | null,
    language: string | null
  ): Promise<AudioProcessResponse> {
    // DTO 字段以 ApiModels.ets 的 snake_case 为准;可选字段(?)不可传 null,统一用 undefined 表示缺省
    const request: TextProcessRequest = {
      operation: operationApiValue(Operation.TRANSCRIBE),
      text: transcript,
      client_asr_text: clientAsrText !== null ? clientAsrText : undefined,
      asr_session_id: asrSessionId !== null ? asrSessionId : undefined,
      selected_text: undefined,
      clipboard_history: await this.recentContextListForServer(),
      provider: undefined,
      model: undefined,
      fast_mode: this.fastModeEnabled,
      transcript_language: language !== null && language.trim().length > 0 ? language : undefined
    };
    try {
      const response = await ApiService.getInstance().processRealtimeText(authHeader, request);
      return response;
    } catch (err) {
      throw this.audioApiError(err as Error, authHeader);
    }
  }

  /** 音频/实时文本接口共用的错误归一化(对应 Kotlin uploadAudio/requestRealtimeText 的错误分支)。 */
  private audioApiError(e: Error, authHeader: string): Error {
    const failure = this.parseApiFailure(e);
    if (failure.statusCode === 401 || failure.code === 'USER_BANNED') {
      AuthSession.clearIfCurrent(authHeader);
      return new InputUnavailableException(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired());
    }
    if (failure.code === 'CREDITS_EXHAUSTED') {
      this.liveCreditsRemaining = 0;
      return new InputUnavailableException(BlockedReason.CREDITS_EXHAUSTED, MobileStrings.creditsExhausted());
    }
    return new Error(failure.message ?? MobileStrings.requestFailed(failure.statusCode));
  }

  private handleAudioResponse(response: AudioProcessResponse, operation: Operation): void {
    this.rememberLiveCredits(response.credits_remaining);
    const output = this.outputTextAudio(response).trim();
    if (output.length === 0) {
      const message = operation === Operation.REWRITE
        ? MobileStrings.emptyRewrite()
        : MobileStrings.emptyTranscribe();
      const selected = this.pendingRewriteOriginal.trim().length > 0 ? this.pendingRewriteOriginal : null;
      this.historyAddFailed(operationApiValue(operation), message, selected);
      this.pendingRewriteOriginal = '';
      this.clearRealtimePreview();
      this.showError(message);
      return;
    }

    this.historyAddSuccess(
      operationApiValue(operation),
      response.transcript,
      output,
      response.action_type.toString(),
      this.pendingRewriteOriginal.trim().length > 0 ? this.pendingRewriteOriginal : null
    );

    const localCommand = operation === Operation.TRANSCRIBE ? this.voiceCommand(output) : null;
    if (localCommand !== null) {
      this.clearRealtimePreview();
      this.handleLocalVoiceCommand(localCommand);
      this.pendingRewriteOriginal = '';
      this.pendingRewriteTarget = RewriteTarget.NONE;
      this.errorMessage = '';
      this.refreshKeyboardUi();
      return;
    }

    // (对齐安卓的空 when 分支注释)
    // REWRITE + LAST_INSERTED → applyProcessedText 负责替换上次插入文本;
    // REWRITE + SELECTED_TEXT → commitText 对可编辑框会替换活动选区。
    const target = operation === Operation.REWRITE ? this.pendingRewriteTarget : RewriteTarget.NONE;
    if (operation === Operation.TRANSCRIBE && this.realtimePreviewLength > 0) {
      this.commitRealtimeFinalText(output);
    } else {
      this.applyProcessedText(
        output,
        target,
        operation === Operation.REWRITE && this.pendingRewriteOriginal.trim().length > 0
          ? this.pendingRewriteOriginal
          : null,
        true
      );
    }
    this.pendingRewriteOriginal = '';
    this.pendingRewriteTarget = RewriteTarget.NONE;
    this.statusText = operation === Operation.REWRITE ? MobileStrings.rewritten() : MobileStrings.inserted();
    this.errorMessage = '';
    this.refreshKeyboardUi();
  }

  // ==================== 本地语音指令 ====================

  /** 字符串入参重载(对齐 Kotlin 的两个 handleLocalVoiceCommand)。 */
  private handleLocalVoiceCommandText(output: string): boolean {
    return this.handleLocalVoiceCommand(this.voiceCommand(output));
  }

  private handleLocalVoiceCommand(command: VoiceCommand | null): boolean {
    if (command === VoiceCommand.NEWLINE) {
      this.handleNewline();
      this.statusText = MobileStrings.inserted();
      return true;
    }
    if (command === VoiceCommand.BACKSPACE) {
      this.handleBackspace();
      return true;
    }
    if (command === VoiceCommand.UNDO_LAST) {
      this.handleUndo();
      return true;
    }
    return false;
  }

  private voiceCommand(output: string): VoiceCommand | null {
    // 对齐 Kotlin Regex("[\\s\\p{Punct}，。！？、；：""''（）【】《》]+")(\p{Punct} 即 ASCII 标点)
    const punctPattern = new RegExp(
      '[\\s!"#$%&\'()*+,\\-./:;<=>?@\\[\\\\\\]^_`{|}~，。！？、；：“”‘’（）【】《》]+', 'g'
    );
    const compact = output.trim().toLowerCase().replace(punctPattern, '');
    const spoken = output.trim().toLowerCase();

    const newlineCompact: string[] = ['换行', '另起一行', '新的一行', '下一行', 'newline', 'newlines', 'nextline', '줄바꿈', '새줄'];
    const newlineSpoken: string[] = ['new line', 'next line', 'new paragraph', 'новая строка'];
    const backspaceCompact: string[] = ['退格', '删除', '删一个字', '删除一个字', 'backspace', 'delete', 'deletechar', 'deletecharacter', '삭제'];
    const backspaceSpoken: string[] = ['delete last character', 'delete character', 'удалить', 'назад'];
    const undoCompact: string[] = ['撤回', '撤销', '撤回刚才', '撤销刚才', '删除刚才', '删掉刚才', '清除刚才', '清空刚才', 'undo', 'clear', 'clearthat', 'deletethat', 'removethat', '취소', '지워'];
    const undoSpoken: string[] = ['clear that', 'delete that', 'remove that', 'undo that', 'отменить'];

    if (newlineCompact.includes(compact) || newlineSpoken.includes(spoken)) {
      return VoiceCommand.NEWLINE;
    }
    if (backspaceCompact.includes(compact) || backspaceSpoken.includes(spoken)) {
      return VoiceCommand.BACKSPACE;
    }
    if (undoCompact.includes(compact) || undoSpoken.includes(spoken)) {
      return VoiceCommand.UNDO_LAST;
    }
    return null;
  }

  // ==================== 输出文本选择 ====================

  private outputTextAudio(response: AudioProcessResponse): string {
    if (response.action_type === ActionType.CLARIFY) {
      return response.clarify_question ?? response.result;
    }
    // PASTE / SHOW_MARKDOWN / TIP
    return response.result;
  }

  private outputTextQuick(response: TextQuickActionResponse): string {
    // PASTE / CLARIFY / SHOW_MARKDOWN / TIP 全部取 result
    return response.result;
  }

  // ==================== 改写与快捷指令 ====================
  // 【语音面板动作入口】以下 handle*/toggle*/persona* 等公开方法与安卓语音面板各按钮一一对应;
  // 由 VoicePanelView 经 ImeBus.onVoice*(→ ImeBusDelegateImpl)调用,业务逻辑与安卓一致。

  handleRewrite(): void {
    if (this.isBusy) {
      return;
    }

    if (!this.checkRecordPermission()) {
      this.requestRecordPermission();
      this.showError(MobileStrings.micPermission());
      return;
    }

    this.ensureInputAvailableForAction((): void => {
      const selectedText = this.currentSelectionText();
      if (selectedText.trim().length > 0) {
        this.pendingRewriteOriginal = selectedText;
        this.pendingRewriteTarget = RewriteTarget.SELECTED_TEXT;
      } else if (this.lastInsertedText.trim().length > 0) {
        this.pendingRewriteOriginal = this.lastInsertedText;
        this.pendingRewriteTarget = RewriteTarget.LAST_INSERTED;
      } else {
        this.pendingRewriteOriginal = '';
        this.pendingRewriteTarget = RewriteTarget.NONE;
      }
      this.startRecording(Operation.REWRITE);
    });
  }

  handleQuickAction(action: AndroidQuickAction): void {
    if (this.isBusy) {
      return;
    }
    this.ensureInputAvailableForAction((): void => {
      this.performQuickAction(action);
    });
  }

  private performQuickAction(action: AndroidQuickAction): void {
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.showUnavailable(BlockedReason.LOGIN_REQUIRED);
      return;
    }

    const selectedText = this.currentSelectionText();
    let target: RewriteTarget;
    let sourceText: string;
    if (selectedText.trim().length > 0) {
      target = RewriteTarget.SELECTED_TEXT;
      sourceText = selectedText;
    } else if (this.lastInsertedText.trim().length > 0) {
      target = RewriteTarget.LAST_INSERTED;
      sourceText = this.lastInsertedText;
    } else {
      this.showError(MobileStrings.noRewriteTarget());
      return;
    }

    this.isProcessing = true;
    this.errorMessage = '';
    this.statusText = MobileStrings.quickProcessing();
    this.refreshKeyboardUi();

    this.performQuickActionAsync(authHeader, action, sourceText, target);
  }

  private async performQuickActionAsync(
    authHeader: string,
    action: AndroidQuickAction,
    sourceText: string,
    target: RewriteTarget
  ): Promise<void> {
    try {
      const response = await this.requestQuickAction(authHeader, action, sourceText);
      this.rememberLiveCredits(response.credits_remaining);
      const output = this.outputTextQuick(response).trim();
      if (output.length === 0) {
        this.showError(MobileStrings.emptyRewrite());
        return;
      }
      this.applyProcessedText(output, target, sourceText, false);
      this.historyAddSuccess(
        response.operation,
        response.transcript ?? response.input_text,
        output,
        response.action_type.toString(),
        sourceText
      );
      this.statusText = MobileStrings.rewritten();
      this.errorMessage = '';
    } catch (err) {
      const e = err as Error;
      const historyOp = 'android_quick_' + action.toString();
      if (e instanceof InputUnavailableException) {
        this.historyAddFailed(historyOp, e.message !== '' ? e.message : MobileStrings.processFailed(), sourceText);
        this.showUnavailable(e.reason, e.message);
      } else {
        this.historyAddFailed(historyOp, e.message !== '' ? e.message : MobileStrings.processFailed(), sourceText);
        this.showError(e.message !== '' ? e.message : MobileStrings.processFailed());
      }
    } finally {
      this.isProcessing = false;
      this.refreshKeyboardUi();
    }
  }

  private async requestQuickAction(
    authHeader: string,
    action: AndroidQuickAction,
    sourceText: string
  ): Promise<TextQuickActionResponse> {
    const request: AndroidQuickActionRequest = {
      action: action,
      text: sourceText,
      source_operation: operationApiValue(this.pendingOperation)
    };
    try {
      const response = await ApiService.getInstance().quickAction(authHeader, request);
      return response;
    } catch (err) {
      throw this.quickActionError(authHeader, err as Error);
    }
  }

  private quickActionError(authHeader: string, e: Error): Error {
    const failure = this.parseApiFailure(e);
    if (failure.statusCode === 401 || failure.code === 'USER_BANNED') {
      AuthSession.clearIfCurrent(authHeader);
      return new InputUnavailableException(BlockedReason.LOGIN_REQUIRED, MobileStrings.sessionExpired());
    }
    if (failure.code === 'CREDITS_EXHAUSTED') {
      this.liveCreditsRemaining = 0;
      return new InputUnavailableException(BlockedReason.CREDITS_EXHAUSTED, MobileStrings.creditsExhausted());
    }
    return new Error(failure.message ?? MobileStrings.requestFailed(failure.statusCode));
  }

  // ==================== 文本落屏与编辑操作 ====================

  private applyProcessedText(
    output: string,
    target: RewriteTarget,
    replacedOverride: string | null,
    cacheForRestore: boolean
  ): void {
    let replacedText: string;
    if (replacedOverride !== null) {
      replacedText = replacedOverride;
    } else if (target === RewriteTarget.LAST_INSERTED) {
      replacedText = this.lastInsertedText;
    } else if (target === RewriteTarget.SELECTED_TEXT) {
      replacedText = this.currentSelectionText();
    } else {
      replacedText = '';
    }
    if (target === RewriteTarget.LAST_INSERTED && this.lastInsertedText.trim().length > 0) {
      this.deleteTextBeforeCursor(this.lastInsertedText);
    }
    const adapter = this.clientAdapter;
    if (adapter !== null) {
      adapter.commitText(output);
    }
    this.lastInsertedText = output;
    this.recordTextState(replacedText);
    this.recordTextState(output);
    if (cacheForRestore) {
      this.voiceRestoreText = output;
    }
    this.pendingRewriteOriginal = '';
    this.pendingRewriteTarget = RewriteTarget.NONE;
  }

  private handleBackspace(): void {
    const adapter = this.clientAdapter;
    if (adapter === null) {
      return;
    }
    const selectedText = adapter.getSelectedText();
    if (selectedText.length > 0) {
      // commitText('') 替换选区为空(适配器内部折叠选区并删除)
      adapter.commitText('');
      if (this.lastInsertedText === selectedText) {
        this.lastInsertedText = '';
      } else if (this.lastInsertedText.includes(selectedText)) {
        // Kotlin replaceFirst:JS 的 string.replace(str) 恰好只替换第一处
        this.lastInsertedText = this.lastInsertedText.replace(selectedText, '');
      }
    } else {
      adapter.deleteSurroundingText(1, 0);
      if (this.lastInsertedText.length > 0) {
        this.lastInsertedText = this.lastInsertedText.substring(0, this.lastInsertedText.length - 1);
      }
    }
    this.statusText = this.defaultTranscribeHint();
    this.refreshKeyboardUi();
  }

  handleClearInputText(): void {
    if (this.isBusy) {
      return;
    }
    const adapter = this.clientAdapter;
    if (adapter === null) {
      return;
    }
    this.handleClearInputTextAsync(adapter);
  }

  private async handleClearInputTextAsync(adapter: InputClientAdapter): Promise<void> {
    // 安卓走「全文选中提交空串 → 选区提交空串 → 前后逐段删除」三级兜底;
    // 鸿蒙无 ExtractedText/setSelection 全选 API,统一走等价的兜底路径:
    // finishComposing → 折叠选区并删除 → 删除光标前后各至多 100000 字符。
    await adapter.finishComposingAsync();
    await adapter.clearAllText(MAX_SURROUNDING_TEXT_DELETE_CHARS);

    this.operationTextHistory = [];
    this.lastInsertedText = '';
    this.voiceRestoreText = '';
    this.pendingRewriteOriginal = '';
    this.pendingRewriteTarget = RewriteTarget.NONE;
    this.statusText = MobileStrings.inputCleared();
    this.errorMessage = '';
    this.refreshKeyboardUi();
  }

  handleNewline(): void {
    const adapter = this.clientAdapter;
    if (adapter === null) {
      return;
    }
    this.handleNewlineAsync(adapter);
    this.lastInsertedText = '\n';
    this.recordTextState('\n');
    this.statusText = MobileStrings.inserted();
    this.errorMessage = '';
    this.refreshKeyboardUi();
  }

  private async handleNewlineAsync(adapter: InputClientAdapter): Promise<void> {
    const committed = await adapter.commitTextAsync('\n');
    if (!committed) {
      // 对应安卓的 sendKeyEvent(KEYCODE_ENTER) 兜底:鸿蒙发编辑器回车动作
      await adapter.sendEnterKeyAsync();
    }
  }

  // ==================== 打字键盘模式 ====================

  private ensureTypingStack(): void {
    if (this.typingCoordinator !== null) {
      return;
    }
    const ctx = this.context;
    const mic = this.keyboardMic;
    if (ctx === null || mic === null) {
      return;
    }
    const prefs = new TypingPreferences(ctx);
    this.typingPrefs = prefs;
    const undoManager = new TypingUndoManager();
    // 词库引擎装配走真实链路:DictionaryLoader.createEngine → (监听接线后)startLoad
    const loader = new DictionaryLoader(ctx);
    const engine = loader.createEngine();
    const imeCtx = new TypingImeContextImpl(this);
    this.typingImeContext = imeCtx;
    const sessionHost = new TypingSessionHost(ctx, imeCtx, prefs, this.composingBridge, undoManager);
    this.typingSessionHost = sessionHost;
    // 鸿蒙新增:预载打字偏好/剪贴板缓存(缓存先行语义,fire-and-forget)
    sessionHost.init().catch((e: Error): void => {
      Logger.w(TAG, 'typing sessionHost init failed: ' + e.message);
    });
    this.composingBridge.bind(
      (): ImeClientApi | undefined => this.clientAdapter ?? undefined,
      (): boolean => this.isKeyboardMicActive()
    );
    const micCoordinator = new KeyboardMicCoordinator(imeCtx, sessionHost, new KeyboardRealtimeMicApiImpl(mic));
    this.micCoordinator = micCoordinator;
    // 打字状态中枢:渲染出口绑定 ImeBus(ImeBus 实现 KeyboardRenderer)
    const controller = new KeyboardController(sessionHost, engine, this.composingBridge);
    controller.bind(ImeBus.getInstance());
    this.keyboardController = controller;
    this.layoutFactory = new KeyboardLayoutFactory(sessionHost);
    const coordinator = new TypingModeCoordinator(sessionHost, this.composingBridge, micCoordinator, engine);
    this.typingCoordinator = coordinator;
    // 安卓 typingView(真实 View)→ 鸿蒙适配器(controller 逻辑复位 + ImeBus 渲染刷新)
    coordinator.typingView = new TypingKeyboardViewAdapter(controller);
    // 候选栏状态提示回调 → 经 ImeBus 投递给打字键盘 UI
    sessionHost.setStatusCallback((msg?: string): void => {
      this.busTypingStatus(msg ?? null);
    });
    // 输入阻塞(引擎装载中/失败)→ ImeBus 遮罩
    sessionHost.setInputBlockedCallback((blocked: boolean): void => {
      ImeBus.getInstance().setInputBlocked(blocked);
    });
    // 监听已接好(coordinator 构造中 addLoadListener),触发词库异步加载
    loader.startLoad(engine);
  }

  /** ImeBusDelegate 查询/动作的转发目标(未就绪时为 null,delegate 侧回退默认值)。 */
  typingControllerOrNull(): KeyboardController | null {
    return this.keyboardController;
  }

  micCoordinatorOrNull(): KeyboardMicCoordinator | null {
    return this.micCoordinator;
  }

  /**
   * 构建当前键区行列(ImeBusDelegate.buildKeyRows):
   * KeyboardLayoutFactory.build(controller.layoutState()),并把 ENTER 键的 main
   * 替换为 controller.enterKeyLabel()(对齐安卓 rebuildKeyboard 内的 copy)。
   */
  buildKeyRowsForUi(): KeySpec[][] {
    const controller = this.keyboardController;
    const factory = this.layoutFactory;
    if (controller === null || factory === null) {
      return [];
    }
    const rows = factory.build(controller.layoutState());
    const enterLabel = controller.enterKeyLabel();
    const result: KeySpec[][] = [];
    for (let r = 0; r < rows.length; r++) {
      const row = rows[r];
      const outRow: KeySpec[] = [];
      for (let k = 0; k < row.length; k++) {
        const spec = row[k];
        if (spec.type === KeyType.ENTER) {
          outRow.push(new KeySpec(KeyType.ENTER, enterLabel, {
            sub: spec.sub,
            weight: spec.weight,
            value: spec.value,
            longValue: spec.longValue,
            shiftValue: spec.shiftValue
          }));
        } else {
          outRow.push(spec);
        }
      }
      result.push(outRow);
    }
    return result;
  }

  enterKeyboardMode(persistChoice: boolean = true): void {
    if (this.captureMode !== CaptureMode.IDLE) {
      const streamer = this.realtimeStreamer;
      if (streamer !== null) {
        streamer.stop();
      }
      const recorder = this.audioRecorder;
      if (recorder !== null) {
        try {
          recorder.stopRecording();
        } catch (e) {
          Logger.w(TAG, 'stopRecording on enterKeyboardMode failed: ' + (e as Error).message);
        }
      }
      this.captureMode = CaptureMode.IDLE;
    }
    this.symbolPanelVisible = false;
    this.personaPanelVisible = false;
    this.ensureTypingStack();
    const coordinator = this.typingCoordinator;
    if (coordinator !== null) {
      coordinator.enter();
    }
    // persistChoice=false:数字框等场景的自动切换,不覆盖用户手动选择的模式偏好
    const sessionHost = this.typingSessionHost;
    if (persistChoice && sessionHost !== null) {
      sessionHost.setLastModeKeyboard(true); // 记住:用户切到键盘模式
    }
    this.refreshKeyboardUi();
  }

  exitKeyboardMode(): void {
    const mic = this.keyboardMic;
    if (mic !== null && mic.isActive) {
      mic.stop();
    }
    const coordinator = this.typingCoordinator;
    if (coordinator !== null) {
      coordinator.exit();
    }
    const sessionHost = this.typingSessionHost;
    if (sessionHost !== null) {
      sessionHost.setLastModeKeyboard(false); // 记住:用户切回语音
    }
    this.refreshKeyboardUi();
  }

  onKeyboardMicActiveChanged(active: boolean): void {
    const micCoordinator = this.micCoordinator;
    if (micCoordinator !== null) {
      micCoordinator.onMicActiveChanged(active);
    }
  }

  onKeyboardMicError(kind: RealtimeAsrErrorKind, message: string): void {
    const micCoordinator = this.micCoordinator;
    if (micCoordinator !== null) {
      // 链路层错误不透传底层原文,统一换成本地化网络提示(对齐安卓)
      const display = kind === RealtimeAsrErrorKind.NETWORK ? MobileStrings.networkError() : message;
      micCoordinator.onMicError(display);
    }
  }

  // ==================== 退格长按连发(对应 installBackspaceRepeatTouch) ====================

  onBackspacePressDown(): void {
    this.backspaceRepeatSession += 1;
    const session = this.backspaceRepeatSession;
    this.backspaceRepeatActive = true;
    this.backspaceLongPressTriggered = false;
    this.clearBackspaceTimers();
    this.backspaceLongPressTimer = setTimeout((): void => {
      if (this.backspaceRepeatActive && session === this.backspaceRepeatSession) {
        this.backspaceLongPressTriggered = true;
        this.handleBackspace();
        this.backspaceRepeatTimer = setInterval((): void => {
          if (!this.backspaceRepeatActive) {
            return;
          }
          this.handleBackspace();
        }, BACKSPACE_REPEAT_INTERVAL_MS);
      }
    }, LONG_PRESS_TIMEOUT_MS);
  }

  onBackspacePressUp(): void {
    const wasLongPress = this.backspaceLongPressTriggered;
    this.stopBackspaceRepeat();
    if (!wasLongPress) {
      this.handleBackspace(); // 对应 view.performClick()
    }
  }

  onBackspacePressCancel(): void {
    this.stopBackspaceRepeat();
  }

  private stopBackspaceRepeat(): void {
    this.backspaceRepeatActive = false;
    this.backspaceRepeatSession += 1;
    this.clearBackspaceTimers();
  }

  private clearBackspaceTimers(): void {
    if (this.backspaceLongPressTimer >= 0) {
      clearTimeout(this.backspaceLongPressTimer);
      this.backspaceLongPressTimer = -1;
    }
    if (this.backspaceRepeatTimer >= 0) {
      clearInterval(this.backspaceRepeatTimer);
      this.backspaceRepeatTimer = -1;
    }
  }

  // ==================== 撤回 / 恢复 / 历史 ====================

  handleUndo(): void {
    if (this.operationTextHistory.length === 0) {
      this.statusText = this.defaultTranscribeHint();
      this.refreshKeyboardUi();
      return;
    }
    const currentText = this.operationTextHistory.pop() ?? '';
    this.deleteTextBeforeCursor(currentText);
    const previousText = this.operationTextHistory.length > 0
      ? this.operationTextHistory[this.operationTextHistory.length - 1]
      : '';
    if (previousText.trim().length > 0) {
      const adapter = this.clientAdapter;
      if (adapter !== null) {
        adapter.commitText(previousText);
      }
      this.lastInsertedText = previousText;
    } else {
      this.lastInsertedText = '';
    }
    this.statusText = this.defaultTranscribeHint();
    this.errorMessage = '';
    this.refreshKeyboardUi();
  }

  handleRestoreVoiceText(): void {
    const text = this.voiceRestoreText.trim();
    if (text.length === 0 || this.isBusy) {
      return;
    }
    const selectedText = this.currentSelectionText();
    let target: RewriteTarget;
    if (selectedText.trim().length > 0) {
      target = RewriteTarget.SELECTED_TEXT;
    } else if (this.lastInsertedText.trim().length > 0) {
      target = RewriteTarget.LAST_INSERTED;
    } else {
      target = RewriteTarget.NONE;
    }
    let replaced: string;
    if (target === RewriteTarget.SELECTED_TEXT) {
      replaced = selectedText;
    } else if (target === RewriteTarget.LAST_INSERTED) {
      replaced = this.lastInsertedText;
    } else {
      replaced = '';
    }
    this.applyProcessedText(text, target, replaced, false);
    this.statusText = MobileStrings.restoredVoice();
    this.errorMessage = '';
    this.refreshKeyboardUi();
  }

  private deleteLastInsertedText(): void {
    this.deleteTextBeforeCursor(this.lastInsertedText);
    this.lastInsertedText = '';
  }

  private deleteTextBeforeCursor(text: string): void {
    const adapter = this.clientAdapter;
    if (adapter === null) {
      return;
    }
    // 安卓逐字 deleteSurroundingText(1,0) × text.length;适配器按码点换算一次删除,净效果一致
    adapter.deleteTextBeforeCursor(text);
  }

  commitTextWithHistory(text: string): void {
    if (text.length === 0) {
      return;
    }
    const adapter = this.clientAdapter;
    if (adapter !== null) {
      adapter.commitText(text);
    }
    this.lastInsertedText = text;
    this.recordTextState(text);
    this.errorMessage = '';
    this.refreshKeyboardUi();
  }

  private recordTextState(text: string): void {
    if (text.trim().length === 0) {
      return;
    }
    if (this.operationTextHistory.length > 0 &&
      this.operationTextHistory[this.operationTextHistory.length - 1] === text) {
      return;
    }
    this.operationTextHistory.push(text);
    while (this.operationTextHistory.length > 20) {
      this.operationTextHistory.shift();
    }
  }

  private clearTemporaryTextHistory(): void {
    this.clearRealtimePreview();
    this.operationTextHistory = [];
    this.lastInsertedText = '';
    this.voiceRestoreText = '';
    this.pendingRewriteOriginal = '';
    this.pendingRewriteTarget = RewriteTarget.NONE;
  }

  private restoreRewriteIfNeeded(): void {
    this.pendingRewriteOriginal = '';
    this.pendingRewriteTarget = RewriteTarget.NONE;
  }

  private canRewrite(): boolean {
    return this.currentSelectionText().trim().length > 0 || this.lastInsertedText.trim().length > 0;
  }

  private currentSelectionText(): string {
    const adapter = this.clientAdapter;
    if (adapter === null) {
      return '';
    }
    return adapter.getSelectedText().trim();
  }

  // ==================== 服务端上下文(clipboard_history) ====================

  private async recentContextForServer(): Promise<string | null> {
    const snippets = await this.recentContextListForServer();
    if (snippets.length === 0) {
      return null;
    }
    return JSON.stringify(snippets);
  }

  private async recentContextListForServer(): Promise<string[]> {
    const adapter = this.clientAdapter;
    if (adapter === null) {
      return [];
    }
    const snippets: string[] = [];
    if (this.lastInsertedText.trim().length > 0) {
      snippets.push(this.lastInsertedText);
    }
    const surrounding = await this.surroundingText(adapter);
    if (surrounding.trim().length > 0) {
      snippets.push(surrounding);
    }
    // distinct().take(3)
    const distinct: string[] = [];
    for (let i = 0; i < snippets.length; i++) {
      if (!distinct.includes(snippets[i])) {
        distinct.push(snippets[i]);
      }
    }
    return distinct.slice(0, 3);
  }

  private async surroundingText(adapter: InputClientAdapter): Promise<string> {
    // 走入队版本:保证读取发生在此前所有写操作之后(与安卓 InputConnection 时序一致)
    const before = await adapter.getTextBeforeCursorAsync(280);
    const after = await adapter.getTextAfterCursorAsync(120);
    return (before + after).trim();
  }

  private defaultTranscribeHint(): string {
    return this.realtimeRecognitionEnabled ? MobileStrings.holdToSpeak() : MobileStrings.tapToSpeak();
  }

  // ==================== 实时预览(composing 模拟)与打字机 ====================

  private shouldAcceptRealtimePreview(client: RealtimeAsrWebSocketClient): boolean {
    return this.realtimeAcceptingPreview &&
      this.realtimeWsClient === client &&
      !this.realtimeFinishing &&
      !this.isProcessing;
  }

  private replaceRealtimePreview(text: string): void {
    if (!this.realtimeAcceptingPreview) {
      return;
    }
    const preview = text.trim();
    if (preview.length === 0) {
      this.realtimeTypewriter.reset();
      this.clearRealtimePreview();
      this.realtimeTranscript = '';
      return;
    }
    // realtimeTranscript 始终保存"完整目标整句"(供 stop 时作为 clientAsrText 传给后端),
    // 与打字机当前揭示到的前缀无关,避免丢字。
    this.realtimeTranscript = preview;
    this.realtimeTypewriter.setTarget(preview);
  }

  /**
   * 把打字机"已揭示前缀"渲染到 composing 预览区,并维护预览长度状态。
   * 注意:不修改 realtimeTranscript(完整目标),只负责显示。
   * 鸿蒙侧 setComposingText 由 InputClientAdapter 的组合缓冲模拟,恒定成功,
   * 因此安卓的 delete+commit 降级分支在此不可达(保留语义注释)。
   */
  private applyRealtimePreview(shown: string): void {
    const adapter = this.clientAdapter;
    if (adapter === null) {
      return;
    }
    if (shown.length === 0) {
      this.clearRealtimePreview();
      return;
    }
    adapter.setComposing(shown);
    this.realtimePreviewComposing = true;
    this.realtimePreviewLength = shown.length;
  }

  private clearRealtimePreview(): void {
    // 任何清空预览的路径都同时停掉打字机,避免遗留 ticker 在已失效的会话上继续渲染。
    this.realtimeTypewriter.reset();
    const adapter = this.clientAdapter;
    if (adapter === null) {
      this.realtimePreviewLength = 0;
      this.realtimePreviewComposing = false;
      return;
    }
    if (this.realtimePreviewLength > 0) {
      if (this.realtimePreviewComposing) {
        adapter.setComposing('');
        adapter.finishComposing();
      } else {
        adapter.deleteSurroundingText(this.realtimePreviewLength, 0);
      }
    }
    this.realtimePreviewLength = 0;
    this.realtimePreviewComposing = false;
  }

  private commitRealtimeFinalText(text: string): void {
    const output = text.trim();
    const adapter = this.clientAdapter;
    if (adapter === null) {
      this.clearRealtimePreview();
      this.commitTextWithHistory(output);
      return;
    }
    if (this.realtimePreviewLength > 0 && this.realtimePreviewComposing) {
      // commitText 在组合中会替换组合区(适配器模拟安卓语义)
      adapter.commitText(output);
    } else {
      if (this.realtimePreviewLength > 0) {
        adapter.deleteSurroundingText(this.realtimePreviewLength, 0);
      }
      adapter.commitText(output);
    }
    this.realtimePreviewLength = 0;
    this.realtimePreviewComposing = false;
    this.realtimeTranscript = '';
    this.lastInsertedText = output;
    this.recordTextState(output);
    this.voiceRestoreText = output;
  }

  // ==================== 状态文案与 UI 同步 ====================

  private currentStatusText(): string {
    if (this.blockedReason !== null) {
      return MobileStrings.inputUnavailableTitle(this.blockedReason === BlockedReason.CREDITS_EXHAUSTED);
    }
    if (!this.isLoggedIn()) {
      return MobileStrings.loginRequired();
    }
    if (this.accountStatusLoading) {
      return MobileStrings.checkingAccount();
    }
    if (this.isProcessing) {
      return this.statusText;
    }
    if (this.captureMode === CaptureMode.REALTIME) {
      const m = Math.floor(this.realtimeRemainingSec / 60);
      const s = this.realtimeRemainingSec % 60;
      const base = this.statusText.trim().length > 0 ? this.statusText : MobileStrings.releaseToSend();
      return base + '\n' + pad2(m) + ':' + pad2(s);
    }
    if (this.captureMode === CaptureMode.SYNC) {
      const m = Math.floor(this.recordingRemainingSec / 60);
      const s = this.recordingRemainingSec % 60;
      return this.statusText + '\n' + pad2(m) + ':' + pad2(s);
    }
    if (this.canRewrite()) {
      return this.statusText.trim().length > 0 ? this.statusText : MobileStrings.rewriteHint();
    }
    return this.statusText.trim().length > 0 ? this.statusText : this.defaultTranscribeHint();
  }

  showError(message: string): void {
    this.errorMessage = message;
    this.statusText = message;
    this.refreshKeyboardUi();
  }

  /**
   * 对应安卓 refreshKeyboardUi():安卓直接改视图;鸿蒙经 ImeBus 的具名方法驱动 UI ——
   *  - 面板模式:打字键盘(TYPING)独占 / 语音面板(VOICE);
   *  - 打字态:rebuildKeyboard 全量拉取逻辑层快照(键区/子页/候选栏按钮态);
   *  - 语音态:录音球状态(setOrbState)+ 语音面板完整快照(setVoicePanelState,
   *    快捷行/符号板/人设板/不可用面板/状态条全部经此驱动 VoicePanelView)。
   */
  refreshKeyboardUi(): void {
    const bus = ImeBus.getInstance();
    const coordinator = this.typingCoordinator;
    const typingActive = coordinator !== null && coordinator.active;
    const level = this.captureMode === CaptureMode.REALTIME ? this.realtimeAudioLevel : this.audioLevel;
    if (typingActive) {
      bus.setOrbVisible(false);
      bus.setPanelMode(ImePanelMode.TYPING);
      // 打字键盘全量快照刷新(shift/语言/子页/候选栏按钮态经 delegate 拉取)
      bus.rebuildKeyboard();
    } else {
      bus.setPanelMode(ImePanelMode.VOICE);
      bus.setOrbVisible(true);
      // 对齐安卓 recordButton.setOrbState:loggedIn 需同时满足「已登录且未被拦截」
      bus.setOrbState(
        this.captureMode !== CaptureMode.IDLE,
        this.isProcessing,
        this.isLoggedIn() && this.blockedReason === null,
        clamp01(level / 100)
      );
      // 语音面板完整快照(VoicePanelView 的唯一状态源)
      bus.setVoicePanelState(this.buildVoicePanelUiState());
      const status = this.errorMessage.trim().length > 0 ? this.errorMessage : this.currentStatusText();
      bus.showStatus(status);
    }
  }

  /** ImeVoicePanelState → ImeBus 响应式快照(逐字段拷贝,UI 只读)。 */
  private buildVoicePanelUiState(): ImeVoicePanelUiState {
    const s = this.voicePanelState();
    const v = new ImeVoicePanelUiState();
    v.loggedIn = s.loggedIn;
    v.unavailable = s.unavailable;
    v.blockedReasonCredits = s.blockedReasonCredits;
    v.statusText = s.statusText;
    v.isError = s.isError;
    v.recording = s.recording;
    v.processing = s.processing;
    v.accountStatusLoading = s.accountStatusLoading;
    v.recordEnabled = s.recordEnabled;
    v.undoEnabled = s.undoEnabled;
    v.restoreEnabled = s.restoreEnabled;
    v.rewriteEnabled = s.rewriteEnabled;
    v.fastModeEnabled = s.fastModeEnabled;
    v.realtimeRecognitionEnabled = s.realtimeRecognitionEnabled;
    v.rightHandLayout = s.rightHandLayout;
    v.symbolPanelVisible = s.symbolPanelVisible;
    v.personaPanelVisible = s.personaPanelVisible;
    v.voiceSymbolCategory = s.voiceSymbolCategory;
    v.recentSymbols = s.recentSymbols;
    v.personas = s.personas;
    v.personaDetail = s.personaDetail;
    v.personasLoading = s.personasLoading;
    v.personasRefreshing = s.personasRefreshing;
    v.pendingPersonaActionId = s.pendingPersonaActionId;
    return v;
  }

  /**
   * 语音面板完整状态快照(原 ImeUiState 的等价保留):refreshKeyboardUi 每次经
   * buildVoicePanelUiState 拷贝为 ImeBus 响应式快照,驱动 VoicePanelView
   * (快捷行/符号板/人设板/不可用面板)全量刷新。
   */
  voicePanelState(): ImeVoicePanelState {
    const coordinator = this.typingCoordinator;
    const typingActive = coordinator !== null && coordinator.active;
    const loggedIn = this.isLoggedIn();
    const isUnavailable = this.blockedReason !== null && !this.isBusy;
    const level = this.captureMode === CaptureMode.REALTIME ? this.realtimeAudioLevel : this.audioLevel;
    const state: ImeVoicePanelState = {
      typingActive: typingActive,
      loggedIn: loggedIn,
      unavailable: isUnavailable,
      blockedReasonCredits: this.blockedReason === BlockedReason.CREDITS_EXHAUSTED,
      statusText: this.errorMessage.trim().length > 0 ? this.errorMessage : this.currentStatusText(),
      isError: this.errorMessage.trim().length > 0,
      recording: this.captureMode !== CaptureMode.IDLE,
      processing: this.isProcessing,
      accountStatusLoading: this.accountStatusLoading,
      recordEnabled: !this.isProcessing && !this.accountStatusLoading && loggedIn && this.blockedReason === null,
      audioLevel: clamp01(level / 100),
      undoEnabled: this.operationTextHistory.length > 0 && !this.isBusy,
      restoreEnabled: this.voiceRestoreText.trim().length > 0 && !this.isBusy,
      rewriteEnabled: loggedIn && this.blockedReason === null && !this.accountStatusLoading && !this.isBusy,
      fastModeEnabled: this.fastModeEnabled,
      realtimeRecognitionEnabled: this.realtimeRecognitionEnabled,
      rightHandLayout: this.rightHandLayout,
      symbolPanelVisible: this.symbolPanelVisible,
      personaPanelVisible: this.personaPanelVisible,
      voiceSymbolCategory: this.voiceSymbolCategory,
      recentSymbols: this.recentSymbolsCache,
      personas: this.personas,
      personaDetail: this.personaDetail,
      personasLoading: this.personasLoading,
      personasRefreshing: this.personasRefreshing,
      pendingPersonaActionId: this.pendingPersonaActionId
    };
    return state;
  }

  // ---------- ImeBus 轻量通道(高频,不走整面板快照) ----------

  /** 录音球声浪能量(非响应式原始通道,RecordOrbView 帧循环消费)。 */
  private busAudioLevel(level: number): void {
    ImeBus.getInstance().updateOrbLevel(level);
  }

  /** 键盘内录音波形能量(非响应式原始通道)。 */
  private busMicLevel(level: number): void {
    ImeBus.getInstance().updateMicLevel(level);
  }

  /** 键盘内录音剩余进度 0-1(麦克风外环倒计时)。 */
  private busMicProgress(progress: number): void {
    ImeBus.getInstance().setMicProgress(progress);
  }

  /** 打字候选栏状态提示(3s 自动消失;null 清空)。 */
  busTypingStatus(message: string | null): void {
    ImeBus.getInstance().showStatus(message);
  }

  // ==================== UI 事件对接(对应各 View 的 OnClickListener/OnTouchListener) ====================

  /**
   * 绑定 UI → 逻辑层 delegate(ImeBus 真实接口):打字键盘全部视图事件、
   * 候选栏麦克风与录音球手势、语音面板全部动作(改写/快捷指令/符号板/人设板/
   * 切输入法等,见「语音面板动作入口」段)经 ImeBusDelegateImpl 进入本服务/KeyboardController。
   */
  private bindUiActions(): void {
    ImeBus.getInstance().bindDelegate(new ImeBusDelegateImpl(this));
  }

  // ==================== 布局/快速模式/面板开关 ====================

  toggleHandLayout(): void {
    this.rightHandLayout = !this.rightHandLayout;
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putBoolean(PREF_HAND_LAYOUT, this.rightHandLayout);
    }
    // 快捷键行镜像/过场动画由 UI 层依据 rightHandLayout 状态自行处理
    this.refreshKeyboardUi();
  }

  toggleFastMode(): void {
    this.fastModeEnabled = !this.fastModeEnabled;
    const prefs = this.prefs;
    if (prefs !== null) {
      prefs.putBoolean(PREF_FAST_MODE, this.fastModeEnabled);
    }
    this.refreshKeyboardUi();
  }

  toggleSymbolPanel(): void {
    this.symbolPanelVisible = !this.symbolPanelVisible;
    if (this.symbolPanelVisible) {
      this.personaPanelVisible = false;
      this.personaDetail = null;
      // 每次进入符号面板默认「最近」,不记忆上次选中的分类
      this.voiceSymbolCategory = SymbolData.RECENT_ID;
      this.refreshSymbolPanelState();
    }
    this.refreshKeyboardUi();
  }

  togglePersonaPanel(): void {
    this.personaPanelVisible = !this.personaPanelVisible;
    if (this.personaPanelVisible) {
      this.symbolPanelVisible = false;
      this.personaDetail = null;
      this.loadPersonasForPanel(this.personas.length === 0);
    }
    this.refreshKeyboardUi();
  }

  /** 对应安卓 rebuildSymbolPanel 的数据部分(网格渲染在 UI 层)。 */
  private refreshSymbolPanelState(): void {
    const prefs = this.typingPrefs;
    if (prefs === null) {
      return;
    }
    this.recentSymbolsCache = prefs.recentSymbols();
    if (this.voiceSymbolCategory === SymbolData.RECENT_ID && this.recentSymbolsCache.length === 0) {
      this.voiceSymbolCategory = 'zh';
    }
  }

  selectSymbolCategory(id: string): void {
    this.voiceSymbolCategory = id;
    this.refreshSymbolPanelState();
    this.refreshKeyboardUi();
  }

  /** 符号点击:直接提交(不入撤回历史,与安卓一致)+ 记录最近使用。 */
  commitSymbol(value: string): void {
    const adapter = this.clientAdapter;
    if (adapter !== null) {
      adapter.commitText(value);
    }
    const prefs = this.typingPrefs;
    if (prefs !== null) {
      prefs.recordRecentSymbol(value);
      this.recentSymbolsCache = prefs.recentSymbols();
    }
    this.refreshKeyboardUi();
  }

  // ==================== 切换输入法 / 打开主应用(不可用面板动作) ====================

  showInputMethodPicker(): void {
    try {
      inputMethod.getSetting().showOptionalInputMethods();
    } catch (e) {
      Logger.w(TAG, 'showOptionalInputMethods failed: ' + (e as Error).message);
    }
  }

  openMainApp(): void {
    const ctx = this.context;
    if (ctx === null) {
      return;
    }
    try {
      const want: Want = {
        bundleName: 'com.lobster.input',
        abilityName: 'EntryAbility'
      };
      // IME 扩展上下文才有 startAbility(API 12+);onCreate 传入的即 InputMethodExtensionContext
      (ctx as InputMethodExtensionContext).startAbility(want).catch((e: Error): void => {
        Logger.w(TAG, 'startAbility failed: ' + e.message);
      });
    } catch (e) {
      Logger.w(TAG, 'openMainApp failed: ' + (e as Error).message);
    }
  }

  /** 按键触感反馈(对应 performHapticFeedback(KEYBOARD_TAP);需 ohos.permission.VIBRATE)。 */
  performKeyHaptic(): void {
    try {
      vibrator.startVibration(
        { type: 'time', duration: 15 },
        { id: 0, usage: 'touch' }
      );
    } catch (e) {
      Logger.w(TAG, 'performKeyHaptic failed: ' + (e as Error).message);
    }
  }

  // ==================== 人设面板(与安卓 persona 全流程一致) ====================

  /** 人设面板「刷新」按钮入口(对应安卓 loadPersonasForPanel(showLoading = personas.isEmpty()))。 */
  refreshPersonas(): void {
    this.loadPersonasForPanel(this.personas.length === 0);
  }

  loadPersonasForPanel(showLoading: boolean): void {
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.showError(MobileStrings.loginRequired());
      return;
    }
    this.personasLoading = showLoading;
    this.personasRefreshing = !showLoading;
    if (showLoading || this.personaPanelVisible) {
      this.refreshKeyboardUi();
    }
    this.loadPersonasAsync(authHeader);
  }

  private async loadPersonasAsync(authHeader: string): Promise<void> {
    try {
      const response = await ApiService.getInstance().getPersonas(authHeader);
      this.replacePanelPersonas(response.personas);
      this.errorMessage = '';
    } catch (err) {
      const e = this.personaApiError(authHeader, err as Error);
      this.showError(e.message !== '' ? e.message : MobileStrings.mainLoadPersonasFailed());
    } finally {
      this.personasLoading = false;
      this.personasRefreshing = false;
      this.refreshKeyboardUi();
    }
  }

  openPersonaDetail(id: string): void {
    // 对应安卓列表行点击:内置人设不可进详情
    let found: PersonaItem | null = null;
    for (let i = 0; i < this.personas.length; i++) {
      if (this.personas[i].id === id) {
        found = this.personas[i];
        break;
      }
    }
    if (found === null || found.is_builtin) {
      return;
    }
    this.personaDetail = found;
    this.refreshKeyboardUi();
  }

  onPersonaBack(): void {
    if (this.personaDetail !== null) {
      this.personaDetail = null;
      this.refreshKeyboardUi();
    } else {
      this.personaPanelVisible = false;
      this.refreshKeyboardUi();
    }
  }

  onPersonaActivate(id: string): void {
    let found: PersonaItem | null = null;
    for (let i = 0; i < this.personas.length; i++) {
      if (this.personas[i].id === id) {
        found = this.personas[i];
        break;
      }
    }
    if (found === null) {
      return;
    }
    if (found.is_active) {
      this.deactivatePersonasForPanel();
    } else {
      this.activatePersonaForPanel(found);
    }
  }

  private activatePersonaForPanel(persona: PersonaItem): void {
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.showError(MobileStrings.loginRequired());
      return;
    }
    this.pendingPersonaActionId = persona.id;
    this.refreshKeyboardUi();
    this.activatePersonaAsync(authHeader, persona);
  }

  private async activatePersonaAsync(authHeader: string, persona: PersonaItem): Promise<void> {
    try {
      const activated = await ApiService.getInstance().activatePersona(authHeader, persona.id);
      this.applyActivatedPersona(activated);
      this.pendingPersonaActionId = null;
      this.refreshKeyboardUi();
      this.loadPersonasForPanel(false);
    } catch (err) {
      const e = this.personaApiError(authHeader, err as Error);
      this.pendingPersonaActionId = null;
      this.showError(e.message !== '' ? e.message : MobileStrings.mainActivatePersonaFailed());
      this.refreshKeyboardUi();
    }
  }

  deactivatePersonasForPanel(): void {
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.showError(MobileStrings.loginRequired());
      return;
    }
    let activeId: string | null = null;
    for (let i = 0; i < this.personas.length; i++) {
      if (this.personas[i].is_active) {
        activeId = this.personas[i].id;
        break;
      }
    }
    if (activeId === null && this.personaDetail !== null) {
      activeId = this.personaDetail.id;
    }
    this.pendingPersonaActionId = activeId;
    this.refreshKeyboardUi();
    this.deactivatePersonasAsync(authHeader);
  }

  private async deactivatePersonasAsync(authHeader: string): Promise<void> {
    try {
      await ApiService.getInstance().deactivatePersonas(authHeader);
      this.clearActivePanelPersona();
      this.pendingPersonaActionId = null;
      this.refreshKeyboardUi();
      this.loadPersonasForPanel(false);
    } catch (err) {
      const e = this.personaApiError(authHeader, err as Error);
      this.pendingPersonaActionId = null;
      this.showError(e.message !== '' ? e.message : MobileStrings.mainActivatePersonaFailed());
      this.refreshKeyboardUi();
    }
  }

  onPersonaToggleModule(id: string, module: string): void {
    let found: PersonaItem | null = null;
    for (let i = 0; i < this.personas.length; i++) {
      if (this.personas[i].id === id) {
        found = this.personas[i];
        break;
      }
    }
    if (found === null && this.personaDetail !== null && this.personaDetail.id === id) {
      found = this.personaDetail;
    }
    if (found === null) {
      return;
    }
    const personaModule = module === 'rewrite' ? PersonaModule.REWRITE : PersonaModule.TRANSCRIBE;
    this.togglePersonaModule(found, personaModule);
  }

  private togglePersonaModule(persona: PersonaItem, module: PersonaModule): void {
    const authHeader = this.getAuthHeader();
    if (authHeader === null) {
      this.showError(MobileStrings.loginRequired());
      return;
    }
    const current = persona.prompts;
    let updated: PersonaPrompts;
    if (module === PersonaModule.TRANSCRIBE) {
      updated = {
        transcribe_prompt: current.transcribe_prompt,
        transcribe_enabled: !current.transcribe_enabled && isPromptConfigured(current.transcribe_prompt),
        rewrite_prompt: current.rewrite_prompt,
        rewrite_enabled: current.rewrite_enabled,
        intent_hint: current.intent_hint,
        intent_enabled: current.intent_enabled
      };
    } else {
      updated = {
        transcribe_prompt: current.transcribe_prompt,
        transcribe_enabled: current.transcribe_enabled,
        rewrite_prompt: current.rewrite_prompt,
        rewrite_enabled: !current.rewrite_enabled && isPromptConfigured(current.rewrite_prompt),
        intent_hint: current.intent_hint,
        intent_enabled: current.intent_enabled
      };
    }
    this.pendingPersonaActionId = persona.id;
    this.refreshKeyboardUi();
    this.togglePersonaModuleAsync(authHeader, persona, updated);
  }

  private async togglePersonaModuleAsync(
    authHeader: string,
    persona: PersonaItem,
    updated: PersonaPrompts
  ): Promise<void> {
    try {
      const body: PersonaUpdateBody = {
        name: null,
        description: null,
        prompts: updated
      };
      const saved = await ApiService.getInstance().updatePersona(authHeader, persona.id, body);
      this.replacePanelPersona(saved);
      this.pendingPersonaActionId = null;
      this.refreshKeyboardUi();
      this.loadPersonasForPanel(false);
    } catch (err) {
      const e = this.personaApiError(authHeader, err as Error);
      this.pendingPersonaActionId = null;
      this.showError(e.message !== '' ? e.message : MobileStrings.mainSavePersonaFailed());
      this.refreshKeyboardUi();
    }
  }

  private replacePanelPersonas(next: PersonaItem[]): void {
    this.personas = next;
    const selected = this.personaDetail;
    if (selected !== null) {
      let match: PersonaItem | null = null;
      for (let i = 0; i < this.personas.length; i++) {
        if (this.personas[i].id === selected.id) {
          match = this.personas[i];
          break;
        }
      }
      this.personaDetail = match;
    }
  }

  private replacePanelPersona(updated: PersonaItem): void {
    const next: PersonaItem[] = [];
    for (let i = 0; i < this.personas.length; i++) {
      next.push(this.personas[i].id === updated.id ? updated : this.personas[i]);
    }
    this.personas = next;
    const selected = this.personaDetail;
    if (selected !== null && selected.id === updated.id) {
      this.personaDetail = updated;
    }
  }

  private applyActivatedPersona(activated: PersonaItem): void {
    const next: PersonaItem[] = [];
    for (let i = 0; i < this.personas.length; i++) {
      const persona = this.personas[i];
      if (persona.id === activated.id) {
        next.push(activated);
      } else {
        next.push(this.personaWithActive(persona, false));
      }
    }
    this.personas = next;
    const selected = this.personaDetail;
    if (selected !== null) {
      let match: PersonaItem | null = null;
      for (let i = 0; i < this.personas.length; i++) {
        if (this.personas[i].id === selected.id) {
          match = this.personas[i];
          break;
        }
      }
      this.personaDetail = match !== null ? match : this.personaWithActive(selected, false);
    }
  }

  private clearActivePanelPersona(): void {
    const next: PersonaItem[] = [];
    for (let i = 0; i < this.personas.length; i++) {
      const persona = this.personas[i];
      if (persona.is_builtin) {
        next.push(this.personaWithActive(persona, false));
      } else {
        next.push(this.personaWithModulesDisabled(persona));
      }
    }
    this.personas = next;
    const selected = this.personaDetail;
    if (selected !== null) {
      this.personaDetail = this.personaWithModulesDisabled(selected);
    }
  }

  /** persona.copy(isActive = x) 的显式等价(ArkTS 无数据类 copy)。 */
  private personaWithActive(persona: PersonaItem, isActive: boolean): PersonaItem {
    const copy: PersonaItem = {
      id: persona.id,
      name: persona.name,
      description: persona.description,
      is_active: isActive,
      is_builtin: persona.is_builtin,
      prompts: persona.prompts
    };
    return copy;
  }

  /** persona.copy(isActive=false, prompts=全部模块关闭) 的显式等价。 */
  private personaWithModulesDisabled(persona: PersonaItem): PersonaItem {
    const prompts: PersonaPrompts = {
      transcribe_prompt: persona.prompts.transcribe_prompt,
      transcribe_enabled: false,
      rewrite_prompt: persona.prompts.rewrite_prompt,
      rewrite_enabled: false,
      intent_hint: persona.prompts.intent_hint,
      intent_enabled: false
    };
    const copy: PersonaItem = {
      id: persona.id,
      name: persona.name,
      description: persona.description,
      is_active: false,
      is_builtin: persona.is_builtin,
      prompts: prompts
    };
    return copy;
  }

  private personaApiError(authHeader: string, e: Error): Error {
    const failure = this.parseApiFailure(e);
    if (failure.statusCode === 401 || failure.code === 'USER_BANNED') {
      AuthSession.clearIfCurrent(authHeader);
      return new Error(MobileStrings.sessionExpired());
    }
    return new Error(failure.message ?? MobileStrings.requestFailed(failure.statusCode));
  }

  // ==================== 错误归一化与历史 ====================

  /**
   * 把基础层抛出的异常归一化为 { statusCode, code, message }:
   * - ApiException(HttpClient 非 2xx 统一封装):取 statusCode 与已解析的 ApiErrorResponse;
   *   UNAUTHORIZED/USER_BANNED 两种 kind 无 errorResponse,按语义映射到 401 / USER_BANNED code;
   * - 其它异常:仅取 message。
   */
  private parseApiFailure(e: Error): ApiFailureInfo {
    let statusCode = 0;
    let code: string | null = null;
    let message: string | null = e.message.length > 0 ? e.message : null;
    if (e instanceof ApiException) {
      statusCode = e.statusCode;
      if (e.kind === ApiExceptionKind.USER_BANNED) {
        code = 'USER_BANNED';
      }
      const apiError = e.errorResponse;
      if (apiError !== null) {
        code = apiError.code;
        if (apiError.message.length > 0) {
          message = apiError.message;
        }
      }
    }
    const info: ApiFailureInfo = { statusCode: statusCode, code: code, message: message };
    return info;
  }

  private tryParseApiError(text: string | null): ApiErrorResponse | null {
    if (text === null || text.trim().length === 0) {
      return null;
    }
    try {
      return parseApiErrorResponse(text);
    } catch (e) {
      return null;
    }
  }

  private historyAddSuccess(
    operation: string,
    transcript: string,
    result: string,
    actionType: string | null,
    selectedText: string | null
  ): void {
    const store = this.historyStore;
    if (store !== null) {
      store.addSuccess(operation, transcript, result, actionType, selectedText);
    }
  }

  private historyAddFailed(operation: string, errorMessage: string, selectedText: string | null): void {
    const store = this.historyStore;
    if (store !== null) {
      store.addFailed(operation, errorMessage, selectedText);
    }
  }

  // ==================== 工具 ====================

  private deleteAudioFile(filePath: string): void {
    try {
      fs.unlinkSync(filePath);
    } catch (e) {
      Logger.w(TAG, 'deleteAudioFile failed: ' + (e as Error).message);
    }
  }
}
