/**
 * 自绘键帽(1:1 移植安卓 keyboard/typing/KeyView.kt)。
 * 单一职责:渲染一个键 + 触摸反馈;不持有键盘状态,shift/中文态由父组件以 @Prop 注入,
 * 按键事件经 ImeBus 转发逻辑层。Canvas 逐效果复刻 onDraw:
 * 3D 键帽 = 底缘投影 + 纵向渐变键帽体 + 描边/回车玻璃高光,按压时投影收窄 + 键帽下沉 1vp。
 */
import { common } from '@kit.AbilityKit'
import { KeySpec, KeyType } from '../../keyboard/typing/KeyModels'
import { TypingAccessibilityLabels } from '../../keyboard/typing/accessibility/TypingAccessibilityLabels'
import { ImeBus } from '../ImeBus'
import {
  LobsterKeyboardMetrics,
  LobsterWaterColors,
  canvasFont,
  cssOf,
  rad,
  roundRectPath
} from './KeyboardTheme'

@Component
export struct KeyView {
  /** 键描述(必传;由父组件 rows 提供)。 */
  spec: KeySpec | null = null
  @Prop @Watch('onVisualChanged') shiftActive: boolean = false
  @Prop @Watch('onVisualChanged') capsLock: boolean = false
  @Prop @Watch('onVisualChanged') chineseMode: boolean = false
  /** 键帽重绘代号(invalidateKeys 触发)。 */
  @Prop @Watch('onVisualChanged') redrawEpoch: number = 0
  /** 气泡回调:text + 键左上角全局坐标 + 键宽高(vp)。 */
  onShowBubble: (text: string, gX: number, gY: number, kw: number, kh: number) => void =
    (text: string, gX: number, gY: number, kw: number, kh: number) => {}
  onHideBubble: () => void = () => {}

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private ready: boolean = false
  private pressed: boolean = false

  // 长按(300ms,对齐安卓 longRunnable)
  private longTimer: number = -1
  private longFired: boolean = false

  // 空格滑动移光标(步长 12vp,对齐安卓 installSpaceTouch)
  private spaceStartX: number = 0
  private spaceAccum: number = 0
  private spaceSlid: boolean = false

  // 自身全局位置(气泡定位用)
  private areaGX: number = 0
  private areaGY: number = 0
  private areaW: number = 0
  private areaH: number = 0

  onVisualChanged(propName: string): void {
    this.draw()
  }

  aboutToDisappear(): void {
    this.clearLongTimer()
  }

  private clearLongTimer(): void {
    if (this.longTimer !== -1) {
      clearTimeout(this.longTimer)
      this.longTimer = -1
    }
  }

  /**
   * 无障碍标签(等价安卓 KeyView init 中的 TypingAccessibilityLabels.applyKeyLabel,
   * 即 contentDescription 语义)。shiftActive/capsLock 为 @Prop,变化时 ArkUI
   * 自动重算本属性,shift 态字母键实时读大写(安卓靠重建键实现同一效果)。
   */
  private keyA11yLabel(): string {
    const spec = this.spec
    if (spec === null) {
      return ''
    }
    return TypingAccessibilityLabels.keyLabel(spec, getContext(this) as common.Context, this.shiftActive, this.capsLock)
  }

  /** shift/caps 态显示字符(韩语双辅音走 shiftValue;拉丁/西里尔非中文模式大写)。 */
  private displayChar(): string {
    const spec = this.spec
    if (spec === null) {
      return ''
    }
    const shifted = this.shiftActive || this.capsLock
    if (spec.type === KeyType.LETTER && shifted && spec.shiftValue !== null && spec.shiftValue !== undefined) {
      return spec.shiftValue
    }
    if (spec.type === KeyType.LETTER && !this.chineseMode && shifted) {
      return spec.main.toUpperCase()
    }
    return spec.main
  }

  // ================= 触摸 =================

  private handleTouch(event: TouchEvent): void {
    const spec = this.spec
    if (spec === null) {
      return
    }
    if (spec.type === KeyType.DELETE) {
      this.handleDeleteTouch(event)
    } else if (spec.type === KeyType.SPACE) {
      this.handleSpaceTouch(event)
    } else {
      this.handleNormalTouch(event)
    }
  }

  private touchPoint(event: TouchEvent): TouchObject | null {
    if (event.changedTouches.length > 0) {
      return event.changedTouches[0]
    }
    if (event.touches.length > 0) {
      return event.touches[0]
    }
    return null
  }

  private handleNormalTouch(event: TouchEvent): void {
    const spec = this.spec
    if (spec === null) {
      return
    }
    if (event.type === TouchType.Down) {
      this.pressed = true
      this.draw()
      this.longFired = false
      if (spec.type === KeyType.LETTER) {
        this.onShowBubble(this.displayChar(), this.areaGX, this.areaGY, this.areaW, this.areaH)
      }
      if (spec.longValue !== null && spec.longValue !== undefined) {
        this.clearLongTimer()
        this.longTimer = setTimeout(() => {
          this.longFired = true
          this.onHideBubble()
          ImeBus.getInstance().onKeyLongPress(spec)
        }, 300)
      }
    } else if (event.type === TouchType.Up) {
      this.pressed = false
      this.draw()
      this.onHideBubble()
      this.clearLongTimer()
      const t = this.touchPoint(event)
      if (!this.longFired && t !== null &&
        t.x >= -10 && t.x <= this.areaW + 10 && t.y >= -14 && t.y <= this.areaH + 14) {
        ImeBus.getInstance().onKeyTap(spec)
      }
    } else if (event.type === TouchType.Cancel) {
      this.pressed = false
      this.draw()
      this.onHideBubble()
      this.clearLongTimer()
    }
  }

  private handleDeleteTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.pressed = true
      this.draw()
      ImeBus.getInstance().onDeletePressDown()
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.pressed = false
      this.draw()
      ImeBus.getInstance().onDeletePressUp()
    }
  }

  /** 空格键:横向滑动移光标,未滑动则正常上屏空格。 */
  private handleSpaceTouch(event: TouchEvent): void {
    const spec = this.spec
    if (spec === null) {
      return
    }
    const stepPx = 12
    const t = this.touchPoint(event)
    if (event.type === TouchType.Down) {
      this.pressed = true
      this.draw()
      this.spaceStartX = t !== null ? t.x : 0
      this.spaceAccum = 0
      this.spaceSlid = false
    } else if (event.type === TouchType.Move) {
      if (t === null) {
        return
      }
      this.spaceAccum += t.x - this.spaceStartX
      this.spaceStartX = t.x
      let steps = 0
      while (this.spaceAccum >= stepPx) {
        steps++
        this.spaceAccum -= stepPx
      }
      while (this.spaceAccum <= -stepPx) {
        steps--
        this.spaceAccum += stepPx
      }
      if (steps !== 0) {
        this.spaceSlid = true
        ImeBus.getInstance().onSpaceSlide(steps)
      }
    } else if (event.type === TouchType.Up) {
      this.pressed = false
      this.draw()
      if (!this.spaceSlid) {
        ImeBus.getInstance().onKeyTap(spec)
      }
    } else if (event.type === TouchType.Cancel) {
      this.pressed = false
      this.draw()
    }
  }

  // ================= 绘制(逐行对齐安卓 onDraw)=================

  private draw(): void {
    if (!this.ready) {
      return
    }
    const spec = this.spec
    if (spec === null) {
      return
    }
    const ctx = this.ctx
    const w = ctx.width
    const h = ctx.height
    if (w <= 0 || h <= 0) {
      return
    }
    ctx.clearRect(0, 0, w, h)

    const r = LobsterKeyboardMetrics.KEY_CORNER_DP
    const enter = spec.type === KeyType.ENTER
    // SYM_CANDS(9 宫格 1 键 @#)与字母键同款键帽:它位于 T9 键区内,视觉须与 2-9 键一致
    const isFunc = spec.type !== KeyType.LETTER && spec.type !== KeyType.T9 && spec.type !== KeyType.SYM_CHAR
      && spec.type !== KeyType.SYM_CANDS
    // 3D 键帽:先画向下偏移的底缘投影,再画键帽;按压时投影收窄 + 键帽整体下沉 1vp
    const sink = this.pressed ? 1 : 0
    const shadowOffset = this.pressed ? 0.5 : 1.5
    const rectTop = sink
    const rectBottom = h - 1.5 + sink
    const rectH = rectBottom - rectTop

    // 底缘投影
    ctx.fillStyle = cssOf(enter ? LobsterWaterColors.ENTER_SHADOW : LobsterWaterColors.KEY_SHADOW)
    roundRectPath(ctx, 0, rectTop + shadowOffset, w, rectH, r)
    ctx.fill()

    // 键帽体纵向渐变
    const grad = ctx.createLinearGradient(0, 0, 0, h)
    if (enter) {
      grad.addColorStop(0, cssOf(LobsterWaterColors.ENTER_TOP))
      grad.addColorStop(1, cssOf(LobsterWaterColors.ENTER_BOTTOM))
    } else if (isFunc) {
      grad.addColorStop(0, cssOf(this.pressed ? LobsterWaterColors.FUNC_PRESS_TOP : LobsterWaterColors.FUNC_TOP))
      grad.addColorStop(1, cssOf(this.pressed ? LobsterWaterColors.FUNC_PRESS_BOTTOM : LobsterWaterColors.FUNC_BOTTOM))
    } else {
      grad.addColorStop(0, cssOf(this.pressed ? LobsterWaterColors.KEY_PRESS_TOP : LobsterWaterColors.KEY_TOP))
      grad.addColorStop(1, cssOf(this.pressed ? LobsterWaterColors.KEY_PRESS_BOTTOM : LobsterWaterColors.KEY_BOTTOM))
    }
    ctx.fillStyle = grad
    roundRectPath(ctx, 0, rectTop, w, rectH, r)
    ctx.fill()

    if (enter) {
      // 回车键:键帽内上半部高光描边,营造玻璃反光
      const inset = 1
      ctx.save()
      ctx.beginPath()
      ctx.rect(0, rectTop, w, rectH / 2)
      ctx.clip()
      ctx.strokeStyle = cssOf(LobsterWaterColors.ENTER_HIGHLIGHT)
      ctx.lineWidth = 1.2
      roundRectPath(ctx, inset, rectTop + inset, w - 2 * inset, rectH - 2 * inset, r - inset)
      ctx.stroke()
      ctx.restore()
    } else {
      ctx.strokeStyle = cssOf(LobsterWaterColors.BORDER)
      ctx.lineWidth = 1
      roundRectPath(ctx, 0, rectTop, w, rectH, r)
      ctx.stroke()
    }

    const cx = w / 2
    const cy = rectTop + rectH / 2
    if (spec.type === KeyType.DELETE) {
      this.drawBackspace(ctx, cx, cy)
    } else if (spec.type === KeyType.ENTER) {
      this.drawEnter(ctx, cx, cy)
    } else if (spec.type === KeyType.SHIFT) {
      this.drawShift(ctx, cx, cy)
    } else if (spec.type === KeyType.MODE_CYCLE) {
      this.drawModeCycle(ctx, cx, cy, spec)
    } else if (spec.type === KeyType.LETTER) {
      ctx.fillStyle = cssOf(LobsterWaterColors.TEXT_MAIN)
      ctx.font = canvasFont(19, false)
      ctx.textAlign = 'center'
      ctx.fillText(this.displayChar(), cx, cy + 7)
    } else if (spec.type === KeyType.T9) {
      ctx.fillStyle = cssOf(LobsterWaterColors.TEXT_MAIN)
      ctx.font = canvasFont(15, true)
      ctx.textAlign = 'center'
      ctx.fillText(spec.main, cx, cy + 2)
      if (spec.sub !== null && spec.sub !== undefined && spec.sub.length > 0) {
        ctx.fillStyle = cssOf(LobsterWaterColors.TEXT_MUTED)
        ctx.font = canvasFont(9, false)
        ctx.fillText(spec.sub, cx, cy + 14)
      }
    } else {
      ctx.fillStyle = cssOf(enter ? LobsterWaterColors.TEXT_ON_ACCENT : LobsterWaterColors.TEXT_MAIN)
      const boldTypes: KeyType[] = [KeyType.LANG, KeyType.NUM, KeyType.SYMBOL, KeyType.ALPHA, KeyType.SYM_PAGE, KeyType.LAYOUT]
      const bold = boldTypes.indexOf(spec.type) >= 0
      const hasSub = spec.sub !== null && spec.sub !== undefined && spec.sub.length > 0
      ctx.font = canvasFont(spec.main.length > 1 ? 14 : 17, bold)
      ctx.textAlign = 'center'
      // 分词键(数字1)等带 sub 的键:主字上移 + 下方小字,对齐九宫格字母键(2-9)
      ctx.fillText(spec.main, cx, cy + (hasSub ? 2 : 5))
      if (hasSub && spec.sub !== null && spec.sub !== undefined) {
        ctx.fillStyle = cssOf(LobsterWaterColors.TEXT_MUTED)
        ctx.font = canvasFont(9, false)
        ctx.fillText(spec.sub, cx, cy + 14)
      }
    }
  }

  private glyphColor(): string {
    return cssOf(this.pressed ? LobsterWaterColors.ACCENT_DEEP : LobsterWaterColors.TEXT_MAIN)
  }

  private drawBackspace(ctx: CanvasRenderingContext2D, cx: number, cy: number): void {
    ctx.strokeStyle = this.glyphColor()
    ctx.lineWidth = 2
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    const w = 11
    const h = 8
    ctx.beginPath()
    ctx.moveTo(cx - w, cy)
    ctx.lineTo(cx - w + 5, cy - h)
    ctx.lineTo(cx + w, cy - h)
    ctx.lineTo(cx + w, cy + h)
    ctx.lineTo(cx - w + 5, cy + h)
    ctx.closePath()
    ctx.stroke()
    ctx.beginPath()
    ctx.moveTo(cx - 1, cy - 4)
    ctx.lineTo(cx + 6, cy + 4)
    ctx.moveTo(cx + 6, cy - 4)
    ctx.lineTo(cx - 1, cy + 4)
    ctx.stroke()
  }

  private drawEnter(ctx: CanvasRenderingContext2D, cx: number, cy: number): void {
    ctx.strokeStyle = cssOf(LobsterWaterColors.TEXT_ON_ACCENT)
    ctx.lineWidth = 2
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    ctx.beginPath()
    ctx.moveTo(cx + 8, cy - 7)
    ctx.lineTo(cx + 8, cy + 2)
    ctx.lineTo(cx - 8, cy + 2)
    ctx.stroke()
    ctx.beginPath()
    ctx.moveTo(cx - 8, cy + 2)
    ctx.lineTo(cx - 3, cy - 3)
    ctx.moveTo(cx - 8, cy + 2)
    ctx.lineTo(cx - 3, cy + 7)
    ctx.stroke()
  }

  private drawShift(ctx: CanvasRenderingContext2D, cx: number, cy: number): void {
    const active = this.shiftActive || this.capsLock
    const color = cssOf(active ? LobsterWaterColors.ACCENT : LobsterWaterColors.TEXT_MAIN)
    ctx.strokeStyle = color
    ctx.fillStyle = color
    ctx.lineWidth = 2
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    ctx.beginPath()
    ctx.moveTo(cx, cy - 9)
    ctx.lineTo(cx + 8, cy - 1)
    ctx.lineTo(cx + 4, cy - 1)
    ctx.lineTo(cx + 4, cy + 6)
    ctx.lineTo(cx - 4, cy + 6)
    ctx.lineTo(cx - 4, cy - 1)
    ctx.lineTo(cx - 8, cy - 1)
    ctx.closePath()
    if (active) {
      ctx.fill()
    }
    ctx.stroke()
    if (this.capsLock) {
      ctx.beginPath()
      ctx.moveTo(cx - 4, cy + 9)
      ctx.lineTo(cx + 4, cy + 9)
      ctx.stroke()
    }
  }

  /**
   * 模式轮换键图标:双弧循环箭头(⟳ 键盘轮换语义)+ 下方下一模式短标签(spec.sub),
   * 用户可预期下一站(逐参数对齐安卓 drawModeCycle)。
   */
  private drawModeCycle(ctx: CanvasRenderingContext2D, cx: number, cy: number, spec: KeySpec): void {
    const color = this.glyphColor()
    ctx.strokeStyle = color
    ctx.fillStyle = color
    ctx.lineWidth = 2
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    const hasSub = spec.sub !== null && spec.sub !== undefined && spec.sub.length > 0
    const iconCy = hasSub ? cy - 4 : cy
    const r = 7
    // 两段开口弧(各 120°)构成循环
    ctx.beginPath()
    ctx.arc(cx, iconCy, r, rad(-80), rad(40), false)
    ctx.stroke()
    ctx.beginPath()
    ctx.arc(cx, iconCy, r, rad(100), rad(220), false)
    ctx.stroke()
    // 弧端箭头(小三角,FILL,指向弧线切线方向)
    const drawArrow = (angleDeg: number): void => {
      const a = rad(angleDeg)
      const ax = cx + r * Math.cos(a)
      const ay = iconCy + r * Math.sin(a)
      const tRad = a + Math.PI / 2
      const dxv = Math.cos(tRad)
      const dyv = Math.sin(tRad)
      const s = 3.4
      ctx.beginPath()
      ctx.moveTo(ax + dxv * s, ay + dyv * s)
      ctx.lineTo(ax - dyv * s * 0.85, ay + dxv * s * 0.85)
      ctx.lineTo(ax + dyv * s * 0.85, ay - dxv * s * 0.85)
      ctx.closePath()
      ctx.fill()
    }
    drawArrow(40)
    drawArrow(220)
    // 下一模式短标签
    if (hasSub && spec.sub !== null && spec.sub !== undefined) {
      ctx.fillStyle = cssOf(LobsterWaterColors.TEXT_MUTED)
      ctx.font = canvasFont(9, false)
      ctx.textAlign = 'center'
      ctx.fillText(spec.sub, cx, cy + 14)
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      // 无障碍:Canvas 自绘无文本节点,必须显式提供朗读文本
      // (等价安卓 View.contentDescription,见 KeyView.kt:73 applyKeyLabel)
      .accessibilityGroup(true)
      .accessibilityText(this.keyA11yLabel())
      .accessibilityLevel('yes')
      .onReady(() => {
        this.ready = true
        this.draw()
      })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.areaW = Number(newArea.width)
        this.areaH = Number(newArea.height)
        if (newArea.globalPosition.x !== undefined) {
          this.areaGX = Number(newArea.globalPosition.x)
        }
        if (newArea.globalPosition.y !== undefined) {
          this.areaGY = Number(newArea.globalPosition.y)
        }
      })
      .onTouch((event: TouchEvent) => {
        this.handleTouch(event)
      })
  }
}
