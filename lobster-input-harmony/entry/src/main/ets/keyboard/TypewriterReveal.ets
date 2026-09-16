/**
 * 实时识别"打字机"平滑层。(移植自 keyboard/TypewriterReveal.kt)
 *
 * 上游(火山 Seed-ASR)在实时输入下吐字是突发的:前沿大约每 ~390ms 跳 ~2 个字,并伴随
 * 偶发 ~1 秒停顿。直接整段替换显示就会"一顿一顿"。本组件把突发到达的 partial 目标文本,
 * 转换成稳定逐字揭示的连续流,改善"边说边出字"的流畅观感。
 *
 * 安全原则(必须遵守,勿破坏业务):
 *  - 只影响"预览显示",绝不参与最终提交;最终权威文本仍由调用方在 finished 后整段提交。
 *  - setTarget 每次都用"最新 target 的前缀"重绘,因此火山对已显示区域的"纠正 / 整句替换"
 *    会在下一 tick(≤TICK_MS)立即反映到屏幕,不会丢字、不会显示过期文本。
 *  - flush 立即把显示补齐到最新 target(停止 / 收尾时调用),保证被锁定 / 提交的是完整文本。
 *  - 揭示速率随积压自适应:积压越多揭示越快(数百毫秒内追平最新 partial),不给"边说边识别"添加可感知延迟。
 *
 * 安卓版依赖主线程 Handler;ArkTS 单线程事件循环下直接用 setTimeout,语义等价。
 */
export class TypewriterReveal {
  private target: string = '';
  private revealed: number = 0;
  private running: boolean = false;
  private lastRevealAt: number = 0;
  private timerId: number = -1;
  private readonly render: (shown: string) => void;

  private static readonly TICK_MS: number = 30;
  // 积压字数阈值与对应的逐字间隔(毫秒):积压越大越快,平滑吸收上游停顿。
  private static readonly FAST_BACKLOG: number = 8;
  private static readonly MID_BACKLOG: number = 4;
  private static readonly FAST_MS: number = 22;
  private static readonly MID_MS: number = 55;
  private static readonly SLOW_MS: number = 120;

  constructor(render: (shown: string) => void) {
    this.render = render;
  }

  /** 设置最新目标文本(来自 partial / completed)。已显示区域内的纠正会立即生效。 */
  setTarget(text: string): void {
    this.target = text;
    this.clampRevealedToBoundary();
    // 仅在已揭示>0 时重绘已揭示前缀(反映纠正 / 整句替换);
    // revealed==0 时不渲染空串,避免触发 clearRealtimePreview→reset 把刚设的 target 自毁。
    if (this.revealed > 0) {
      this.render(this.currentPrefix());
    }
    if (this.revealed < this.target.length && !this.running) {
      this.running = true;
      this.lastRevealAt = Date.now();
      this.scheduleTick();
    }
  }

  /** 立即补齐到最新目标并停止动画(停止 / 收尾时调用)。 */
  flush(): void {
    this.running = false;
    this.cancelTick();
    this.revealed = this.target.length;
    this.render(this.target);
  }

  /** 清空状态并停止动画(会话结束 / 清理时调用,显示清理由调用方负责)。 */
  reset(): void {
    this.running = false;
    this.cancelTick();
    this.target = '';
    this.revealed = 0;
    this.lastRevealAt = 0;
  }

  /** 等价安卓 tick Runnable */
  private onTick(): void {
    if (!this.running) {
      return;
    }
    this.stepReveal();
    if (this.revealed >= this.target.length) {
      this.running = false;
      return;
    }
    this.scheduleTick();
  }

  private scheduleTick(): void {
    this.timerId = setTimeout(() => this.onTick(), TypewriterReveal.TICK_MS);
  }

  private cancelTick(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }

  private stepReveal(): void {
    if (this.revealed >= this.target.length) {
      return;
    }
    const now = Date.now();
    let changed = false;
    while (this.revealed < this.target.length) {
      const backlog = this.target.length - this.revealed;
      let interval = TypewriterReveal.SLOW_MS;
      if (backlog >= TypewriterReveal.FAST_BACKLOG) {
        interval = TypewriterReveal.FAST_MS;
      } else if (backlog >= TypewriterReveal.MID_BACKLOG) {
        interval = TypewriterReveal.MID_MS;
      }
      if (now - this.lastRevealAt < interval) {
        break;
      }
      this.advanceOneGrapheme();
      this.lastRevealAt += interval;
      changed = true;
    }
    if (changed) {
      this.render(this.currentPrefix());
    }
  }

  /** 前进一个"字":正确跨过 UTF-16 代理对(emoji 等),不切断字符。 */
  private advanceOneGrapheme(): void {
    this.revealed++;
    if (this.revealed < this.target.length &&
      TypewriterReveal.isHighSurrogate(this.target.charCodeAt(this.revealed - 1)) &&
      TypewriterReveal.isLowSurrogate(this.target.charCodeAt(this.revealed))) {
      this.revealed++;
    }
  }

  /** 目标变更后,确保 revealed 不落在代理对中间。 */
  private clampRevealedToBoundary(): void {
    if (this.revealed > this.target.length) {
      this.revealed = this.target.length;
    }
    if (this.revealed >= 1 && this.revealed < this.target.length &&
      TypewriterReveal.isLowSurrogate(this.target.charCodeAt(this.revealed))) {
      this.revealed--;
    }
  }

  private currentPrefix(): string {
    if (this.revealed <= 0) {
      return '';
    }
    if (this.revealed >= this.target.length) {
      return this.target;
    }
    return this.target.substring(0, this.revealed);
  }

  private static isHighSurrogate(code: number): boolean {
    return code >= 0xD800 && code <= 0xDBFF;
  }

  private static isLowSurrogate(code: number): boolean {
    return code >= 0xDC00 && code <= 0xDFFF;
  }
}
