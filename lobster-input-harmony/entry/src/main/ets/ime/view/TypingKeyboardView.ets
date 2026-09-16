/**
 * 打字键盘面板(1:1 移植安卓 keyboard/typing/TypingKeyboardView.kt)。
 * 组装候选栏 + 键区 + 工具/emoji/剪贴板/分类符号板子页 + 长按气泡 + 左侧竖排拼音选择器
 * + 展开多行候选面板 + 输入阻塞遮罩。
 * 面板背景:与语音面板完全一致的纵向冰面渐变;键区行高动态吃满键区(行高反推,不依赖测量时机)。
 * 状态来自 ImeBus(逻辑层写入),事件经 ImeBus 转发逻辑层。
 */
import { KeySpec, KeyType } from '../../keyboard/typing/KeyModels'
import { Candidate } from '../../keyboard/pinyin/PinyinEngine'
import { SymbolData } from '../../keyboard/typing/SymbolData'
import { EmojiData } from '../../keyboard/typing/EmojiData'
import { MobileStrings } from '../../core/locale/MobileStrings'
import { ImeBus, ImeBusState, ImePageKind } from '../ImeBus'
import {
  KeycapButton,
  LobsterKeyboardMetrics,
  LobsterWaterColors
} from './KeyboardTheme'
import { KeyView } from './KeyView'
import { CandidateBarView } from './CandidateBarView'

/** 工具子页磁贴描述。 */
interface ToolTile {
  key: string
  glyph: string
  label: string
}

/** 根容器左右 padding(vp,对齐安卓 setPadding(3,0,3,5))。 */
const ROOT_PADDING_H: number = 3
/** 根容器底 padding(vp)。 */
const ROOT_PADDING_BOTTOM: number = 5

/** 字符串数组按列数切行。 */
function chunkStrings(arr: string[], size: number): string[][] {
  const out: string[][] = []
  for (let i = 0; i < arr.length; i += size) {
    out.push(arr.slice(i, i + size))
  }
  return out
}

/** 磁贴数组按列数切行。 */
function chunkTiles(arr: ToolTile[], size: number): ToolTile[][] {
  const out: ToolTile[][] = []
  for (let i = 0; i < arr.length; i += size) {
    out.push(arr.slice(i, i + size))
  }
  return out
}

@Component
export struct TypingKeyboardView {
  @ObjectLink state: ImeBusState

  private bus: ImeBus = ImeBus.getInstance()

  // ---- 长按气泡 ----
  @State bubbleVisible: boolean = false
  @State bubbleText: string = ''
  @State bubbleX: number = 0
  @State bubbleY: number = 0

  // ---- 测量(气泡/选择器定位)----
  @State rootWidth: number = 360
  @State candBarHeight: number = LobsterKeyboardMetrics.TOOLBAR_HEIGHT_DP
  @State firstKeyWidth: number = 44
  private rootGX: number = 0
  private rootGY: number = 0

  /**
   * 键区可用高度(vp)= 打字面板内容高 266 - 根上 padding(0) - 根下 padding(5) - 候选栏行高 44。
   * 用固定规格反推,不依赖测量时机(对齐安卓 keyboardAreaHeightPx)。
   */
  private keyAreaHeight(): number {
    return LobsterKeyboardMetrics.TYPING_CONTENT_HEIGHT_DP - ROOT_PADDING_BOTTOM -
      LobsterKeyboardMetrics.TOOLBAR_HEIGHT_DP
  }

  /** 行高动态吃满键区:行高 = (键区可用高 - 行距总和) / 行数,底部不留死空隙。 */
  private rowHeight(): number {
    const n = this.state.rows.length
    if (n <= 0) {
      return 46
    }
    return (this.keyAreaHeight() - n * LobsterKeyboardMetrics.KEY_ROW_SPACING_DP) / n
  }

  /** 工具/emoji/剪贴板/符号板子页滚动区高度(vp):吃满键区,只给底部返回栏留位。 */
  private subPageScrollHeight(): number {
    return this.keyAreaHeight() - 40 - 2
  }

  /**
   * 左侧竖排拼音选择器是否显示(输入态)。
   * 【常驻可改选,2026-07-11】展开候选面板时选择器保留(对齐搜狗:展开态左列拼音仍可改选),
   * 面板内容左缩进避让(见 CandidatesPanel)。
   */
  private selectorShowing(): boolean {
    return this.state.pageKind === ImePageKind.KEYS && this.state.pinyinOptions.length > 0
  }

  // ---- 气泡定位(对齐安卓 onKeyShowBubble:键正上方,水平钳位)----
  private showBubble(text: string, gX: number, gY: number, kw: number, kh: number): void {
    const bw = 46
    const bh = 52
    const centerX = gX - this.rootGX - ROOT_PADDING_H + kw / 2
    const topY = gY - this.rootGY
    this.bubbleX = Math.min(Math.max(centerX - bw / 2, 0), Math.max(this.rootWidth - ROOT_PADDING_H * 2 - bw, 0))
    this.bubbleY = Math.max(topY - bh - 2, 0)
    this.bubbleText = text
    this.bubbleVisible = true
  }

  private hideBubble(): void {
    this.bubbleVisible = false
  }

  // ---- 工具子页磁贴(布局切换/emoji/剪贴板/俄语·韩语直达)----
  private toolTiles(): ToolTile[] {
    const tiles: ToolTile[] = []
    const cn = this.state.chineseMode
    const lang = this.state.currentLangCode
    // 布局切换(26↔九宫格)仅中文有意义
    if (cn) {
      const t: ToolTile = {
        key: 'layout',
        glyph: this.state.nineGrid ? '⌨' : '⑨',
        label: this.state.nineGrid ? MobileStrings.switchTo26Keys() : MobileStrings.switchToNineGrid()
      }
      tiles.push(t)
    }
    const emoji: ToolTile = { key: 'emoji', glyph: '😊', label: MobileStrings.toolEmoji() }
    tiles.push(emoji)
    const clip: ToolTile = { key: 'clip', glyph: '📋', label: MobileStrings.toolClipboard() }
    tiles.push(clip)
    // 扩展语种键盘直达(对齐 Gboard 语言切换菜单):已在该语种时显示退出
    const ru: ToolTile = {
      key: 'lang_ru',
      glyph: 'РУ',
      label: lang === 'ru' ? MobileStrings.exitRussian() : 'Русский'
    }
    tiles.push(ru)
    const ko: ToolTile = {
      key: 'lang_ko',
      glyph: '한',
      label: lang === 'ko' ? MobileStrings.exitKorean() : '한국어'
    }
    tiles.push(ko)
    return tiles
  }

  // ---- 分类符号板数据 ----
  private symCatIds(): string[] {
    const ids: string[] = [SymbolData.RECENT_ID]
    for (let i = 0; i < SymbolData.categories.length; i++) {
      ids.push(SymbolData.categories[i].id)
    }
    return ids
  }

  /** 进入时若「最近」为空默认落到中文分类(避免空面板,对齐安卓)。 */
  private symEffectiveCategory(): string {
    if (this.state.symBoardCategory === SymbolData.RECENT_ID && this.state.recentSymbols.length === 0) {
      return 'zh'
    }
    return this.state.symBoardCategory
  }

  private symItems(): string[] {
    const cat = this.symEffectiveCategory()
    if (cat === SymbolData.RECENT_ID) {
      return this.state.recentSymbols
    }
    for (let i = 0; i < SymbolData.categories.length; i++) {
      if (SymbolData.categories[i].id === cat) {
        return SymbolData.categories[i].items
      }
    }
    return []
  }

  private symCols(): number {
    const cols = Math.floor((this.rootWidth - 72) / 46)
    return Math.max(5, Math.min(9, cols))
  }

  // ---- emoji 数据 ----
  private emojiCols(): number {
    const cols = Math.floor((this.rootWidth - 8) / 46)
    return Math.max(6, Math.min(10, cols))
  }

  private emojiAll(): string[] {
    const cols = this.emojiCols()
    const all: string[] = []
    const rec = this.state.recentEmojis
    if (rec.length > 0) {
      const take = Math.min(rec.length, cols * 2)
      for (let i = 0; i < take; i++) {
        all.push(rec[i])
      }
    }
    for (let i = 0; i < EmojiData.categories.length; i++) {
      const items = EmojiData.categories[i].items
      for (let j = 0; j < items.length; j++) {
        all.push(items[j])
      }
    }
    return all
  }

  /** 子页返回按钮文案(中文回「拼音」,否则「ABC」,对齐安卓)。 */
  private backLabel(): string {
    return this.state.chineseMode ? MobileStrings.pinyinLabel() : MobileStrings.abcKeyLabel()
  }

  /** 生成 n 个占位索引(符号网格尾行补齐)。 */
  private padIndices(n: number): number[] {
    const a: number[] = []
    for (let i = 0; i < n; i++) {
      a.push(i)
    }
    return a
  }

  // ================= 构建 =================

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        // ---- 候选栏(状态条 + 工具栏行)----
        Column() {
          CandidateBarView({ state: this.state })
        }
        .width('100%')
        .onAreaChange((oldArea: Area, newArea: Area) => {
          this.candBarHeight = Number(newArea.height)
        })

        // ---- 键区 / 展开候选面板 / 子页 ----
        Column() {
          if (this.state.panelOpen) {
            this.CandidatesPanel()
          } else if (this.state.pageKind === ImePageKind.TOOLS) {
            this.ToolsPage()
          } else if (this.state.pageKind === ImePageKind.EMOJI) {
            this.EmojiPage()
          } else if (this.state.pageKind === ImePageKind.CLIP) {
            this.ClipboardPage()
          } else if (this.state.pageKind === ImePageKind.SYM_BOARD) {
            this.SymBoardPage()
          } else {
            this.KeyRows()
          }
        }
        .width('100%')
        .opacity(this.state.inputBlocked ? 0.45 : 1)
      }
      .width('100%')

      // ---- 左侧竖排拼音选择器(覆盖键区最左一列,搜狗式)----
      if (this.selectorShowing()) {
        Scroll() {
          Column() {
            ForEach(this.state.pinyinOptions, (opt: string) => {
              Text(opt)
                .fontSize(opt.length > 3 ? 11 : 13)
                .fontWeight(FontWeight.Bold)
                .fontColor(opt === this.state.pinyinActive ?
                  LobsterWaterColors.TEXT_ON_ACCENT : LobsterWaterColors.ACCENT_DEEP)
                .textAlign(TextAlign.Center)
                .width('100%')
                .height(42)
                .margin({ top: 2 })
                .backgroundColor(opt === this.state.pinyinActive ?
                  LobsterWaterColors.ACCENT : LobsterWaterColors.BADGE_INACTIVE_BG)
                .borderRadius(8)
                .border({
                  width: opt === this.state.pinyinActive ? 0 : 1,
                  color: LobsterWaterColors.ACCENT_SOFT
                })
                .onClick(() => {
                  this.bus.onPinyinOptionSelected(opt)
                })
            }, (opt: string, i: number) => `${i}_${opt}_${opt === this.state.pinyinActive}`)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.None)
        .backgroundColor(LobsterWaterColors.PANEL_BG)
        .width(this.firstKeyWidth)
        .height(this.keyAreaHeight() - LobsterKeyboardMetrics.KEY_ROW_SPACING_DP)
        .position({
          x: 2.5,
          y: this.candBarHeight + LobsterKeyboardMetrics.KEY_ROW_SPACING_DP + 2.5
        })
      }

      // ---- 长按气泡(键正上方)----
      if (this.bubbleVisible) {
        Text(this.bubbleText)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(LobsterWaterColors.TEXT_MAIN)
          .textAlign(TextAlign.Center)
          .width(46)
          .height(52)
          .backgroundColor(LobsterWaterColors.PANEL_SURFACE)
          .borderRadius(8)
          .border({ width: 1, color: LobsterWaterColors.BORDER })
          .shadow({ radius: 4, color: 0x26000000, offsetX: 0, offsetY: 2 })
          .position({ x: this.bubbleX, y: this.bubbleY })
          .hitTestBehavior(HitTestMode.None)
      }

      // ---- 输入阻塞遮罩(词库装载中/失败时拦截点击)----
      if (this.state.inputBlocked) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(LobsterWaterColors.PANEL_SCRIM)
          .onClick(() => {
          })
      }
    }
    .width('100%')
    .linearGradient({
      angle: 180,
      colors: [[LobsterWaterColors.PANEL_BG_TOP, 0], [LobsterWaterColors.PANEL_BG_BOTTOM, 1]]
    })
    // 上 padding 为 0:候选栏顶边与语音面板 header 顶边同一 Y,两模式左上按钮完全对齐
    .padding({ left: ROOT_PADDING_H, top: 0, right: ROOT_PADDING_H, bottom: ROOT_PADDING_BOTTOM })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.rootWidth = Number(newArea.width)
      if (newArea.globalPosition.x !== undefined) {
        this.rootGX = Number(newArea.globalPosition.x)
      }
      if (newArea.globalPosition.y !== undefined) {
        this.rootGY = Number(newArea.globalPosition.y)
      }
    })
  }

  // ---- 常规键区(行列 + 权重)----
  @Builder
  KeyRows() {
    Column() {
      ForEach(this.state.rows, (row: KeySpec[], ri: number) => {
        Row() {
          ForEach(row, (spec: KeySpec, ci: number) => {
            if (spec.type === KeyType.GAP) {
              Row()
                .layoutWeight(spec.weight)
                .height('100%')
            } else {
              KeyView({
                spec: spec,
                shiftActive: this.state.shiftActive,
                capsLock: this.state.capsLock,
                chineseMode: this.state.chineseMode,
                redrawEpoch: this.state.keysRedrawEpoch,
                onShowBubble: (text: string, gX: number, gY: number, kw: number, kh: number) => {
                  this.showBubble(text, gX, gY, kw, kh)
                },
                onHideBubble: () => {
                  this.hideBubble()
                }
              })
                .layoutWeight(spec.weight)
                .height('100%')
                .margin({ left: 2.5, right: 2.5 })
                // 选择器覆盖时隐藏最左一列原按键(Hidden 保留占位不抖动,对齐安卓 INVISIBLE)
                .visibility(this.selectorShowing() && ci === 0 ? Visibility.Hidden : Visibility.Visible)
                .onAreaChange((oldArea: Area, newArea: Area) => {
                  if (ri === 0 && ci === 0) {
                    this.firstKeyWidth = Number(newArea.width)
                  }
                })
            }
          }, (spec: KeySpec, ci: number) => `${this.state.keyboardEpoch}_${ri}_${ci}_${spec.main}`)
        }
        .width('100%')
        .height(this.rowHeight())
        .margin({ top: LobsterKeyboardMetrics.KEY_ROW_SPACING_DP })
      }, (row: KeySpec[], ri: number) => `${this.state.keyboardEpoch}_${ri}`)
    }
    .width('100%')
  }

  // ---- 展开多行候选网格面板(覆盖键区位置,纵向滚动看全部候选)----
  @Builder
  CandidatesPanel() {
    Scroll() {
      Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
        ForEach(this.state.candidates, (c: Candidate, i: number) => {
          // Secondary pill 风格候选 chip(保留小圆角)
          Text(c.word)
            .fontSize(18)
            .fontColor(LobsterWaterColors.TEXT_MAIN)
            .textAlign(TextAlign.Center)
            .padding({ left: 12, top: 8, right: 12, bottom: 8 })
            .backgroundColor(LobsterWaterColors.BUTTON_BG)
            .borderRadius(10)
            .border({ width: 1, color: LobsterWaterColors.SECONDARY_STROKE })
            .margin({ right: 4, bottom: 4 })
            .onClick(() => {
              this.bus.closeCandidatesPanel()
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
      // 【常驻可改选】选择器可见时内容左缩进避让(列宽 + 6 缝隙),左列拼音在展开态仍可改选
      .padding({
        left: this.selectorShowing() ? this.firstKeyWidth + 6 + 4 : 4,
        top: 4, right: 4, bottom: 4
      })
      .width('100%')
    }
    .scrollBar(BarState.Auto)
    .width('100%')
    .height(this.keyAreaHeight())
    .align(Alignment.TopStart)
  }

  // ---- 工具子页(齿轮入口):布局切换 / emoji / 剪贴板 / 俄语·韩语键盘磁贴 + 返回 ----
  @Builder
  ToolsPage() {
    Column() {
      Scroll() {
        Column() {
          ForEach(chunkTiles(this.toolTiles(), 3), (tileRow: ToolTile[], ri: number) => {
            Row() {
              ForEach(tileRow, (tile: ToolTile) => {
                Column() {
                  Text(tile.glyph)
                    .fontSize(24)
                    .textAlign(TextAlign.Center)
                  Text(tile.label)
                    .fontSize(12)
                    .fontColor(LobsterWaterColors.ACCENT_DEEP)
                    .textAlign(TextAlign.Center)
                    .padding({ top: 4 })
                }
                .justifyContent(FlexAlign.Center)
                .layoutWeight(1)
                .height(64)
                .margin({ left: 5, right: 5, top: 5 })
                .backgroundColor(LobsterWaterColors.BADGE_INACTIVE_BG)
                .borderRadius(12)
                .border({ width: 1, color: LobsterWaterColors.BORDER })
                .onClick(() => {
                  this.bus.onToolSelected(tile.key)
                })
              }, (tile: ToolTile) => tile.key)
            }
            .width('100%')
          }, (tileRow: ToolTile[], ri: number) => `tools_${this.state.keyboardEpoch}_${ri}`)
        }
        .width('100%')
        .padding({ left: 8, top: 10, right: 8, bottom: 10 })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .height(this.subPageScrollHeight())
      .align(Alignment.TopStart)

      Row() {
        KeycapButton({
          label: MobileStrings.back(),
          fontSizeFp: 14,
          radiusVp: 12,
          heightVp: 40,
          stretch: true,
          onTap: () => {
            this.bus.onBackToAlpha()
          }
        })
          .layoutWeight(1)
          .margin({ left: 3, right: 3 })
      }
      .width('100%')
      .height(40)
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  // ---- emoji 面板:纵向滚动网格(最近 + 分类) + 返回/删除 ----
  @Builder
  EmojiPage() {
    Column() {
      Scroll() {
        Column() {
          ForEach(chunkStrings(this.emojiAll(), this.emojiCols()), (emojiRow: string[], ri: number) => {
            Row() {
              ForEach(emojiRow, (e: string, ci: number) => {
                Text(e)
                  .fontSize(22)
                  .textAlign(TextAlign.Center)
                  .layoutWeight(1)
                  .height(40)
                  .onClick(() => {
                    this.bus.onEmojiSelected(e)
                  })
              }, (e: string, ci: number) => `${ri}_${ci}_${e}`)
            }
            .width('100%')
          }, (emojiRow: string[], ri: number) => `emoji_${this.state.subPageEpoch}_${ri}`)
        }
        .width('100%')
        .padding({ left: 4, top: 2, right: 4, bottom: 2 })
      }
      .scrollBar(BarState.Auto)
      .width('100%')
      .height(this.subPageScrollHeight())
      .align(Alignment.TopStart)

      this.SubPageFooter(this.backLabel())
    }
    .width('100%')
  }

  // ---- 剪贴板面板:剪贴历史(长按删) + 快捷短语 ----
  @Builder
  ClipboardPage() {
    Column() {
      Scroll() {
        Column() {
          this.ClipSectionLabel(MobileStrings.toolClipboard())
          if (this.state.clipboardHistory.length === 0) {
            Text(MobileStrings.clipEmptyHint())
              .fontSize(13)
              .fontColor(LobsterWaterColors.TEXT_MUTED)
              .width('100%')
              .padding(6)
          } else {
            ForEach(this.state.clipboardHistory, (item: string, i: number) => {
              this.ClipItemRow(item, true)
            }, (item: string, i: number) => `clip_${this.state.subPageEpoch}_${i}`)
          }
          this.ClipSectionLabel(MobileStrings.quickPhrasesLabel())
          ForEach(this.state.quickPhrases, (item: string, i: number) => {
            this.ClipItemRow(item, false)
          }, (item: string, i: number) => `phrase_${this.state.subPageEpoch}_${i}`)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 8, top: 6, right: 8, bottom: 6 })
      }
      .scrollBar(BarState.Auto)
      .width('100%')
      .height(this.subPageScrollHeight())
      .align(Alignment.TopStart)

      // footer:返回 + 清空
      Row() {
        KeycapButton({
          label: this.backLabel(),
          fontSizeFp: 14,
          radiusVp: 12,
          heightVp: 40,
          stretch: true,
          onTap: () => {
            this.bus.onBackToAlpha()
          }
        })
          .layoutWeight(1.4)
          .margin({ left: 3, right: 3 })
        Row()
          .layoutWeight(4)
        KeycapButton({
          label: MobileStrings.clearInput(),
          fontSizeFp: 14,
          radiusVp: 12,
          heightVp: 40,
          stretch: true,
          onTap: () => {
            this.bus.onClipClear()
          }
        })
          .layoutWeight(1.4)
          .margin({ left: 3, right: 3 })
      }
      .width('100%')
      .height(40)
      .margin({ top: 2 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  @Builder
  ClipSectionLabel(label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Bold)
      .fontColor(LobsterWaterColors.ACCENT_DEEP)
      .padding({ left: 4, top: 8, right: 4, bottom: 4 })
  }

  @Builder
  ClipItemRow(item: string, deletable: boolean) {
    Text(item)
      .fontSize(15)
      .fontColor(LobsterWaterColors.TEXT_MAIN)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .padding({ left: 12, top: 11, right: 12, bottom: 11 })
      .backgroundColor(LobsterWaterColors.BADGE_INACTIVE_BG)
      .borderRadius(12)
      .border({ width: 1, color: LobsterWaterColors.BORDER })
      .margin({ bottom: 6 })
      .onClick(() => {
        this.bus.onClipSelected(item)
      })
      .gesture(
        LongPressGesture({ duration: 500 })
          .onAction(() => {
            if (deletable) {
              this.bus.onClipRemove(item)
            }
          })
      )
  }

  // ---- 分类符号板:左侧竖排分类标签 + 右侧滚动符号网格 + 返回/删除 ----
  @Builder
  SymBoardPage() {
    Column() {
      Row() {
        // 左侧分类栏(纵向滚动)
        Scroll() {
          Column() {
            ForEach(this.symCatIds(), (id: string) => {
              Text(SymbolData.label(id, MobileStrings.currentLanguage().code))
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(id === this.symEffectiveCategory() ?
                  LobsterWaterColors.TEXT_ON_ACCENT : LobsterWaterColors.ACCENT_DEEP)
                .textAlign(TextAlign.Center)
                .width('100%')
                .height(34)
                .margin({ bottom: 4 })
                .backgroundColor(id === this.symEffectiveCategory() ?
                  LobsterWaterColors.ACCENT : LobsterWaterColors.BADGE_INACTIVE_BG)
                .borderRadius(8)
                .border({
                  width: id === this.symEffectiveCategory() ? 0 : 1,
                  color: LobsterWaterColors.BORDER
                })
                .onClick(() => {
                  this.bus.onSymBoardCategorySelected(id)
                })
            }, (id: string) => `symcat_${id}_${id === this.symEffectiveCategory()}`)
          }
          .width('100%')
          .padding({ left: 4, top: 4, right: 2, bottom: 4 })
        }
        .scrollBar(BarState.Off)
        .width(64)
        .height('100%')
        .align(Alignment.TopStart)

        // 右侧符号网格(纵向滚动,尾行占位补齐保证格子等宽)
        Scroll() {
          Column() {
            ForEach(chunkStrings(this.symItems(), this.symCols()), (symRow: string[], ri: number) => {
              Row() {
                ForEach(symRow, (s: string, ci: number) => {
                  KeycapButton({
                    label: s,
                    fontSizeFp: 18,
                    radiusVp: 10,
                    heightVp: 40,
                    stretch: true,
                    bold: false,
                    textColorOverride: LobsterWaterColors.TEXT_MAIN,
                    onTap: () => {
                      this.bus.onSymbolSelected(s)
                    }
                  })
                    .layoutWeight(1)
                    .margin({ left: 2, right: 2, top: 2, bottom: 2 })
                }, (s: string, ci: number) => `${ri}_${ci}_${s}`)
                // 尾行补齐占位,保证格子等宽
                if (symRow.length < this.symCols()) {
                  ForEach(this.padIndices(this.symCols() - symRow.length), (pi: number) => {
                    Row()
                      .layoutWeight(1)
                      .height(40)
                      .margin({ left: 2, right: 2 })
                  }, (pi: number) => `pad_${ri}_${pi}`)
                }
              }
              .width('100%')
            }, (symRow: string[], ri: number) =>
              `sym_${this.symEffectiveCategory()}_${this.state.subPageEpoch}_${ri}`)
          }
          .width('100%')
          .padding({ left: 2, top: 4, right: 4, bottom: 4 })
        }
        .scrollBar(BarState.Auto)
        .layoutWeight(1)
        .height('100%')
        .align(Alignment.TopStart)
      }
      .width('100%')
      .height(this.subPageScrollHeight())
      .alignItems(VerticalAlign.Top)

      // 符号板返回按钮文案用「返回」(对齐安卓 TypingKeyboardView.kt:314,B-7)
      this.SubPageFooter(MobileStrings.back())
    }
    .width('100%')
  }

  // ---- 子页通用 footer:返回 + 删除(emoji/符号板共用规格,返回文案由调用方传入)----
  @Builder
  SubPageFooter(backText: string) {
    Row() {
      KeycapButton({
        label: backText,
        fontSizeFp: 14,
        radiusVp: 12,
        heightVp: 40,
        stretch: true,
        onTap: () => {
          this.bus.onBackToAlpha()
        }
      })
        .layoutWeight(1.4)
        .margin({ left: 3, right: 3 })
      Row()
        .layoutWeight(4)
      KeycapButton({
        label: '⌫',
        fontSizeFp: 14,
        radiusVp: 12,
        heightVp: 40,
        stretch: true,
        onTap: () => {
          this.bus.onDeleteOnce()
        }
      })
        .layoutWeight(1.4)
        .margin({ left: 3, right: 3 })
    }
    .width('100%')
    .height(40)
    .margin({ top: 2 })
    .alignItems(VerticalAlign.Center)
  }
}
