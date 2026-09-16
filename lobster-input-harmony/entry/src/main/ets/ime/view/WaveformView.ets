/**
 * 音波波形动画(录音态,1:1 移植安卓 keyboard/typing/WaveformView.kt)。
 * 竖条高度由实时音量驱动并逐帧插值,叠加正弦相位使动画自然不僵硬;
 * 临近录音上限时染警示色。音量/警示走 ImeBus 非响应式原始字段,由帧循环轮询,
 * 避免每个音频帧触发面板全量刷新。
 * 组件仅在录音期间挂载:挂载即 start,卸载即 stop。
 */
import { ImeBus } from '../ImeBus'
import { LobsterWaterColors, cssOf } from './KeyboardTheme'

@Component
export struct WaveformView {
  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private ready: boolean = false

  private readonly barCount: number = 9
  private current: number[] = [0, 0, 0, 0, 0, 0, 0, 0, 0]
  private tick: number = 0
  private timerId: number = -1

  aboutToDisappear(): void {
    this.stop()
  }

  private start(): void {
    if (this.timerId !== -1) {
      return
    }
    // 安卓 postInvalidateOnAnimation 逐帧驱动(≈60fps),此处用 16ms 定时器等价
    this.timerId = setInterval(() => {
      this.tick += 0.32
      this.draw()
    }, 16)
  }

  private stop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
    for (let i = 0; i < this.current.length; i++) {
      this.current[i] = 0
    }
  }

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
    const bus = ImeBus.getInstance()
    const level = Math.max(0, Math.min(1, bus.micLevelRaw))
    const warning = bus.micWarningRaw

    const barW = 2.6
    const gap = 3.2
    const totalW = this.barCount * barW + (this.barCount - 1) * gap
    let x = (w - totalW) / 2
    const midY = h / 2
    const maxBar = h * 0.78
    ctx.fillStyle = cssOf(warning ? LobsterWaterColors.ERROR : LobsterWaterColors.ACCENT)

    for (let i = 0; i < this.barCount; i++) {
      // 目标高度:音量 × 每根不同相位的正弦,边缘略低,中间略高
      const phase = this.tick + i * 0.7
      const shape = 0.45 + 0.55 * ((Math.sin(phase) + 1) / 2)
      const edge = 1 - Math.abs(i - (this.barCount - 1) / 2) / this.barCount * 0.5
      const target = Math.min(3 + level * maxBar * shape * edge, maxBar)
      this.current[i] += (target - this.current[i]) * 0.28
      const bh = Math.max(this.current[i], 3)
      this.fillRoundBar(ctx, x, midY - bh / 2, barW, bh, barW / 2)
      x += barW + gap
    }
  }

  /** 圆头竖条(等价安卓 drawRoundRect,r = 条宽一半)。 */
  private fillRoundBar(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
    const rr = Math.min(r, Math.min(w, h) / 2)
    ctx.beginPath()
    ctx.moveTo(x + rr, y)
    ctx.arcTo(x + w, y, x + w, y + h, rr)
    ctx.arcTo(x + w, y + h, x, y + h, rr)
    ctx.arcTo(x, y + h, x, y, rr)
    ctx.arcTo(x, y, x + w, y, rr)
    ctx.closePath()
    ctx.fill()
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.ready = true
        this.start()
      })
  }
}
