/**
 * 与 Mac / Windows / iOS 桌面端一致的滚动音浪采样。
 * (移植自 core/audio/AudioWaveformEngine.kt,纯逻辑逐行复刻)
 */
export class AudioWaveformEngine {
  private readonly barCount: number;
  readonly levels: number[];

  constructor(barCount: number = 10, initialLevel: number = 0.08) {
    this.barCount = Math.max(1, barCount);
    this.levels = [];
    for (let i = 0; i < this.barCount; i++) {
      this.levels.push(initialLevel);
    }
  }

  reset(initialLevel: number = 0.08): void {
    for (let i = 0; i < this.levels.length; i++) {
      this.levels[i] = initialLevel;
    }
  }

  push(inputLevel: number): void {
    const input = Math.min(1, Math.max(0, inputLevel));
    const idle = Math.random() * 0.12 + 0.08;
    const reactive = input * (Math.random() * 0.23 + 0.72);
    this.shift(Math.max(0.05, Math.min(1, Math.max(idle, reactive))));
  }

  private shift(value: number): void {
    if (this.levels.length === 0) {
      return;
    }
    this.levels.shift();
    this.levels.push(value);
  }

  nextProcessingPhase(phase: number): number {
    return (phase + 1) % this.barCount;
  }
}
