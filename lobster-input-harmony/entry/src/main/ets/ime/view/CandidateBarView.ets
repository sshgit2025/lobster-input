/**
 * 候选栏(1:1 移植安卓 keyboard/typing/CandidateBarView.kt):
 * 状态条 + [返回语音][麦克风][组合/候选/波形][展开][撤销][齿轮]。
 * 打字中(composing 非空)收起两边按钮,候选占满整行;composing 一空立即恢复。
 * 候选首屏同步渲染前 80 个,其余下一拍补齐(对齐安卓 syncRenderCount 防按键回显卡顿)。
 */
import { accessibility } from '@kit.AccessibilityKit'
import { Candidate } from '../../keyboard/pinyin/PinyinEngine'
import { PinyinLoadState } from '../../keyboard/pinyin/PinyinLoadState'
import { TypingAccessibilityLabels } from '../../keyboard/typing/accessibility/TypingAccessibilityLabels'
import { MobileStrings } from '../../core/locale/MobileStrings'
import { ImeBus, ImeBusState } from '../ImeBus'
import {
  KeycapButton,
  LobsterKeyboardMetrics,
  LobsterWaterColors
} from './KeyboardTheme'
import { MicButtonView } from './MicButtonView'
import { WaveformView } from './WaveformView'

@Component
export struct CandidateBarView {
  @ObjectLink @Watch('onStateChanged') state: ImeBusState

  private bus: ImeBus = ImeBus.getInstance()
  private scroller: Scroller = new Scroller()
  /** 首屏同步渲染的候选数(对齐安卓 syncRenderCount)。 */
  private readonly syncRenderCount: number = 80
  @State visibleCount: number = 0
  private lastCandidatesEpoch: number = -1
  /** 上次已播报的引擎状态文案(变化时才播报,防止 state 高频更新重复朗读)。 */
  private lastAnnouncedEngineMsg: string = ''

  aboutToAppear(): void {
    this.applyCandidatesEpoch()
    this.announceEngineState()
  }

  onStateChanged(propName: string): void {
    if (this.state.candidatesEpoch !== this.lastCandidatesEpoch) {
      this.applyCandidatesEpoch()
    }
    this.announceEngineState()
  }

  /** 引擎装载中/失败常驻文案(安卓侧仅这类消息走 announceStatus 播报,临时 showStatus 不播报)。 */
  private engineStateText(): string {
    if (this.state.engineLoadState === PinyinLoadState.LOADING) {
      return MobileStrings.pinyinDictLoading()
    }
    if (this.state.engineLoadState === PinyinLoadState.FAILED) {
      return this.state.engineDetail.length > 0 ? this.state.engineDetail : MobileStrings.pinyinDictFailed()
    }
    return ''
  }

  /**
   * 等价安卓 TypingAccessibilityLabels.announceStatus(view.announceForAccessibility,
   * 见 CandidateBarView.kt renderEngineState):引擎状态文案变化时发送系统
   * announceForAccessibility 无障碍事件,屏幕朗读开启时主动读出;
   * 朗读未开启或发送失败静默忽略,不影响正常功能。
   */
  private announceEngineState(): void {
    const msg = this.engineStateText()
    if (msg === this.lastAnnouncedEngineMsg) {
      return
    }
    this.lastAnnouncedEngineMsg = msg
    if (msg.length === 0) {
      return
    }
    const event = new accessibility.EventInfo('announceForAccessibility', 'com.lobster.input', 'common')
    event.textAnnouncedForAccessibility = msg
    accessibility.sendAccessibilityEvent(event).catch(() => {
      // 无障碍服务未开启等场景:静默忽略(对齐安卓 announceForAccessibility 的无副作用语义)
    })
  }

  /** 新一轮候选:同步渲染首屏,剩余下一拍补齐(epoch 防旧任务追加到新列表),并回滚到起点。 */
  private applyCandidatesEpoch(): void {
    this.lastCandidatesEpoch = this.state.candidatesEpoch
    const total = this.state.candidates.length
    const sync = Math.min(this.syncRenderCount, total)
    this.visibleCount = sync
    if (total > sync) {
      const epoch = this.state.candidatesEpoch
      setTimeout(() => {
        if (epoch === this.state.candidatesEpoch) {
          this.visibleCount = this.state.candidates.length
        }
      }, 0)
    }
    try {
      this.scroller.scrollTo({ xOffset: 0, yOffset: 0 })
    } catch (e) {
      // 滚动器未挂载时忽略
    }
  }

  private isTyping(): boolean {
    // 打字中收起两侧;1 键符号候选态(isSymbol)同样收起:13 个符号需要整行空间,
    // 与候选词展开效果对齐(emoji 联想态不收起,保持原状)。
    return this.state.composingDisplay.length > 0 ||
      (this.state.candidates.length > 0 && this.state.candidates[0].isSymbol)
  }

  /** 状态条文案:临时提示优先;否则引擎装载中/失败常驻提示(对齐安卓 renderEngineState + showStatus)。 */
  private statusText(): string {
    if (this.state.statusMessage.length > 0) {
      return this.state.statusMessage
    }
    if (this.state.engineLoadState === PinyinLoadState.LOADING) {
      return MobileStrings.pinyinDictLoading()
    }
    if (this.state.engineLoadState === PinyinLoadState.FAILED) {
      return this.state.engineDetail.length > 0 ? this.state.engineDetail : MobileStrings.pinyinDictFailed()
    }
    return ''
  }

  build() {
    Column() {
      // ---- 状态条(错误红,11fp)----
      if (this.statusText().length > 0) {
        Text(this.statusText())
          .fontSize(11)
          .fontColor(LobsterWaterColors.ERROR)
          .width('100%')
          .padding({ left: 6, top: 2, right: 6, bottom: 2 })
      }

      // ---- 工具栏行(44vp)----
      Row() {
        // 返回语音(Primary 胶囊,打字中隐藏)
        if (!this.isTyping()) {
          KeycapButton({
            label: this.state.returnVoiceText,
            primary: true,
            fontSizeFp: 13,
            onTap: () => {
              this.bus.onReturnToVoice()
            }
          })
            .margin({ left: 2, right: 4 })
        }

        // 麦克风(密码框隐藏;未登录置灰;打字中隐藏)
        if (!this.isTyping() && this.state.micVisible) {
          MicButtonView({
            recording: this.state.recording,
            micEnabled: this.state.micEnabled
          })
            .width(38)
            .height(38)
            .margin({ right: 4 })
        }

        // 中部:组合串 + 候选横滑 / 录音波形
        Stack() {
          if (this.state.recording) {
            WaveformView()
              .width('100%')
              .height('100%')
          } else {
            Scroll(this.scroller) {
              Row() {
                if (this.isTyping()) {
                  Text(this.state.composingDisplay)
                    .fontSize(14)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(LobsterWaterColors.ACCENT)
                    .margin({ right: 8 })
                }
                ForEach(this.state.candidates.slice(0, this.visibleCount), (c: Candidate, i: number) => {
                  Text(c.word)
                    .fontSize(18)
                    .fontColor(i === 0 ? LobsterWaterColors.ACCENT_DEEP : LobsterWaterColors.TEXT_MAIN)
                    .textAlign(TextAlign.Center)
                    .constraintSize({ minWidth: 40 })
                    .padding({ left: 10, top: 4, right: 10, bottom: 4 })
                    .backgroundColor(i === 0 ? LobsterWaterColors.BADGE_ACTIVE_BG : Color.Transparent)
                    .borderRadius(8)
                    // 无障碍:读"序号. 词"(等价安卓 announceCandidate 的 contentDescription,
                    // 见 CandidateBarView.kt:259)
                    .accessibilityGroup(true)
                    .accessibilityText(TypingAccessibilityLabels.candidateLabel(c, i))
                    .accessibilityLevel('yes')
                    .onClick(() => {
                      this.bus.onCandidateSelected(c)
                    })
                    .gesture(
                      LongPressGesture({ duration: 500 })
                        .onAction(() => {
                          this.bus.onCandidateLongPress(c)
                        })
                    )
                }, (c: Candidate, i: number) => `${this.state.candidatesEpoch}_${i}_${c.word}`)
              }
              .alignItems(VerticalAlign.Center)
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.None)
            .align(Alignment.Start)
            .width('100%')
            .height('100%')
          }
        }
        .layoutWeight(1)
        .height('100%')

        // 展开箭头(候选超一屏时;打字与否都显示,对齐安卓)
        if (this.state.candidates.length > 8) {
          KeycapButton({
            label: this.state.panelOpen ? '▴' : '▾',
            fontSizeFp: 12.5,
            onTap: () => {
              this.bus.onExpandCandidates()
            }
          })
            .margin({ left: 2, right: 2 })
        }

        // 撤销(有可撤销提交且非打字中)
        if (!this.isTyping() && this.state.canUndo) {
          KeycapButton({
            label: MobileStrings.undo(),
            fontSizeFp: 12.5,
            onTap: () => {
              this.bus.onUndo()
            }
          })
            .margin({ left: 2, right: 2 })
        }

        // 齿轮工具入口(最右,打字中隐藏)
        if (!this.isTyping()) {
          KeycapButton({
            label: '⚙',
            fontSizeFp: 12.5,
            onTap: () => {
              this.bus.onToolsTapped()
            }
          })
            .margin({ left: 4, right: 2 })
        }
      }
      .width('100%')
      .height(LobsterKeyboardMetrics.TOOLBAR_HEIGHT_DP)
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }
}
