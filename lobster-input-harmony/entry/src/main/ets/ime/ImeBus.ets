/**
 * ImeBus:键盘 UI 层(ets/ime/view/**)与逻辑层(ets/keyboard/typing/**)之间的全局单例状态桥。
 *
 * 职责划分(对齐安卓 TypingKeyboardView 的中介角色):
 *  - 逻辑层 → UI:ImeBus 实现 KeyboardRenderer;KeyboardController.bind(ImeBus.getInstance())
 *    后,rebuildKeyboard/renderCandidates/... 会把数据快照写入 @Observed 的 ImeBusState,
 *    KeyboardRoot 及子组件响应式刷新。
 *  - UI → 逻辑:视图事件(按键/候选点击/麦克风)统一走 onKeyTap/onCandidateSelected/... 转发
 *    到 ImeBusDelegate(由 IME 服务层实现,内部持有 KeyboardController / KeyboardMicCoordinator),
 *    UI 不直接持有 InputClient。
 *  - 高频音量/进度(每音频帧)走非响应式原始字段(micLevelRaw 等),由波形/录音球的
 *    帧循环轮询消费,避免高频触发整面板重渲染(对齐安卓 RecordOrbView.updateLevel 的设计)。
 */
import { KeySpec, KeyType } from '../keyboard/typing/KeyModels'
import { Candidate } from '../keyboard/pinyin/PinyinEngine'
import { PinyinLoadState } from '../keyboard/pinyin/PinyinLoadState'
import { KeyboardRenderer } from '../keyboard/typing/KeyboardRenderer'
import { AndroidQuickAction, PersonaItem } from '../data/model/ApiModels'

/**
 * 语音面板完整 UI 快照(响应式消费端):字段与 LobsterImeService.ImeVoicePanelState 一一对应,
 * 由服务层 refreshKeyboardUi() 全量构造后经 ImeBus.setVoicePanelState 整体替换写入
 * (整体替换 = @Observed 第一层赋值,可靠触发语音面板重渲染;UI 只读)。
 */
export class ImeVoicePanelUiState {
  loggedIn: boolean = true
  /** 输入不可用(未登录/积分耗尽,显示不可用面板)。 */
  unavailable: boolean = false
  /** 不可用原因是否为积分耗尽(false=未登录)。 */
  blockedReasonCredits: boolean = false
  statusText: string = ''
  /** 状态条是否为错误红字。 */
  isError: boolean = false
  recording: boolean = false
  processing: boolean = false
  accountStatusLoading: boolean = false
  recordEnabled: boolean = true
  undoEnabled: boolean = false
  restoreEnabled: boolean = false
  rewriteEnabled: boolean = true
  fastModeEnabled: boolean = false
  realtimeRecognitionEnabled: boolean = false
  rightHandLayout: boolean = true
  symbolPanelVisible: boolean = false
  personaPanelVisible: boolean = false
  /** 语音符号面板当前分类 id(SymbolData.RECENT_ID / 'zh' / ...)。 */
  voiceSymbolCategory: string = 'recent'
  recentSymbols: string[] = []
  personas: PersonaItem[] = []
  personaDetail: PersonaItem | null = null
  personasLoading: boolean = false
  personasRefreshing: boolean = false
  /** 正在等待服务端响应的人设 id(按钮显示「处理中」并禁用其它人设操作)。 */
  pendingPersonaActionId: string | null = null
}

/** 面板子页类型(rebuildKeyboard 时由逻辑层查询快照)。 */
export class ImePageKind {
  static readonly KEYS: string = 'keys'
  static readonly TOOLS: string = 'tools'
  static readonly EMOJI: string = 'emoji'
  static readonly CLIP: string = 'clip'
  static readonly SYM_BOARD: string = 'symboard'
}

/** 面板整体模式:打字键盘 / 语音面板(录音球)。 */
export class ImePanelMode {
  static readonly TYPING: string = 'typing'
  static readonly VOICE: string = 'voice'
}

/** 触感反馈类型(delegate.performHaptic 参数)。 */
export class HapticKind {
  static readonly TAP: string = 'tap'
  static readonly LONG_PRESS: string = 'longPress'
}

/**
 * UI → 逻辑层的对接接口,由 IME 服务层实现(内部组合 KeyboardController /
 * KeyboardLayoutFactory / KeyboardMicCoordinator,方法名与 Kotlin 同名或一一对应)。
 */
export interface ImeBusDelegate {
  /**
   * 构建当前键区行列 = KeyboardLayoutFactory.build(controller.layoutState())。
   * 约定:ENTER 键的 main 已替换为 controller.enterKeyLabel()(对齐安卓 rebuildKeyboard 内的 copy)。
   */
  buildKeyRows(): KeySpec[][]

  // ---- 控制器查询(与 KeyboardController 同名)----
  isToolsPage(): boolean
  isEmojiPage(): boolean
  isClipPage(): boolean
  isSymBoardPage(): boolean
  isChineseMode(): boolean
  /** = controller.layoutState().nineGrid */
  isNineGrid(): boolean
  /** 当前输入语种 code:'zh' | 'en' | 'ru' | 'ko'(= controller.currentLang().code)。 */
  currentLangCode(): string
  isShiftActive(): boolean
  isCapsLock(): boolean
  isPasswordField(): boolean
  isMicAvailable(): boolean
  canUndo(): boolean
  returnVoiceText(): string
  layoutSwitchText(): string

  // ---- 子页数据 ----
  recentEmojis(): string[]
  recentSymbols(): string[]
  clipboardHistory(): string[]
  quickPhrases(): string[]

  // ---- 动作(与 KeyboardController 同名)----
  handleKey(spec: KeySpec): void
  /** 无参功能键快捷通道(子页返回=ALPHA、footer 删除=DELETE、撤销=UNDO),等价 handleKey(KeySpec(type))。 */
  handleSimpleKey(type: KeyType): void
  handleLongPress(spec: KeySpec): void
  onDeletePressDown(): void
  onDeletePressUp(): void
  /** 空格横向滑动移光标:steps 为带符号步数(负=左,正=右)。 */
  moveCursor(steps: number): void
  selectCandidate(c: Candidate): void
  forgetCandidate(c: Candidate): void
  selectT9Pinyin(pinyin: string): void
  selectEmoji(emoji: string): void
  selectClip(text: string): void
  selectSymbol(symbol: string): void
  removeClipboardItem(item: string): void
  clearClipboard(): void
  /** 工具子页磁贴:'layout' | 'emoji' | 'clip' | 'lang_ru' | 'lang_ko'。 */
  runTool(tool: string): void
  openTools(): void
  returnToVoice(): void
  refreshCandidates(): void

  // ---- 麦克风(KeyboardMicCoordinator)----
  /** 录音中按任意键 → 结束实时识别(消费该键,不上屏,豆包式交互)。 */
  isMicActive(): boolean
  onMicRecordStart(): void
  onMicRecordEnd(): void

  // ---- 录音球(语音面板,LobsterIME 侧语义)----
  onOrbTap(): void
  onOrbTouchDown(): void
  onOrbTouchUp(): void

  // ---- 语音面板动作(方法名与 LobsterImeService「语音面板动作入口」段公开方法一一对应)----
  /** 切到打字键盘(语音面板左上「键盘」按钮)。 */
  enterKeyboardMode(): void
  /** 左/右手布局镜像切换。 */
  toggleHandLayout(): void
  /** 人设面板开关。 */
  togglePersonaPanel(): void
  /** 符号面板开关。 */
  toggleSymbolPanel(): void
  /** 直接提交文本并入撤回历史(header「@」键)。 */
  commitTextWithHistory(text: string): void
  /** 退格键按下/抬起/取消(长按连发在服务层计时)。 */
  onBackspacePressDown(): void
  onBackspacePressUp(): void
  onBackspacePressCancel(): void
  /** 换行。 */
  handleNewline(): void
  /** 撤回上一次上屏。 */
  handleUndo(): void
  /** 指令改写(录下一段语音作为改写指令)。 */
  handleRewrite(): void
  /** 快捷改写:格式化/润色/精简。 */
  handleQuickAction(action: AndroidQuickAction): void
  /** 清空输入框全文。 */
  handleClearInputText(): void
  /** 快速模式开关。 */
  toggleFastMode(): void
  /** 恢复原文(最近一次语音原文重新上屏)。 */
  handleRestoreVoiceText(): void
  /** 符号面板选分类。 */
  selectSymbolCategory(id: string): void
  /** 符号面板点符号(直接提交 + 记最近)。 */
  commitSymbol(value: string): void
  /** 不可用面板:唤起系统输入法切换。 */
  showInputMethodPicker(): void
  /** 不可用面板:打开主应用。 */
  openMainApp(): void
  /** 人设面板:刷新列表(personas 为空时带 loading 态)。 */
  refreshPersonas(): void
  /** 人设面板:打开自定义人设详情。 */
  openPersonaDetail(id: string): void
  /** 人设面板:返回(详情→列表,列表→关面板)。 */
  onPersonaBack(): void
  /** 人设面板:启用/停用(内部按当前激活态分流)。 */
  onPersonaActivate(id: string): void
  /** 人设详情:切换模块开关(module: 'transcribe' | 'rewrite')。 */
  onPersonaToggleModule(id: string, module: string): void

  // ---- 反馈 ----
  /** 触感反馈:HapticKind.TAP / HapticKind.LONG_PRESS(服务层走 vibrator)。 */
  performHaptic(kind: string): void
}

/**
 * 键盘面板响应式状态(@Observed):逻辑层通过 ImeBus 写入,UI 组件通过
 * @State / @ObjectLink 订阅。数组字段一律整体替换(不可原地 push)以触发刷新。
 */
@Observed
export class ImeBusState {
  /** 面板整体模式:ImePanelMode.TYPING / VOICE。 */
  panelMode: string = ImePanelMode.TYPING

  // ---- 键区 ----
  /** 键盘重建代号(rebuildKeyboard 自增,ForEach 以此为 key 强制重建键区)。 */
  keyboardEpoch: number = 0
  /** 仅重绘键帽(invalidateKeys,不重建结构)。 */
  keysRedrawEpoch: number = 0
  /** 当前键区行列(ENTER label 已代入)。 */
  rows: KeySpec[][] = []
  /** 当前子页:ImePageKind.*。 */
  pageKind: string = ImePageKind.KEYS
  shiftActive: boolean = false
  capsLock: boolean = false
  chineseMode: boolean = true
  nineGrid: boolean = false
  currentLangCode: string = 'zh'

  // ---- 候选 ----
  composingDisplay: string = ''
  candidates: Candidate[] = []
  candidatesEpoch: number = 0
  layoutLabel: string = ''
  /** 左侧竖排拼音选择器数据(九宫格输入态)。 */
  pinyinOptions: string[] = []
  pinyinActive: string = ''
  /** 展开多行候选面板。 */
  panelOpen: boolean = false

  // ---- 候选栏按钮态 ----
  micVisible: boolean = true
  micEnabled: boolean = true
  canUndo: boolean = false
  returnVoiceText: string = ''

  // ---- 键盘内录音(候选栏麦克风) ----
  recording: boolean = false

  // ---- 状态条 ----
  /** 临时提示(3s 自动消失)。 */
  statusMessage: string = ''
  /** 引擎装载状态(LOADING/FAILED 时常驻提示)。 */
  engineLoadState: PinyinLoadState = PinyinLoadState.IDLE
  engineDetail: string = ''

  // ---- 输入阻塞遮罩 ----
  inputBlocked: boolean = false

  // ---- 子页数据快照 ----
  /** 分类符号板当前分类(进入时重置为「最近」)。 */
  symBoardCategory: string = 'recent'
  recentEmojis: string[] = []
  recentSymbols: string[] = []
  clipboardHistory: string[] = []
  quickPhrases: string[] = []
  /** 子页数据刷新代号(删剪贴项/清空后自增)。 */
  subPageEpoch: number = 0

  // ---- 录音球(语音面板)----
  orbVisible: boolean = false
  orbRecording: boolean = false
  orbProcessing: boolean = false
  orbLoggedIn: boolean = true

  // ---- 语音面板完整快照(服务层 refreshKeyboardUi 整体替换写入)----
  voice: ImeVoicePanelUiState = new ImeVoicePanelUiState()
  /** 语音面板快照代号(每次替换自增,ForEach key 用)。 */
  voiceEpoch: number = 0
}

/** 全局单例状态桥。 */
export class ImeBus implements KeyboardRenderer {
  private static instance: ImeBus | null = null

  static getInstance(): ImeBus {
    if (ImeBus.instance === null) {
      ImeBus.instance = new ImeBus()
    }
    return ImeBus.instance
  }

  /** 响应式状态(UI 订阅)。 */
  readonly state: ImeBusState = new ImeBusState()

  /** 逻辑层对接(IME 服务启动时 bindDelegate)。 */
  delegate: ImeBusDelegate | null = null

  // ---- 高频原始值(非响应式,帧循环轮询;绝不放进 @Observed 防高频全量重渲染)----
  /** 键盘内录音实时音量 0-1(WaveformView 帧循环消费)。 */
  micLevelRaw: number = 0
  /** 录音剩余进度 0-1(MicButtonView 外环倒计时)。 */
  micProgressRaw: number = 1
  /** 临近录音上限警示(≤0.16 置位,波形/外环染 ERROR 色)。 */
  micWarningRaw: boolean = false
  /** 录音球声浪能量 0-1(RecordOrbView 帧循环消费)。 */
  orbLevelRaw: number = 0

  private statusTimer: number = -1

  bindDelegate(d: ImeBusDelegate): void {
    this.delegate = d
  }

  // ================= KeyboardRenderer(逻辑层 → UI)=================

  /** 重建键区:关闭展开面板 + 全量拉取逻辑层快照(对齐安卓 rebuildKeyboard)。 */
  rebuildKeyboard(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    const s = this.state
    if (s.panelOpen) {
      s.panelOpen = false
    }
    s.micVisible = !d.isPasswordField()
    s.micEnabled = d.isMicAvailable()
    s.shiftActive = d.isShiftActive()
    s.capsLock = d.isCapsLock()
    s.chineseMode = d.isChineseMode()
    s.nineGrid = d.isNineGrid()
    s.currentLangCode = d.currentLangCode()
    s.returnVoiceText = d.returnVoiceText()
    s.canUndo = d.canUndo()
    if (d.isToolsPage()) {
      s.pageKind = ImePageKind.TOOLS
    } else if (d.isEmojiPage()) {
      s.pageKind = ImePageKind.EMOJI
    } else if (d.isClipPage()) {
      s.pageKind = ImePageKind.CLIP
    } else if (d.isSymBoardPage()) {
      s.pageKind = ImePageKind.SYM_BOARD
    } else {
      s.pageKind = ImePageKind.KEYS
    }
    s.rows = d.buildKeyRows()
    s.recentEmojis = d.recentEmojis()
    s.recentSymbols = d.recentSymbols()
    s.clipboardHistory = d.clipboardHistory()
    s.quickPhrases = d.quickPhrases()
    s.keyboardEpoch++
  }

  renderCandidates(composingDisplay: string, candidates: Candidate[], layoutLabel: string): void {
    const s = this.state
    s.composingDisplay = composingDisplay
    s.candidates = candidates
    s.layoutLabel = layoutLabel
    const d = this.delegate
    if (d !== null) {
      // 对齐安卓 CandidateBarView.render():每次渲染刷新返回语音文案与撤销可用性
      s.returnVoiceText = d.returnVoiceText()
      s.canUndo = d.canUndo()
    }
    // 展开态下候选清空则收起(对齐安卓 renderCandidates)
    if (s.panelOpen && candidates.length === 0) {
      this.closeCandidatesPanel()
    }
    s.candidatesEpoch++
  }

  renderPinyinSelector(options: string[], active: string): void {
    this.state.pinyinOptions = options
    this.state.pinyinActive = active
  }

  /** 仅重绘键帽(shift 视觉态等),不重建结构。 */
  invalidateKeys(): void {
    const d = this.delegate
    if (d !== null) {
      this.state.shiftActive = d.isShiftActive()
      this.state.capsLock = d.isCapsLock()
    }
    this.state.keysRedrawEpoch++
  }

  /** 进入分类符号板:重置分类选中为「最近」(对齐安卓 onEnterSymBoard)。 */
  onEnterSymBoard(): void {
    this.state.symBoardCategory = 'recent'
  }

  setInputBlocked(blocked: boolean): void {
    this.state.inputBlocked = blocked
  }

  renderEngineState(state: PinyinLoadState, detail?: string): void {
    this.state.engineLoadState = state
    this.state.engineDetail = detail !== undefined ? detail : ''
  }

  // ================= 服务层附加 UI 通道(对应 TypingKeyboardView 公开方法)=================

  /** 录音实时音量(高频,非响应式;波形帧循环消费)。 */
  updateMicLevel(level: number): void {
    this.micLevelRaw = Math.max(0, Math.min(1, level))
  }

  /** 录音剩余进度 0-1;≤0.16 置警示色(对齐安卓 setRecordProgress)。 */
  setMicProgress(remaining: number): void {
    this.micProgressRaw = Math.max(0, Math.min(1, remaining))
    this.micWarningRaw = remaining <= 0.16
  }

  /** 服务层强制结束键盘内录音的 UI 态(对齐安卓 stopMicRecordingUI)。 */
  stopMicRecordingUI(): void {
    this.state.recording = false
    this.micLevelRaw = 0
  }

  /** 状态条临时提示,3s 自动消失(对齐安卓 showStatus)。 */
  showStatus(message: string | null): void {
    if (this.statusTimer !== -1) {
      clearTimeout(this.statusTimer)
      this.statusTimer = -1
    }
    if (message === null || message.length === 0) {
      this.state.statusMessage = ''
    } else {
      this.state.statusMessage = message
      this.statusTimer = setTimeout(() => {
        this.state.statusMessage = ''
        this.statusTimer = -1
      }, 3000)
    }
  }

  /** 切换面板整体模式(打字键盘 ↔ 语音面板)。 */
  setPanelMode(mode: string): void {
    this.state.panelMode = mode
  }

  setOrbVisible(visible: boolean): void {
    this.state.orbVisible = visible
  }

  /** 录音球状态(对齐安卓 RecordOrbView.setOrbState;level 走原始通道)。 */
  setOrbState(recording: boolean, processing: boolean, loggedIn: boolean, level: number): void {
    this.state.orbRecording = recording
    this.state.orbProcessing = processing
    this.state.orbLoggedIn = loggedIn
    this.orbLevelRaw = Math.max(0, Math.min(1, level))
  }

  /** 录音球高频声浪能量(非响应式,帧循环消费,对齐安卓 updateLevel)。 */
  updateOrbLevel(level: number): void {
    this.orbLevelRaw = Math.max(0, Math.min(1, level))
  }

  /** 语音面板完整快照整体替换(服务层 refreshKeyboardUi 语音分支调用)。 */
  setVoicePanelState(v: ImeVoicePanelUiState): void {
    this.state.voice = v
    this.state.voiceEpoch++
  }

  /** 重新拉取子页数据快照(删剪贴项/记最近符号后调用)。 */
  refreshSubpageData(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    this.state.recentEmojis = d.recentEmojis()
    this.state.recentSymbols = d.recentSymbols()
    this.state.clipboardHistory = d.clipboardHistory()
    this.state.quickPhrases = d.quickPhrases()
    this.state.subPageEpoch++
  }

  // ================= UI → 逻辑转发(视图事件)=================

  /** 键帽点按:录音中按任意键 → 结束实时识别(消费该键,对齐安卓 onKeyTap)。 */
  onKeyTap(spec: KeySpec): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    if (d.isMicActive()) {
      d.onMicRecordEnd()
      return
    }
    d.handleKey(spec)
  }

  onKeyLongPress(spec: KeySpec): void {
    this.delegate?.handleLongPress(spec)
  }

  onDeletePressDown(): void {
    this.delegate?.onDeletePressDown()
  }

  onDeletePressUp(): void {
    this.delegate?.onDeletePressUp()
  }

  onSpaceSlide(steps: number): void {
    this.delegate?.moveCursor(steps)
  }

  onCandidateSelected(c: Candidate): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.selectCandidate(c)
  }

  onCandidateLongPress(c: Candidate): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.LONG_PRESS)
    d.forgetCandidate(c)
  }

  onPinyinOptionSelected(pinyin: string): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.selectT9Pinyin(pinyin)
  }

  onReturnToVoice(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.returnToVoice()
  }

  onToolsTapped(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.openTools()
  }

  onUndo(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.handleSimpleKey(KeyType.UNDO)
  }

  /** 子页返回按钮(= handleKey(KeySpec(ALPHA)))。 */
  onBackToAlpha(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.handleSimpleKey(KeyType.ALPHA)
  }

  /** 子页 footer 删除键(单击一次,= handleKey(KeySpec(DELETE)))。 */
  onDeleteOnce(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.handleSimpleKey(KeyType.DELETE)
  }

  // ---- 麦克风(候选栏)----

  onMicRecordStart(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    this.state.recording = true
    this.micProgressRaw = 1
    this.micWarningRaw = false
    d.onMicRecordStart()
  }

  onMicRecordEnd(): void {
    this.state.recording = false
    this.micLevelRaw = 0
    this.delegate?.onMicRecordEnd()
  }

  onMicCancel(): void {
    this.onMicRecordEnd()
  }

  // ---- 展开候选面板 ----

  /** 展开/收起多行候选面板(对齐安卓 toggleCandidatesPanel)。 */
  onExpandCandidates(): void {
    const d = this.delegate
    if (d !== null) {
      d.performHaptic(HapticKind.TAP)
    }
    if (this.state.panelOpen) {
      this.closeCandidatesPanel()
      return
    }
    if (this.state.candidates.length <= 1) {
      return
    }
    this.state.panelOpen = true
  }

  closeCandidatesPanel(): void {
    this.state.panelOpen = false
    // 收起后恢复选择器(仍处输入态时,对齐安卓 closeCandidatesPanel)
    this.delegate?.refreshCandidates()
  }

  // ---- 子页动作 ----

  onToolSelected(tool: string): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.runTool(tool)
  }

  onEmojiSelected(emoji: string): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.selectEmoji(emoji)
    this.refreshSubpageData()
  }

  onSymbolSelected(symbol: string): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.selectSymbol(symbol)
    this.refreshSubpageData()
  }

  onSymBoardCategorySelected(id: string): void {
    const d = this.delegate
    if (d !== null) {
      d.performHaptic(HapticKind.TAP)
    }
    this.state.symBoardCategory = id
  }

  onClipSelected(text: string): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.selectClip(text)
  }

  onClipRemove(item: string): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.LONG_PRESS)
    d.removeClipboardItem(item)
    this.refreshSubpageData()
  }

  onClipClear(): void {
    const d = this.delegate
    if (d === null) {
      return
    }
    d.performHaptic(HapticKind.TAP)
    d.clearClipboard()
    this.refreshSubpageData()
  }

  // ---- 录音球事件 ----

  onOrbTap(): void {
    this.delegate?.onOrbTap()
  }

  onOrbTouchDown(): void {
    this.delegate?.onOrbTouchDown()
  }

  onOrbTouchUp(): void {
    this.delegate?.onOrbTouchUp()
  }

  // ---- 语音面板动作(VoicePanelView → 服务层,与安卓各按钮 OnClickListener 一一对应)----

  onVoiceEnterKeyboardMode(): void {
    this.delegate?.enterKeyboardMode()
  }

  onVoiceToggleHandLayout(): void {
    this.delegate?.toggleHandLayout()
  }

  onVoiceTogglePersonaPanel(): void {
    this.delegate?.togglePersonaPanel()
  }

  onVoiceToggleSymbolPanel(): void {
    this.delegate?.toggleSymbolPanel()
  }

  /** header「@」键:直接提交文本并入撤回历史。 */
  onVoiceCommitText(text: string): void {
    this.delegate?.commitTextWithHistory(text)
  }

  onVoiceBackspaceDown(): void {
    this.delegate?.onBackspacePressDown()
  }

  onVoiceBackspaceUp(): void {
    this.delegate?.onBackspacePressUp()
  }

  onVoiceBackspaceCancel(): void {
    this.delegate?.onBackspacePressCancel()
  }

  onVoiceNewline(): void {
    this.delegate?.handleNewline()
  }

  onVoiceUndo(): void {
    this.delegate?.handleUndo()
  }

  onVoiceRewrite(): void {
    this.delegate?.handleRewrite()
  }

  onVoiceQuickAction(action: AndroidQuickAction): void {
    this.delegate?.handleQuickAction(action)
  }

  onVoiceClearInput(): void {
    this.delegate?.handleClearInputText()
  }

  onVoiceToggleFastMode(): void {
    this.delegate?.toggleFastMode()
  }

  onVoiceRestore(): void {
    this.delegate?.handleRestoreVoiceText()
  }

  onVoiceSymbolCategory(id: string): void {
    this.delegate?.selectSymbolCategory(id)
  }

  onVoiceCommitSymbol(value: string): void {
    this.delegate?.commitSymbol(value)
  }

  onVoiceSwitchInputMethod(): void {
    this.delegate?.showInputMethodPicker()
  }

  onVoiceOpenMainApp(): void {
    this.delegate?.openMainApp()
  }

  onVoicePersonaRefresh(): void {
    this.delegate?.refreshPersonas()
  }

  onVoicePersonaOpenDetail(id: string): void {
    this.delegate?.openPersonaDetail(id)
  }

  onVoicePersonaBack(): void {
    this.delegate?.onPersonaBack()
  }

  onVoicePersonaActivate(id: string): void {
    this.delegate?.onPersonaActivate(id)
  }

  onVoicePersonaToggleModule(id: string, module: string): void {
    this.delegate?.onPersonaToggleModule(id, module)
  }

  // ---- 反馈 ----

  performHaptic(kind: string): void {
    this.delegate?.performHaptic(kind)
  }
}
