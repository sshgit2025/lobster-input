/**
 * 麦克风按钮(1:1 移植安卓 keyboard/typing/MicButtonView.kt)。
 * 单击切换:未录音→开始实时识别;录音中→结束识别(录音中按任意键也会结束,由 ImeBus 拦截)。
 * 录音时外环倒计时(进度/警示走 ImeBus 非响应式原始字段,内部 50ms 定时器刷新外环)。
 * 未登录置灰禁用(键盘仍可打字)。
 */
import { HapticKind, ImeBus } from '../ImeBus'
import { LobsterWaterColors, cssOf, rad } from './KeyboardTheme'

@Component
export struct MicButtonView {
  @Prop @Watch('onFlagsChanged') recording: boolean = false
  @Prop @Watch('onFlagsChanged') micEnabled: boolean = true

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private ready: boolean = false
  private timerId: number = -1

  onFlagsChanged(propName: string): void {
    this.syncTimer()
    this.draw()
  }

  aboutToDisappear(): void {
    this.stopTimer()
  }

  /** 录音中启动外环刷新定时器(消费 micProgressRaw / micWarningRaw),停止即销毁。 */
  private syncTimer(): void {
    if (this.recording && this.micEnabled) {
      if (this.timerId === -1) {
        this.timerId = setInterval(() => {
          this.draw()
        }, 50)
      }
    } else {
      this.stopTimer()
    }
  }

  private stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
  }

  private handleClick(): void {
    if (!this.micEnabled) {
      return
    }
    const bus = ImeBus.getInstance()
    bus.performHaptic(HapticKind.TAP)
    if (this.recording) {
      bus.onMicRecordEnd()
    } else {
      bus.onMicRecordStart()
    }
  }

  // ================= 绘制(逐行对齐安卓 onDraw)=================

  private draw(): void {
    if (!this.ready) {
      return
    }
    const ctx = this.ctx
    const w = ctx.width
    const h = ctx.height
    if (w <= 0 || h <= 0) {
      return
    }
    ctx.clearRect(0, 0, w, h)
    const cx = w / 2
    const cy = h / 2
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'

    if (!this.micEnabled) {
      // 置灰禁用态:只画灰色麦克风轮廓
      const gray = cssOf(LobsterWaterColors.TEXT_MUTED)
      this.drawMicBody(ctx, cx, cy, false, gray, gray)
      this.drawMicStand(ctx, cx, cy, gray)
      return
    }
    const bus = ImeBus.getInstance()
    const warning = bus.micWarningRaw
    const accent = warning ? LobsterWaterColors.ERROR : LobsterWaterColors.ACCENT
    if (this.recording) {
      const progress = Math.max(0, Math.min(1, bus.micProgressRaw))
      const r = Math.min(w, h) / 2 - 2
      // 背景整环
      ctx.strokeStyle = cssOf(LobsterWaterColors.BORDER)
      ctx.lineWidth = 2.2
      ctx.beginPath()
      ctx.arc(cx, cy, r, 0, Math.PI * 2, false)
      ctx.stroke()
      // 剩余进度弧(从顶部逆时针,与安卓 sweep 为负一致)
      ctx.strokeStyle = cssOf(accent)
      ctx.beginPath()
      ctx.arc(cx, cy, r, rad(-90), rad(-90 - progress * 360), true)
      ctx.stroke()
      // 实心麦克风 + 白色支架
      this.drawMicBody(ctx, cx, cy, true, cssOf(accent), cssOf(accent))
      this.drawMicStand(ctx, cx, cy, cssOf(LobsterWaterColors.TEXT_ON_ACCENT))
    } else {
      const deep = cssOf(LobsterWaterColors.ACCENT_DEEP)
      this.drawMicBody(ctx, cx, cy, false, deep, deep)
      this.drawMicStand(ctx, cx, cy, deep)
    }
  }

  private drawMicBody(ctx: CanvasRenderingContext2D, cx: number, cy: number,
    fill: boolean, fillColor: string, strokeColor: string): void {
    const bw = 3.4
    const top = cy - 8.5
    const bot = cy - 0.5
    this.roundRect(ctx, cx - bw, top, bw * 2, bot - top, bw)
    if (fill) {
      ctx.fillStyle = fillColor
      ctx.fill()
    } else {
      ctx.strokeStyle = strokeColor
      ctx.lineWidth = 1.7
      ctx.stroke()
    }
  }

  private drawMicStand(ctx: CanvasRenderingContext2D, cx: number, cy: number, color: string): void {
    ctx.strokeStyle = color
    ctx.lineWidth = 1.7
    // 支架弧(安卓 oval 为 13x10 的椭圆,起 20° 扫 140°)
    ctx.beginPath()
    ctx.ellipse(cx, cy - 0.5, 6.5, 5, 0, rad(20), rad(160), false)
    ctx.stroke()
    ctx.beginPath()
    ctx.moveTo(cx, cy + 4.5)
    ctx.lineTo(cx, cy + 8)
    ctx.moveTo(cx - 4, cy + 8)
    ctx.lineTo(cx + 4, cy + 8)
    ctx.stroke()
  }

  private roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
    const rr = Math.min(r, Math.min(w, h) / 2)
    ctx.beginPath()
    ctx.moveTo(x + rr, y)
    ctx.arcTo(x + w, y, x + w, y + h, rr)
    ctx.arcTo(x + w, y + h, x, y + h, rr)
    ctx.arcTo(x, y + h, x, y, rr)
    ctx.arcTo(x, y, x + w, y, rr)
    ctx.closePath()
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.ready = true
        this.syncTimer()
        this.draw()
      })
      .onClick(() => {
        this.handleClick()
      })
  }
}
