/**
 * 蓝宝石玻璃涟漪录音钮(1:1 移植安卓 keyboard/RecordOrbView.kt,仅 UI,色值全部收敛引用
 * LobsterWaterColors)。默认态与录音态共用同一套扩散算法;录音时仅略增发射频率,
 * 音量不挤压涟漪到中心。
 *
 * 帧循环:安卓 Choreographer + FRAME_INTERVAL_NS(33.3ms)节流 → 此处 33ms setInterval 等价;
 * 声浪能量走 ImeBus.orbLevelRaw(非响应式)由帧循环消费,避免音频帧高频触发面板重渲染。
 * 状态(recording/processing/loggedIn)由父组件以 @Prop 注入(源自 ImeBusState.orb*)。
 * 交互:单击 onOrbTap;按下/抬起 onOrbTouchDown/Up(实时流式 ASR 长按语义由逻辑层裁决)。
 */
import { ImeBus } from '../ImeBus'
import { LobsterWaterColors, cssOf, rgbaOf } from './KeyboardTheme'

/** 单圈涟漪。 */
class Ripple {
  radius: number
  phase1: number
  phase2: number
  amplitude: number
  life: number
  speed: number
  waves1: number
  waves2: number

  constructor(radius: number, phase1: number, phase2: number, amplitude: number,
    life: number, speed: number, waves1: number, waves2: number) {
    this.radius = radius
    this.phase1 = phase1
    this.phase2 = phase2
    this.amplitude = amplitude
    this.life = life
    this.speed = speed
    this.waves1 = waves1
    this.waves2 = waves2
  }
}

/** 水面动画常量(与安卓 RecordOrbView.Water 一致;px 语义按 vp 落地,即设计基准密度 1)。 */
class Water {
  static readonly BG_TOP: number = LobsterWaterColors.ORB_TOP
  static readonly BG_BOTTOM: number = LobsterWaterColors.ORB_BOTTOM
  static readonly RIM: number = LobsterWaterColors.ORB_RIM
  static readonly RIPPLE_DEEP: number = LobsterWaterColors.ACCENT_DEEP
  static readonly RIPPLE_MID: number = LobsterWaterColors.ACCENT_BRIGHT
  static readonly RIPPLE_LIGHT: number = LobsterWaterColors.ACCENT_SOFT
  static readonly MIC: number = LobsterWaterColors.ACCENT_DEEP
  static readonly MIC_HI: number = LobsterWaterColors.ORB_MIC_HI
  static readonly MAX_WOBBLE_PX: number = 2
  static readonly FLOW_PHASE_STEP: number = 0.022
  static readonly RIPPLE_PHASE_STEP: number = 0.018
  static readonly REF_ORB_RADIUS_PX: number = 29
  /** 帧间隔(ms,对齐安卓 FRAME_INTERVAL_NS = 33.3ms)。 */
  static readonly FRAME_INTERVAL_MS: number = 33
  static readonly LIFE_DECAY_PER_SEC: number = 0.21
  static readonly EXPAND: number = 0.28
  static readonly IDLE_VISUAL_ENERGY: number = 0.16
  static readonly MAX_RIPPLES: number = 3
}

const MODE_IDLE: number = 0
const MODE_RECORDING: number = 1
const MODE_PROCESSING: number = 2

@Component
export struct RecordOrbView {
  @Prop @Watch('onOrbStateChanged') orbRecording: boolean = false
  @Prop @Watch('onOrbStateChanged') orbProcessing: boolean = false
  @Prop orbLoggedIn: boolean = true

  @State pressScale: number = 1

  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)
  private ready: boolean = false
  private timerId: number = -1

  private mode: number = MODE_IDLE
  private smoothedEnergy: number = 0
  private flowPhase: number = 0
  private processingPhase: number = 0
  private lastSpawnMs: number = 0
  private lastProcessingMs: number = 0
  private lastFrameMs: number = 0
  private orbRadius: number = Water.REF_ORB_RADIUS_PX
  private ripples: Ripple[] = []

  /** 状态切换:清空涟漪并重置发射时钟(对齐安卓 setOrbState)。 */
  onOrbStateChanged(propName: string): void {
    const newMode = this.computeMode()
    if (newMode !== this.mode) {
      this.ripples = []
      this.lastSpawnMs = 0
    }
    this.mode = newMode
    if (this.mode === MODE_IDLE) {
      this.smoothedEnergy = 0
    }
  }

  private computeMode(): number {
    if (this.orbProcessing) {
      return MODE_PROCESSING
    }
    if (this.orbRecording) {
      return MODE_RECORDING
    }
    return MODE_IDLE
  }

  aboutToDisappear(): void {
    this.stopAnim()
  }

  private startAnim(): void {
    if (this.timerId !== -1) {
      return
    }
    this.lastSpawnMs = 0
    this.lastFrameMs = 0
    this.timerId = setInterval(() => {
      this.doFrame()
    }, Water.FRAME_INTERVAL_MS)
  }

  private stopAnim(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
    this.ripples = []
    this.lastFrameMs = 0
  }

  private sizeScale(): number {
    const s = this.orbRadius / Water.REF_ORB_RADIUS_PX
    return Math.max(0.9, Math.min(3.2, s))
  }

  /** 与默认态相同的单圈涟漪,不随音量改变波峰/振幅/速度。 */
  private spawnIdleStyleRipple(): void {
    const scale = this.sizeScale()
    const ec = Water.IDLE_VISUAL_ENERGY
    const wobbleCap = Water.MAX_WOBBLE_PX * Math.min(scale, 1.8)
    const wobble = Math.min(wobbleCap, (0.85 + ec * 0.65) * Math.min(scale, 1.35))
    this.ripples.push(new Ripple(
      this.orbRadius * 0.11,
      this.flowPhase,
      this.flowPhase * 0.5,
      wobble,
      1,
      (0.30 + ec * 0.14) * scale,
      3,
      2
    ))
  }

  private doFrame(): void {
    if (!this.ready) {
      return
    }
    const now = Date.now()
    let dt = 1 / 30
    if (this.lastFrameMs !== 0) {
      dt = Math.max(1 / 120, Math.min(0.05, (now - this.lastFrameMs) / 1000))
    }
    this.lastFrameMs = now
    const frameScale = dt * 30

    this.mode = this.computeMode()
    this.flowPhase += Water.FLOW_PHASE_STEP * frameScale
    const energy = Math.max(0, Math.min(1, ImeBus.getInstance().orbLevelRaw))
    if (this.mode === MODE_RECORDING) {
      this.smoothedEnergy += (energy - this.smoothedEnergy) * (0.06 * frameScale)
    } else {
      this.smoothedEnergy = 0
    }

    if (this.mode === MODE_RECORDING) {
      // 发射间隔 1800-2400ms,音量越大越密
      const intervalMs = Math.max(1800, Math.min(2400, 2400 - 500 * this.smoothedEnergy))
      if (this.ripples.length < Water.MAX_RIPPLES &&
        (this.lastSpawnMs === 0 || now - this.lastSpawnMs >= intervalMs)) {
        this.spawnIdleStyleRipple()
        this.lastSpawnMs = now
      }
    } else if (this.mode === MODE_IDLE) {
      if (this.lastSpawnMs === 0 || now - this.lastSpawnMs > 3200) {
        this.spawnIdleStyleRipple()
        this.lastSpawnMs = now
      }
    } else {
      // PROCESSING:三点跑马灯 400ms 轮换 + 850ms 发射
      if (this.lastProcessingMs === 0 || now - this.lastProcessingMs > 400) {
        this.processingPhase = (this.processingPhase + 1) % 3
        this.lastProcessingMs = now
      }
      if (this.lastSpawnMs === 0 || now - this.lastSpawnMs > 850) {
        this.spawnIdleStyleRipple()
        this.lastSpawnMs = now
      }
    }

    // 涟漪扩散与衰亡
    const maxR = this.orbRadius * 0.80
    const alive: Ripple[] = []
    for (let i = 0; i < this.ripples.length; i++) {
      const r = this.ripples[i]
      r.radius += r.speed * Water.EXPAND * frameScale
      r.phase1 += Water.RIPPLE_PHASE_STEP * frameScale
      r.phase2 -= Water.RIPPLE_PHASE_STEP * 0.6 * frameScale
      r.life -= Water.LIFE_DECAY_PER_SEC * dt
      if (r.life > 0 && r.radius < maxR) {
        alive.push(r)
      }
    }
    this.ripples = alive
    this.draw()
  }

  // ================= 绘制(逐行对齐安卓 onDraw)=================

  private draw(): void {
    const ctx = this.ctx
    const w = ctx.width
    const h = ctx.height
    if (w <= 0 || h <= 0) {
      return
    }
    ctx.clearRect(0, 0, w, h)
    this.orbRadius = Math.min(w, h) * 0.46
    const cx = w / 2
    const cy = h / 2
    const r = this.orbRadius
    const pillLeft = cx - r
    const pillTop = cy - r * 0.88
    const pillW = r * 2
    const pillH = r * 0.88 * 2

    this.drawBackground(ctx, pillLeft, pillTop, pillW, pillH)
    this.drawShimmer(ctx, pillLeft, pillTop, pillW, pillH)
    for (let i = 0; i < this.ripples.length; i++) {
      this.drawRipple(ctx, cx, cy, this.ripples[i])
    }
    this.drawMic(ctx, cx, cy)
  }

  private drawBackground(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    const grad = ctx.createLinearGradient(x, y, x, y + h)
    grad.addColorStop(0, cssOf(Water.BG_TOP))
    grad.addColorStop(1, cssOf(Water.BG_BOTTOM))
    ctx.fillStyle = grad
    this.pillPath(ctx, x, y, w, h)
    ctx.fill()
    ctx.strokeStyle = cssOf(Water.RIM)
    ctx.lineWidth = this.mode === MODE_RECORDING ? 1.6 : 1.1
    this.pillPath(ctx, x, y, w, h)
    ctx.stroke()
  }

  /** 胶囊路径(圆角 = 高度一半)。 */
  private pillPath(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    const rr = h / 2
    ctx.beginPath()
    ctx.moveTo(x + rr, y)
    ctx.arcTo(x + w, y, x + w, y + h, rr)
    ctx.arcTo(x + w, y + h, x, y + h, rr)
    ctx.arcTo(x, y + h, x, y, rr)
    ctx.arcTo(x, y, x + w, y, rr)
    ctx.closePath()
  }

  /** 水面微光:横向正弦细线,随 flowPhase 流动。 */
  private drawShimmer(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number): void {
    const lineY = y + h * 0.38
    const amp = 0.55
    const steps = 24
    ctx.beginPath()
    for (let i = 0; i <= steps; i++) {
      const t = i / steps
      const px = x + 6 + t * (w - 12)
      const py = lineY + amp * Math.sin(t * Math.PI * 3.2 + this.flowPhase)
      if (i === 0) {
        ctx.moveTo(px, py)
      } else {
        ctx.lineTo(px, py)
      }
    }
    const alpha = 0.35 + (this.mode === MODE_RECORDING ? 0.08 : 0)
    ctx.strokeStyle = rgbaOf(Water.RIPPLE_LIGHT, alpha)
    ctx.lineWidth = 1
    ctx.stroke()
  }

  /** 不规则涟漪环:三层描边(深/中/浅)叠加,透明度随生命周期衰减。 */
  private drawRipple(ctx: CanvasRenderingContext2D, cx: number, cy: number, ripple: Ripple): void {
    const path = this.irregularRing(cx, cy, ripple.radius, ripple.amplitude * ripple.life,
      ripple.waves1, ripple.waves2, ripple.phase1, ripple.phase2)
    const a = ripple.life * (this.mode === MODE_RECORDING ? 0.68 : 0.5)
    ctx.strokeStyle = rgbaOf(Water.RIPPLE_DEEP, a * 0.35)
    ctx.lineWidth = 1.6
    ctx.stroke(path)
    ctx.strokeStyle = rgbaOf(Water.RIPPLE_MID, a * 0.55)
    ctx.lineWidth = 1
    ctx.stroke(path)
    ctx.strokeStyle = rgbaOf(Water.RIPPLE_LIGHT, a * 0.4)
    ctx.lineWidth = 0.6
    ctx.stroke(path)
  }

  private irregularRing(cx: number, cy: number, radius: number, amp: number,
    waves1: number, waves2: number, phase1: number, phase2: number): Path2D {
    const path = new Path2D()
    const n = 56
    for (let i = 0; i <= n; i++) {
      const t = i / n * Math.PI * 2
      const wobble = amp * Math.sin(waves1 * t + phase1) + amp * 0.15 * Math.sin(waves2 * t + phase2)
      const rr = Math.max(2, radius + wobble)
      const x = cx + Math.cos(t) * rr
      const y = cy + Math.sin(t) * rr
      if (i === 0) {
        path.moveTo(x, y)
      } else {
        path.lineTo(x, y)
      }
    }
    path.closePath()
    return path
  }

  private drawMic(ctx: CanvasRenderingContext2D, cx: number, cy: number): void {
    if (!this.orbLoggedIn) {
      // 未登录:感叹号提示
      ctx.fillStyle = cssOf(Water.MIC)
      ctx.font = '26vp sans-serif'
      ctx.textAlign = 'left'
      ctx.fillText('!', cx - 6, cy + 10)
      return
    }
    if (this.mode === MODE_PROCESSING) {
      // 处理中:三点跑马灯
      const gap = 9
      for (let i = 0; i < 3; i++) {
        const on = i === this.processingPhase
        ctx.fillStyle = cssOf(on ? Water.RIPPLE_DEEP : LobsterWaterColors.ORB_DOT_DIM)
        ctx.beginPath()
        ctx.arc(cx - gap + i * gap, cy, on ? 4.5 : 3.2, 0, Math.PI * 2, false)
        ctx.fill()
      }
      return
    }
    // 麦克风本体(高亮白)
    ctx.fillStyle = cssOf(Water.MIC_HI)
    this.fillRoundRect(ctx, cx - 5.5, cy - 10, 11, 12.5, 5.5)
    if (this.mode === MODE_RECORDING) {
      // 录音中:内芯染深蓝宝石
      ctx.fillStyle = cssOf(LobsterWaterColors.ACCENT_DEEP)
      this.fillRoundRect(ctx, cx - 3.5, cy - 7.5, 7, 7, 1.4)
    }
    ctx.strokeStyle = cssOf(Water.MIC)
    ctx.lineWidth = 2
    ctx.lineCap = 'round'
    ctx.beginPath()
    ctx.moveTo(cx, cy + 2.5)
    ctx.lineTo(cx, cy + 8)
    ctx.moveTo(cx - 6.5, cy + 8)
    ctx.lineTo(cx + 6.5, cy + 8)
    ctx.stroke()
  }

  private fillRoundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number): void {
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

  // ================= 交互 =================

  /**
   * 是否响应点击/触摸(对齐安卓 RecordOrbView.setOrbState 的
   * isEnabled = loggedIn && mode != PROCESSING):未登录或处理中一律不响应,
   * 与安卓禁用态 View 不派发 click/touch 的行为一致(B-5)。
   */
  private interactionEnabled(): boolean {
    return this.orbLoggedIn && !this.orbProcessing
  }

  private handleTouch(event: TouchEvent): void {
    if (!this.interactionEnabled()) {
      return
    }
    if (event.type === TouchType.Down) {
      // 按压:补发一圈涟漪 + 1.07 倍缩放(180ms,对齐安卓 setPressed)
      if (this.ripples.length < Water.MAX_RIPPLES) {
        this.spawnIdleStyleRipple()
      }
      animateTo({ duration: 180 }, () => {
        this.pressScale = 1.07
      })
      ImeBus.getInstance().onOrbTouchDown()
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      animateTo({ duration: 180 }, () => {
        this.pressScale = 1
      })
      ImeBus.getInstance().onOrbTouchUp()
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height('100%')
      .scale({ x: this.pressScale, y: this.pressScale })
      // 未登录 0.48 / 处理中 0.9 / 正常 1(对齐安卓 alpha 语义)
      .opacity(this.orbLoggedIn && this.mode !== MODE_PROCESSING ? 1 :
        (this.mode === MODE_PROCESSING ? 0.9 : 0.48))
      .onReady(() => {
        this.ready = true
        this.mode = this.computeMode()
        this.startAnim()
        this.draw()
      })
      .onTouch((event: TouchEvent) => {
        this.handleTouch(event)
      })
      .onClick(() => {
        // 未登录/处理中点击禁用(对照安卓 RecordOrbView.kt isEnabled 语义,B-5)
        if (!this.interactionEnabled()) {
          return
        }
        ImeBus.getInstance().onOrbTap()
      })
  }
}
