/**
 * 语音面板完整 UI(1:1 移植安卓 LobsterIME.onCreateInputView 的 voicePanel/symbolPanel/
 * personaPanel/unavailablePanel 视图树,含 rebuildShortcutRows/rebuildSymbolPanel/
 * rebuildPersonaPanel/buildUnavailablePanel 的全部控件与交互):
 *  - 顶部工具栏:键盘模式切换(Primary 键帽)/ 左右手 / 人设 / 符号 / @ / 退格(长按连发);
 *  - 主内容行:左右手镜像的快捷操作列(换行/撤回/指令改写 + 格式化/润色/精简/清空)
 *    与语音列(状态条 + 录音球 + 极速模式/恢复原文);
 *  - 指令提示条(commandHint);
 *  - 不可用面板(未登录/积分耗尽):标题 + 说明 + 切换输入法/打开 App;
 *  - 符号面板:返回 + 分类 tab(横向滚动)+ 符号网格(纵向滚动,含「最近」);
 *  - 人设面板:返回/标题/刷新 + 列表(启用/停用)+ 详情(模块开关 + 宽按钮)。
 * 状态来自 ImeBusState.voice(服务层 refreshKeyboardUi 全量快照),动作经 ImeBus 的
 * onVoice* 通道转发 LobsterImeService 的「语音面板动作入口」公开方法。
 * 视觉参数(色值/尺寸/圆角)与 LobsterIME.kt 数值逐项对齐,色板收敛引用 KeyboardTheme。
 */
import { MobileStrings } from '../../core/locale/MobileStrings'
import { SymbolData } from '../../keyboard/typing/SymbolData'
import {
  AndroidQuickAction,
  emptyPersonaPrompts,
  PersonaItem,
  PersonaPrompts
} from '../../data/model/ApiModels'
import { ImeBus, ImeBusState } from '../ImeBus'
import {
  KeycapStyle,
  LobsterKeyboardMetrics,
  LobsterKeycap,
  LobsterWaterColors
} from './KeyboardTheme'
import { RecordOrbView } from './RecordOrbView'

/** 符号网格每行列数(对齐安卓 items.chunked(8))。 */
const SYMBOL_GRID_COLS: number = 8

/** 字符串数组按列数切行(符号网格用)。 */
function chunkStrings(arr: string[], size: number): string[][] {
  const out: string[][] = []
  for (let i = 0; i < arr.length; i += size) {
    out.push(arr.slice(i, i + size))
  }
  return out
}

/**
 * 语音面板 3D 键帽按钮(安卓 keycap() 背景 Button 的声明式等价,渲染令牌与 KeycapButton 同源):
 * SECONDARY=玻璃渐变+1vp 描边;ACCENT=回车渐变(指令改写);PRIMARY=蓝宝石胶囊(键盘模式/切换输入法)。
 * enabled=false 时不响应点击;btnOpacity 对齐安卓按钮 alpha 语义(0.35 禁用 / 0.55 弱化)。
 * 文案自适应缩字(minFp..fontSizeFp)对齐安卓 fitPanelLabel。
 */
@Component
struct VoiceKeycap {
  @Prop label: string = ''
  @Prop btnEnabled: boolean = true
  @Prop btnOpacity: number = 1
  /** 键帽风格(构建后不变)。 */
  keycapStyle: KeycapStyle = KeycapStyle.SECONDARY
  fontSizeFp: number = 13
  /** 自适应缩字下限(对齐安卓 fitPanelLabel 的 minSp)。 */
  minFp: number = 8
  radiusVp: number = LobsterKeyboardMetrics.BUTTON_CORNER_DP
  heightVp: number = LobsterKeyboardMetrics.BUTTON_HEIGHT_DP
  /** true=包内容宽(配 paddingH,键盘模式按钮);false=撑满外部给定宽度。 */
  autoWidth: boolean = false
  paddingH: number = 0
  bold: boolean = true
  /** 文字颜色覆盖(0=按风格默认,「清空」用 ERROR)。 */
  textColorOverride: number = 0
  onTap: () => void = () => {
  }

  @Styles
  pressedStyle() {
    .opacity(0.78 * this.btnOpacity)
  }

  @Styles
  normalStyle() {
    .opacity(this.btnOpacity)
  }

  private gradColors(): [ResourceColor, number][] {
    const t = LobsterKeycap.tokens(this.keycapStyle)
    return [[t.gradientTop, 0], [t.gradientBottom, 1]]
  }

  private textColor(): number {
    if (this.textColorOverride !== 0) {
      return this.textColorOverride
    }
    return this.keycapStyle === KeycapStyle.SECONDARY ?
      LobsterWaterColors.ACCENT_DEEP : LobsterWaterColors.TEXT_ON_ACCENT
  }

  build() {
    Text(this.label)
      .fontSize(this.fontSizeFp)
      .minFontSize(this.minFp)
      .maxFontSize(this.fontSizeFp)
      .fontWeight(this.bold ? FontWeight.Bold : FontWeight.Normal)
      .fontColor(this.textColor())
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .height(this.heightVp)
      .width(this.autoWidth ? 'auto' : '100%')
      .padding({ left: this.paddingH, right: this.paddingH })
      .linearGradient({ angle: 180, colors: this.gradColors() })
      .borderRadius(this.radiusVp)
      .border({
        width: LobsterKeycap.tokens(this.keycapStyle).hasStroke ? 1 : 0,
        color: LobsterKeycap.tokens(this.keycapStyle).strokeColor
      })
      .shadow({
        radius: 1,
        color: LobsterKeycap.tokens(this.keycapStyle).shadowColor,
        offsetX: 0,
        offsetY: LobsterKeyboardMetrics.KEYCAP_SHADOW_DP
      })
      .stateStyles({
        pressed: this.pressedStyle,
        normal: this.normalStyle
      })
      .onClick(() => {
        if (this.btnEnabled) {
          this.onTap()
        }
      })
  }
}

/**
 * 语音面板退格键(对应安卓「⌫」Button + installBackspaceRepeatTouch):
 * 按下/抬起/取消经 ImeBus 走服务层的长按连发计时(onBackspacePress*),
 * 短按语义(抬起未触发长按 → 单次退格)由服务层收口。
 */
@Component
struct VoiceBackspaceKey {
  private bus: ImeBus = ImeBus.getInstance()

  @Styles
  pressedStyle() {
    .opacity(0.78)
  }

  @Styles
  normalStyle() {
    .opacity(1)
  }

  build() {
    Text('⌫')
      .fontSize(16)
      .fontColor(LobsterWaterColors.ACCENT_DEEP)
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .height(LobsterKeyboardMetrics.BUTTON_HEIGHT_DP)
      .width('100%')
      .linearGradient({
        angle: 180,
        colors: [[LobsterWaterColors.FUNC_TOP, 0], [LobsterWaterColors.FUNC_BOTTOM, 1]]
      })
      .borderRadius(LobsterKeyboardMetrics.BUTTON_CORNER_DP)
      .border({ width: 1, color: LobsterWaterColors.BORDER })
      .shadow({
        radius: 1,
        color: LobsterWaterColors.KEY_SHADOW,
        offsetX: 0,
        offsetY: LobsterKeyboardMetrics.KEYCAP_SHADOW_DP
      })
      .stateStyles({
        pressed: this.pressedStyle,
        normal: this.normalStyle
      })
      .onTouch((event: TouchEvent) => {
        if (event.type === TouchType.Down) {
          this.bus.onVoiceBackspaceDown()
        } else if (event.type === TouchType.Up) {
          this.bus.onVoiceBackspaceUp()
        } else if (event.type === TouchType.Cancel) {
          this.bus.onVoiceBackspaceCancel()
        }
      })
  }
}

/**
 * 符号/人设面板圆形返回钮(1:1 移植安卓 SymbolBackButton 自绘 View):
 * SYMBOL_BACK_FILL 圆底 + SYMBOL_BACK_STROKE 左向 chevron(圆头圆角折线)。
 */
@Component
struct SymbolBackButton {
  onTap: () => void = () => {
  }

  @Styles
  pressedStyle() {
    .opacity(0.7)
  }

  @Styles
  normalStyle() {
    .opacity(1)
  }

  build() {
    Stack() {
      Circle({ width: 34, height: 34 })
        .fill(LobsterWaterColors.SYMBOL_BACK_FILL)
      // chevron:(cx+7,cy-8)→(cx-5,cy)→(cx+7,cy+8),cx=18/cy=17(vp 语义落地安卓 px 参数)
      Polyline({ width: 36, height: 34 })
        .points([[25, 9], [13, 17], [25, 25]])
        .fillOpacity(0)
        .stroke(LobsterWaterColors.SYMBOL_BACK_STROKE)
        .strokeWidth(2)
        .strokeLineJoin(LineJoinStyle.Round)
        .strokeLineCap(LineCapStyle.Round)
    }
    .width(36)
    .height(34)
    .stateStyles({
      pressed: this.pressedStyle,
      normal: this.normalStyle
    })
    .onClick(() => {
      this.onTap()
    })
  }
}

@Component
export struct VoicePanelView {
  @ObjectLink state: ImeBusState

  private bus: ImeBus = ImeBus.getInstance()

  // ================= 快捷行数据(rebuildShortcutRows / mirroredForCurrentHand)=================

  /** 右手为基准序,左手取镜像(对齐安卓 mirroredForCurrentHand)。 */
  private mirrored(defaultOrder: string[]): string[] {
    if (this.state.voice.rightHandLayout) {
      return defaultOrder
    }
    const reversed: string[] = []
    for (let i = defaultOrder.length - 1; i >= 0; i--) {
      reversed.push(defaultOrder[i])
    }
    return reversed
  }

  private primaryShortcuts(): string[] {
    return this.mirrored(['newline', 'undo', 'rewrite'])
  }

  private quickTopShortcuts(): string[] {
    return this.mirrored(['format', 'polish'])
  }

  private quickBottomShortcuts(): string[] {
    return this.mirrored(['concise', 'clear'])
  }

  private quickLabel(s: string): string {
    if (s === 'format') {
      return MobileStrings.quickFormat()
    }
    if (s === 'polish') {
      return MobileStrings.quickPolish()
    }
    if (s === 'concise') {
      return MobileStrings.quickConcise()
    }
    return MobileStrings.clearInput()
  }

  private onQuickTap(s: string): void {
    if (s === 'format') {
      this.bus.onVoiceQuickAction(AndroidQuickAction.FORMAT)
      return
    }
    if (s === 'polish') {
      this.bus.onVoiceQuickAction(AndroidQuickAction.POLISH)
      return
    }
    if (s === 'concise') {
      this.bus.onVoiceQuickAction(AndroidQuickAction.CONCISE)
      return
    }
    this.bus.onVoiceClearInput()
  }

  // ================= 符号面板数据(rebuildSymbolPanel)=================

  private symCatIds(): string[] {
    const ids: string[] = [SymbolData.RECENT_ID]
    for (let i = 0; i < SymbolData.categories.length; i++) {
      ids.push(SymbolData.categories[i].id)
    }
    return ids
  }

  /** 「最近」为空时落到中文分类(对齐安卓 rebuildSymbolPanel 的兜底)。 */
  private symEffectiveCategory(): string {
    if (this.state.voice.voiceSymbolCategory === SymbolData.RECENT_ID &&
      this.state.voice.recentSymbols.length === 0) {
      return 'zh'
    }
    return this.state.voice.voiceSymbolCategory
  }

  private symItems(): string[] {
    const cat = this.symEffectiveCategory()
    if (cat === SymbolData.RECENT_ID) {
      return this.state.voice.recentSymbols
    }
    for (let i = 0; i < SymbolData.categories.length; i++) {
      if (SymbolData.categories[i].id === cat) {
        return SymbolData.categories[i].items
      }
    }
    return []
  }

  /** 生成 n 个占位索引(符号网格尾行补齐)。 */
  private padIndices(n: number): number[] {
    const a: number[] = []
    for (let i = 0; i < n; i++) {
      a.push(i)
    }
    return a
  }

  // ================= 人设面板数据(rebuildPersonaPanel)=================

  private personaTitle(): string {
    const d = this.state.voice.personaDetail
    return d !== null ? d.name : MobileStrings.persona()
  }

  /** 详情兜底(builder 参数不做 null 收窄,与 personaDetail !== null 分支配套)。 */
  private requireDetail(): PersonaItem {
    const d = this.state.voice.personaDetail
    if (d !== null) {
      return d
    }
    const empty: PersonaItem = {
      id: '',
      name: '',
      description: null,
      is_active: false,
      is_builtin: false,
      prompts: emptyPersonaPrompts()
    }
    return empty
  }

  /** 启用/停用按钮文案(pending 时显示「处理中」,对齐安卓 personaListRow)。 */
  private personaActionLabel(p: PersonaItem): string {
    if (this.state.voice.pendingPersonaActionId === p.id) {
      return MobileStrings.processingShort()
    }
    return p.is_active ? MobileStrings.disable() : MobileStrings.enable()
  }

  private personaActionOpacity(p: PersonaItem): number {
    const pending = this.state.voice.pendingPersonaActionId
    return (pending === null || pending === p.id) ? 1 : 0.55
  }

  private hasDescription(p: PersonaItem): boolean {
    const d = p.description
    return d !== null && d.trim().length > 0
  }

  /** 列表行副标题:描述,内置人设留空,自定义人设显示模块摘要(对齐安卓)。 */
  private personaSubtitle(p: PersonaItem): string {
    if (this.hasDescription(p)) {
      return p.description ?? ''
    }
    return p.is_builtin ? '' : this.moduleSummary(p.prompts)
  }

  private moduleSummary(prompts: PersonaPrompts): string {
    const enabled: string[] = []
    if (prompts.transcribe_enabled) {
      enabled.push(MobileStrings.personaTranscribe())
    }
    if (prompts.rewrite_enabled) {
      enabled.push(MobileStrings.personaRewrite())
    }
    return enabled.length === 0 ? MobileStrings.builtin() : enabled.join(' / ')
  }

  private moduleEnabled(p: PersonaItem, module: string): boolean {
    return module === 'transcribe' ? p.prompts.transcribe_enabled : p.prompts.rewrite_enabled
  }

  private moduleHasPrompt(p: PersonaItem, module: string): boolean {
    const prompt = module === 'transcribe' ? p.prompts.transcribe_prompt : p.prompts.rewrite_prompt
    return prompt !== null && prompt.trim().length > 0
  }

  private moduleTitle(module: string): string {
    return module === 'transcribe' ? MobileStrings.personaTranscribe() : MobileStrings.personaRewrite()
  }

  private moduleBadgeLabel(p: PersonaItem, module: string): string {
    if (this.moduleEnabled(p, module)) {
      return MobileStrings.active()
    }
    return this.moduleHasPrompt(p, module) ? MobileStrings.inactive() : MobileStrings.builtin()
  }

  // ================= 构建 =================

  build() {
    Column() {
      // 面板互斥:符号板 / 人设板整体替换语音主面板(对齐安卓 setPanelVisibility 终态)
      if (this.state.voice.symbolPanelVisible) {
        this.SymbolPanel()
      } else if (this.state.voice.personaPanelVisible) {
        this.PersonaPanel()
      } else {
        this.VoiceMain()
      }
    }
    .width('100%')
    .height(LobsterKeyboardMetrics.PANEL_HEIGHT_DP)
    .linearGradient({
      angle: 180,
      colors: [[LobsterWaterColors.PANEL_BG_TOP, 0], [LobsterWaterColors.PANEL_BG_BOTTOM, 1]]
    })
    .padding({
      left: LobsterKeyboardMetrics.VOICE_ROOT_PADDING_H_DP,
      top: LobsterKeyboardMetrics.VOICE_ROOT_PADDING_V_DP,
      right: LobsterKeyboardMetrics.VOICE_ROOT_PADDING_H_DP,
      bottom: LobsterKeyboardMetrics.VOICE_ROOT_PADDING_V_DP
    })
  }

  // ---- 语音主面板(header + 不可用面板/内容行 + 指令提示条)----
  @Builder
  VoiceMain() {
    Column() {
      this.Header()
      if (this.state.voice.unavailable) {
        this.UnavailablePanel()
      } else {
        // content 行 weight=1 吃满剩余高,内部垂直居中(对齐安卓 content)
        Row() {
          if (this.state.voice.rightHandLayout) {
            this.ActionColumn(12)
            this.VoiceColumn(0)
          } else {
            this.VoiceColumn(12)
            this.ActionColumn(0)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .margin({ top: 12 })
        .alignItems(VerticalAlign.Center)

        // 底部行:左侧「单手(左右手镜像)」低频开关 + 右侧命令提示文案。
        // 单手从麦克风语音列迁到这里,给它一个够宽、不挤压任何区域的低显著度位置。
        Row() {
          VoiceKeycap({
            label: this.state.voice.rightHandLayout ? MobileStrings.rightHand() : MobileStrings.leftHand(),
            fontSizeFp: 11,
            minFp: 8,
            radiusVp: 15,
            heightVp: 28,
            bold: false,
            onTap: () => {
              this.bus.onVoiceToggleHandLayout()
            }
          })
            .width(56)
            .margin({ right: 10 })
          Text(MobileStrings.commandHint())
            .fontSize(11)
            .fontColor(LobsterWaterColors.TEXT_MUTED)
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .opacity(0.72)
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }

  // ---- 顶部工具栏(44vp,与打字键盘候选栏同规格,两模式左上按钮 Y 对齐)----
  // 2026-07 去滑动重设计(镜像安卓,预算模型 test_voice_toolbar_layout.py):
  // - 移除 @ 键(与符号面板内 @ 重复,面板"最近使用"一次可达)
  // - "单手"迁入语音列工具行(设置类低频开关就近其作用区域)
  // - 人设/符号图标化(🎭/🔣),多语言文案只进无障碍描述
  // 内容宽 ≤268vp,320vp 最小屏定宽装下 → 不再用横向 Scroll 兜底
  @Builder
  Header() {
    Row() {
      // 模式切换按钮(Primary 3D 键帽),点击切到打字键盘;长 locale 封顶宽 88 缩排
      VoiceKeycap({
        label: MobileStrings.keyboardModeLabel(),
        keycapStyle: KeycapStyle.PRIMARY,
        fontSizeFp: 13,
        autoWidth: true,
        paddingH: 14,
        onTap: () => {
          this.bus.onVoiceEnterKeyboardMode()
        }
      })
        .constraintSize({ maxWidth: 88 })
        .margin({ right: 8 })
      // 弹性空白:把右侧功能键推到右边
      Blank()
      // @ 键:微信聊天高频符号,回归工具栏右侧显眼位置,一键可达(不必进符号面板)
      VoiceKeycap({
        label: '@',
        fontSizeFp: 17,
        bold: false,
        onTap: () => {
          this.bus.onVoiceCommitText('@')
        }
      })
        .width(40)
        .margin({ right: 8 })
      VoiceKeycap({
        label: '🎭',
        fontSizeFp: 16,
        bold: false,
        onTap: () => {
          this.bus.onVoiceTogglePersonaPanel()
        }
      })
        .accessibilityText(MobileStrings.persona())
        .width(40)
        .margin({ right: 8 })
      VoiceKeycap({
        label: '🔣',
        fontSizeFp: 16,
        bold: false,
        onTap: () => {
          this.bus.onVoiceToggleSymbolPanel()
        }
      })
        .accessibilityText(MobileStrings.symbols())
        .width(40)
        .margin({ right: 8 })
      VoiceBackspaceKey()
        .width(44)
    }
    .width('100%')
    .height(LobsterKeyboardMetrics.TOOLBAR_HEIGHT_DP)
    .alignItems(VerticalAlign.Center)
  }

  // ---- 不可用面板(未登录/积分耗尽,对齐安卓 buildUnavailablePanel)----
  @Builder
  UnavailablePanel() {
    Column() {
      Text(MobileStrings.inputUnavailableTitle(this.state.voice.blockedReasonCredits))
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(LobsterWaterColors.TEXT_MAIN)
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .width('100%')
      Text(MobileStrings.inputUnavailableBody(this.state.voice.blockedReasonCredits))
        .fontSize(12)
        .fontColor(LobsterWaterColors.TEXT_MUTED)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .width('100%')
        .margin({ top: 8 })
      Row() {
        VoiceKeycap({
          label: MobileStrings.switchKeyboard(),
          keycapStyle: KeycapStyle.PRIMARY,
          fontSizeFp: 13,
          radiusVp: 12,
          heightVp: 42,
          onTap: () => {
            this.bus.onVoiceSwitchInputMethod()
          }
        })
          .layoutWeight(1)
          .margin({ right: 8 })
        VoiceKeycap({
          label: MobileStrings.openApp(),
          fontSizeFp: 13,
          radiusVp: 12,
          heightVp: 42,
          onTap: () => {
            this.bus.onVoiceOpenMainApp()
          }
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height(42)
      .margin({ top: 16 })
    }
    .width('100%')
    .height(178)
    .margin({ top: 12 })
    .borderRadius(16)
    .border({ width: 1, color: LobsterWaterColors.BORDER })
    .linearGradient({
      angle: 180,
      colors: [[LobsterWaterColors.SURFACE_GRADIENT_TOP, 0], [LobsterWaterColors.SURFACE_GRADIENT_BOTTOM, 1]]
    })
    .padding({ left: 14, top: 12, right: 14, bottom: 12 })
    .justifyContent(FlexAlign.Center)
  }

  // ---- 语音列(玻璃卡片:状态条 + 录音球 + 极速/恢复原文)----
  @Builder
  VoiceColumn(marginRight: number) {
    Column() {
      // 状态条/错误红字(对齐安卓 statusTextView)
      Text(this.state.voice.statusText)
        .fontSize(13)
        .fontColor(this.state.voice.isError ? LobsterWaterColors.ERROR : LobsterWaterColors.TEXT_MAIN)
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .width('100%')
        .height(34)
      // 录音球(72vp;未登录/处理中禁点由 RecordOrbView 内部裁决,B-5)
      RecordOrbView({
        orbRecording: this.state.orbRecording,
        orbProcessing: this.state.orbProcessing,
        orbLoggedIn: this.state.orbLoggedIn
      })
        .width(72)
        .height(72)
        .margin({ top: 8 })
      // 麦克风语音列工具行:只保留「极速 / 还原」两钮(单手已迁至底部提示行),
      // 两钮等分 106vp,俄语文案不再被三等分挤压
      Row() {
        // 极速:只显示「极速」,开关状态用高亮键帽表示(开=蓝宝石强调,关=常态玻璃),
        // 避免"极速 开/关"两段文案在窄列缩字不可读(俄语 Быстро ВКЛ 最长)
        VoiceKeycap({
          label: MobileStrings.fastMode(),
          keycapStyle: this.state.voice.fastModeEnabled ? KeycapStyle.PRIMARY : KeycapStyle.SECONDARY,
          fontSizeFp: 11,
          minFp: 8,
          radiusVp: 15,
          heightVp: 32,
          bold: false,
          onTap: () => {
            this.bus.onVoiceToggleFastMode()
          }
        })
          .layoutWeight(1)
          .margin({ right: 8 })
        VoiceKeycap({
          label: MobileStrings.restoreVoice(),
          fontSizeFp: 11,
          minFp: 8,
          radiusVp: 15,
          heightVp: 32,
          bold: false,
          btnEnabled: this.state.voice.restoreEnabled,
          btnOpacity: this.state.voice.restoreEnabled ? 1 : 0.35,
          onTap: () => {
            this.bus.onVoiceRestore()
          }
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height(32)
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width(126)
    .height('100%')
    .margin({ right: marginRight })
    .borderRadius(16)
    .border({ width: 1, color: LobsterWaterColors.BORDER })
    .linearGradient({
      angle: 180,
      colors: [[LobsterWaterColors.SURFACE_GRADIENT_TOP, 0], [LobsterWaterColors.SURFACE_GRADIENT_BOTTOM, 1]]
    })
    .padding(10)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ---- 快捷操作列(主行:换行/撤回/指令改写;快捷网格:格式化/润色 + 精简/清空)----
  @Builder
  ActionColumn(marginRight: number) {
    Column() {
      Row() {
        ForEach(this.primaryShortcuts(), (s: string, i: number) => {
          this.PrimaryShortcutButton(s, i === 2)
        }, (s: string, i: number) => `pri_${this.state.voiceEpoch}_${i}_${s}`)
      }
      .width('100%')

      Column() {
        Row() {
          ForEach(this.quickTopShortcuts(), (s: string, i: number) => {
            this.QuickActionButton(s, i === 1)
          }, (s: string, i: number) => `qt_${this.state.voiceEpoch}_${i}_${s}`)
        }
        .width('100%')

        Row() {
          ForEach(this.quickBottomShortcuts(), (s: string, i: number) => {
            this.QuickActionButton(s, i === 1)
          }, (s: string, i: number) => `qb_${this.state.voiceEpoch}_${i}_${s}`)
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .layoutWeight(1)
    .height('100%')
    .margin({ right: marginRight })
    .justifyContent(FlexAlign.Center)
  }

  /** 主快捷行按钮(换行 14fp / 撤回 13fp / 指令改写 ACCENT 强调键帽,对齐 primaryShortcutButton)。 */
  @Builder
  PrimaryShortcutButton(s: string, isLast: boolean) {
    if (s === 'newline') {
      VoiceKeycap({
        label: MobileStrings.newline(),
        fontSizeFp: 14,
        minFp: 9,
        radiusVp: 12,
        heightVp: 42,
        onTap: () => {
          this.bus.onVoiceNewline()
        }
      })
        .layoutWeight(1)
        .margin({ right: isLast ? 0 : 8 })
    } else if (s === 'undo') {
      VoiceKeycap({
        label: MobileStrings.undo(),
        fontSizeFp: 13,
        minFp: 9,
        radiusVp: 12,
        heightVp: 42,
        btnEnabled: this.state.voice.undoEnabled,
        btnOpacity: this.state.voice.undoEnabled ? 1 : 0.35,
        onTap: () => {
          this.bus.onVoiceUndo()
        }
      })
        .layoutWeight(1)
        .margin({ right: isLast ? 0 : 8 })
    } else {
      VoiceKeycap({
        label: MobileStrings.rewrite(),
        keycapStyle: KeycapStyle.ACCENT,
        fontSizeFp: 13,
        minFp: 9,
        radiusVp: 12,
        heightVp: 42,
        btnEnabled: this.state.voice.rewriteEnabled,
        btnOpacity: this.state.voice.rewriteEnabled ? 1 : 0.35,
        onTap: () => {
          this.bus.onVoiceRewrite()
        }
      })
        .layoutWeight(1)
        .margin({ right: isLast ? 0 : 8 })
    }
  }

  /** 快捷改写按钮(格式化/润色/精简/清空,「清空」红字,对齐 quickActionButton)。 */
  @Builder
  QuickActionButton(s: string, isLast: boolean) {
    VoiceKeycap({
      label: this.quickLabel(s),
      fontSizeFp: 13,
      radiusVp: 12,
      heightVp: 40,
      textColorOverride: s === 'clear' ? LobsterWaterColors.ERROR : 0,
      onTap: () => {
        this.onQuickTap(s)
      }
    })
      .layoutWeight(1)
      .margin({ right: isLast ? 0 : 8 })
  }

  // ---- 符号面板(返回 + 标题 + 分类 tab + 符号网格,对齐 rebuildSymbolPanel)----
  @Builder
  SymbolPanel() {
    Column() {
      Row() {
        SymbolBackButton({
          onTap: () => {
            this.bus.onVoiceToggleSymbolPanel()
          }
        })
          .margin({ left: 2, right: 2 })
        Text(MobileStrings.symbols())
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(LobsterWaterColors.TEXT_MAIN)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 分类标签行(横向滚动):最近 + 全部分类
      Scroll() {
        Row() {
          ForEach(this.symCatIds(), (id: string) => {
            Text(SymbolData.label(id, MobileStrings.currentLanguage().code))
              .fontSize(12)
              .fontWeight(FontWeight.Bold)
              .fontColor(id === this.symEffectiveCategory() ?
                LobsterWaterColors.TEXT_ON_ACCENT : LobsterWaterColors.ACCENT_DEEP)
              .textAlign(TextAlign.Center)
              .padding({ left: 10, top: 6, right: 10, bottom: 6 })
              .backgroundColor(id === this.symEffectiveCategory() ?
                LobsterWaterColors.ACCENT : LobsterWaterColors.BADGE_INACTIVE_BG)
              .borderRadius(13)
              .border({
                width: id === this.symEffectiveCategory() ? 0 : 1,
                color: LobsterWaterColors.BORDER
              })
              .margin({ left: 2, right: 2 })
              .onClick(() => {
                this.bus.onVoiceSymbolCategory(id)
              })
          }, (id: string) => `vsymcat_${this.state.voiceEpoch}_${id}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: 4 })
      .align(Alignment.Start)

      // 符号网格(纵向滚动,尾行占位补齐,每行居中,对齐安卓 chunked(8))
      Scroll() {
        Column() {
          ForEach(chunkStrings(this.symItems(), SYMBOL_GRID_COLS), (symRow: string[], ri: number) => {
            Row() {
              ForEach(symRow, (s: string, ci: number) => {
                VoiceKeycap({
                  label: s,
                  fontSizeFp: 14,
                  radiusVp: 12,
                  heightVp: 34,
                  onTap: () => {
                    this.bus.onVoiceCommitSymbol(s)
                  }
                })
                  .width(36)
                  .margin({ left: 2, right: 2 })
              }, (s: string, ci: number) => `vsym_${ri}_${ci}_${s}`)
              if (symRow.length < SYMBOL_GRID_COLS) {
                ForEach(this.padIndices(SYMBOL_GRID_COLS - symRow.length), (pi: number) => {
                  Row()
                    .width(36)
                    .height(34)
                    .margin({ left: 2, right: 2 })
                }, (pi: number) => `vsympad_${ri}_${pi}`)
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 6 })
          }, (symRow: string[], ri: number) =>
            `vsymrow_${this.symEffectiveCategory()}_${this.state.voiceEpoch}_${ri}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
      .margin({ top: 4 })
      .align(Alignment.TopStart)
    }
    .width('100%')
    .height('100%')
  }

  // ---- 人设面板(返回/标题/刷新 + 提示 + 列表或详情,对齐 rebuildPersonaPanel)----
  @Builder
  PersonaPanel() {
    Column() {
      Row() {
        SymbolBackButton({
          onTap: () => {
            this.bus.onVoicePersonaBack()
          }
        })
          .margin({ left: 2, right: 6 })
        Text(this.personaTitle())
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(LobsterWaterColors.TEXT_MAIN)
          .maxLines(1)
          .layoutWeight(1)
        VoiceKeycap({
          label: MobileStrings.refresh(),
          fontSizeFp: 12,
          radiusVp: 16,
          heightVp: 32,
          btnEnabled: !this.state.voice.personasRefreshing,
          btnOpacity: this.state.voice.personasRefreshing ? 0.55 : 1,
          onTap: () => {
            this.bus.onVoicePersonaRefresh()
          }
        })
          .width(58)
      }
      .width('100%')
      .height(36)
      .alignItems(VerticalAlign.Center)

      Text(this.state.voice.personaDetail === null ?
        MobileStrings.personaHint() : MobileStrings.personaModuleHint())
        .fontSize(11)
        .fontColor(LobsterWaterColors.TEXT_MUTED)
        .maxLines(1)
        .width('100%')
        .height(22)

      if (this.state.voice.personasLoading) {
        Column() {
          Text(MobileStrings.processingShort())
            .fontSize(13)
            .fontColor(LobsterWaterColors.TEXT_MUTED)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.state.voice.personaDetail !== null) {
        this.PersonaDetailView(this.requireDetail())
      } else {
        this.PersonaListView()
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  PersonaListView() {
    if (this.state.voice.personas.length === 0) {
      Column() {
        Text(MobileStrings.personaEmpty())
          .fontSize(13)
          .fontColor(LobsterWaterColors.TEXT_MUTED)
          .textAlign(TextAlign.Center)
          .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column() {
          ForEach(this.state.voice.personas, (p: PersonaItem) => {
            this.PersonaListRow(p)
          }, (p: PersonaItem) => `vpersona_${this.state.voiceEpoch}_${p.id}`)
        }
        .width('100%')
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
    }
  }

  /** 人设列表行(名称/摘要 + 启用/停用按钮;非内置人设点击进详情)。 */
  @Builder
  PersonaListRow(p: PersonaItem) {
    Row() {
      Column() {
        Text(p.name)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(LobsterWaterColors.TEXT_MAIN)
          .maxLines(1)
        Text(this.personaSubtitle(p))
          .fontSize(10)
          .fontColor(LobsterWaterColors.TEXT_MUTED)
          .maxLines(1)
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Start)

      VoiceKeycap({
        label: this.personaActionLabel(p),
        fontSizeFp: 12,
        radiusVp: 16,
        heightVp: 32,
        btnEnabled: this.state.voice.pendingPersonaActionId === null,
        btnOpacity: this.personaActionOpacity(p),
        onTap: () => {
          this.bus.onVoicePersonaActivate(p.id)
        }
      })
        .width(58)
    }
    .width('100%')
    .height(48)
    .borderRadius(12)
    .backgroundColor(p.is_active ? LobsterWaterColors.BUTTON_BG_STRONG : LobsterWaterColors.BUTTON_BG)
    .padding({ left: 10, top: 6, right: 8, bottom: 6 })
    .margin({ bottom: 7 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (!p.is_builtin) {
        this.bus.onVoicePersonaOpenDetail(p.id)
      }
    })
  }

  /** 人设详情(描述 + 语音输入/指令改写模块开关 + 启用/停用宽按钮)。 */
  @Builder
  PersonaDetailView(p: PersonaItem) {
    Column() {
      if (this.hasDescription(p)) {
        Text(p.description ?? '')
          .fontSize(11)
          .fontColor(LobsterWaterColors.TEXT_MUTED)
          .maxLines(2)
          .width('100%')
          .height(32)
          .margin({ bottom: 4 })
      }
      this.PersonaModuleRow(p, 'transcribe')
      this.PersonaModuleRow(p, 'rewrite')
      Row() {
        VoiceKeycap({
          label: this.personaActionLabel(p),
          fontSizeFp: 13,
          minFp: 9,
          radiusVp: 12,
          heightVp: 38,
          btnEnabled: this.state.voice.pendingPersonaActionId === null,
          btnOpacity: this.personaActionOpacity(p),
          onTap: () => {
            this.bus.onVoicePersonaActivate(p.id)
          }
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height(38)
      .margin({ top: 6 })
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 人设模块行(标题 + 启用/停用/内置徽标;有提示词且无 pending 时可点切换)。 */
  @Builder
  PersonaModuleRow(p: PersonaItem, module: string) {
    Row() {
      Text(this.moduleTitle(module))
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(LobsterWaterColors.TEXT_MAIN)
        .layoutWeight(1)
      Text(this.moduleBadgeLabel(p, module))
        .fontSize(11)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.moduleEnabled(p, module) ?
          LobsterWaterColors.ACCENT : LobsterWaterColors.TEXT_MUTED)
        .textAlign(TextAlign.Center)
        .width(66)
        .height(28)
        .borderRadius(18)
        .backgroundColor(this.moduleEnabled(p, module) ?
          LobsterWaterColors.BADGE_ACTIVE_BG : LobsterWaterColors.BADGE_INACTIVE_BG)
    }
    .width('100%')
    .height(42)
    .margin({ bottom: 7 })
    .borderRadius(12)
    .backgroundColor(this.moduleEnabled(p, module) ?
      LobsterWaterColors.BUTTON_BG_STRONG : LobsterWaterColors.BUTTON_BG)
    .opacity(this.moduleHasPrompt(p, module) ? 1 : 0.48)
    .padding({ left: 12, right: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.moduleHasPrompt(p, module) && this.state.voice.pendingPersonaActionId === null) {
        this.bus.onVoicePersonaToggleModule(p.id, module)
      }
    })
  }
}
