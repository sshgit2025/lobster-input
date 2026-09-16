// 对齐 Android: keyboard/typing/InputStrategy.kt
import { Candidate, PinyinEngine } from '../pinyin/PinyinEngine';
import { HangulComposer } from './HangulComposer';

/** Kotlin StringBuilder 的轻量等价物(composing 共享可变缓冲)。 */
export class StringBuilder {
  private buf: string = '';

  get length(): number {
    return this.buf.length;
  }

  isEmpty(): boolean {
    return this.buf.length === 0;
  }

  isNotEmpty(): boolean {
    return this.buf.length > 0;
  }

  append(s: string): void {
    this.buf += s;
  }

  /** 截断到指定长度(Kotlin setLength 语义,只用于截短/清空)。 */
  setLength(n: number): void {
    if (n <= 0) {
      this.buf = '';
    } else if (n < this.buf.length) {
      this.buf = this.buf.substring(0, n);
    }
  }

  substring(start: number, end?: number): string {
    return end === undefined ? this.buf.substring(start) : this.buf.substring(start, end);
  }

  toString(): string {
    return this.buf;
  }
}

/**
 * 输入策略(策略模式)。把"按字母键如何变成文本/候选"的差异封装到各策略中,
 * 让 KeyboardController 无需对中/英 × 26/9 做散落的 if/else。
 * (ArkTS 接口无默认实现 → reset/onDelete/flush 各策略显式实现。)
 */
export interface InputStrategy {
  /** 字母键:26 键传字母,9 宫格传数字字符串,韩语传 jamo。 */
  onAlpha(value: string): void;
  /** 基于当前组合串产出候选(英文/俄语/韩语策略返回空)。 */
  candidates(): Candidate[];
  /** 候选栏组合显示(英文/俄语/韩语策略返回空串)。 */
  composingDisplay(): string;
  /** 切换到本策略时复位内部状态。 */
  reset(): void;
  /** 删除键:返回 true 表示已在策略内部消化(韩语组字逐 jamo 拆解),false 走默认删除。 */
  onDelete(): boolean;
  /** 输入中断点(空格/回车/标点/切页/切语言):定稿策略内部组合态(韩语当前音节)。 */
  flush(): void;
}

/** 策略运行上下文(由 Controller 实现),供策略读写组合串、上屏、刷新。 */
export interface StrategyContext {
  readonly composing: StringBuilder;
  readonly engine: PinyinEngine;
  readonly shiftActive: boolean;

  commit(text: string): void;

  deleteBeforeCursor(): void;

  refreshCandidates(): void;

  consumeShift(): void;

  /** 组合预览写入目标框(韩语组字音节,setComposing 通道;拼音不走此通道)。 */
  composingText(text: string): void;

  /** 定稿目标框中的组合预览(finishComposing)。 */
  finishComposing(): void;
}

/** 中文 · 26 键全拼。 */
export class ChineseQwertyStrategy implements InputStrategy {
  private readonly ctx: StrategyContext;

  constructor(ctx: StrategyContext) {
    this.ctx = ctx;
  }

  onAlpha(value: string): void {
    this.ctx.composing.append(value.toLowerCase());
    this.ctx.refreshCandidates();
  }

  candidates(): Candidate[] {
    return this.ctx.engine.candidates(this.ctx.composing.toString());
  }

  composingDisplay(): string {
    return this.ctx.composing.isEmpty() ? '' : this.ctx.engine.displaySegmented(this.ctx.composing.toString());
  }

  reset(): void {}

  onDelete(): boolean {
    return false;
  }

  flush(): void {}
}

/** 中文 · 9 宫格 T9。候选从最优拼音切分生成(与显示拼音一一对应)。 */
export class ChineseT9Strategy implements InputStrategy {
  private readonly ctx: StrategyContext;

  constructor(ctx: StrategyContext) {
    this.ctx = ctx;
  }

  onAlpha(value: string): void {
    this.ctx.composing.append(value);
    this.ctx.refreshCandidates();
  }

  candidates(): Candidate[] {
    return this.ctx.engine.candidatesForT9(this.ctx.composing.toString());
  }

  composingDisplay(): string {
    return '';
  }

  reset(): void {}

  onDelete(): boolean {
    return false;
  }

  flush(): void {}
}

/** 英文 · 26 键直接上屏。 */
export class EnglishQwertyStrategy implements InputStrategy {
  private readonly ctx: StrategyContext;

  constructor(ctx: StrategyContext) {
    this.ctx = ctx;
  }

  onAlpha(value: string): void {
    const out = this.ctx.shiftActive ? value.toUpperCase() : value.toLowerCase();
    this.ctx.commit(out);
    this.ctx.consumeShift();
  }

  candidates(): Candidate[] {
    return [];
  }

  composingDisplay(): string {
    return '';
  }

  reset(): void {}

  onDelete(): boolean {
    return false;
  }

  flush(): void {}
}

/** 俄语 · ЙЦУКЕН 直接上屏(西里尔字母大小写随 shift;ё 由 е 长按提供,布局层配置)。 */
export class RussianStrategy implements InputStrategy {
  private readonly ctx: StrategyContext;

  constructor(ctx: StrategyContext) {
    this.ctx = ctx;
  }

  onAlpha(value: string): void {
    const out = this.ctx.shiftActive ? value.toUpperCase() : value.toLowerCase();
    this.ctx.commit(out);
    this.ctx.consumeShift();
  }

  candidates(): Candidate[] {
    return [];
  }

  composingDisplay(): string {
    return '';
  }

  reset(): void {}

  onDelete(): boolean {
    return false;
  }

  flush(): void {}
}

/**
 * 韩语 · 2-set(두벌식)组字上屏。jamo 经 HangulComposer 组字:
 * 定稿部分 commit,组合中音节走 setComposing 预览(业界标准,光标下带下划线);
 * 删除键优先在组合内逐 jamo 拆解;空格/回车/标点/切页先 flush 定稿。
 */
export class KoreanStrategy implements InputStrategy {
  private readonly ctx: StrategyContext;
  private readonly composer: HangulComposer = new HangulComposer();

  constructor(ctx: StrategyContext) {
    this.ctx = ctx;
  }

  onAlpha(value: string): void {
    if (value.length === 0) return;
    const jamo = value.charAt(0);
    const committed = this.composer.feed(jamo);
    // commitText 会替换当前组合预览区并定稿(标准 IC 语义),无需先 finishComposing
    if (committed.length > 0) this.ctx.commit(committed);
    this.syncPreview();
    this.ctx.consumeShift();
  }

  onDelete(): boolean {
    if (this.composer.isEmpty()) return false;
    this.composer.backspace();
    this.syncPreview();
    return true;
  }

  flush(): void {
    if (this.composer.isEmpty()) return;
    // 组合预览已显示当前音节,finishComposing 直接把它定稿进文档
    this.composer.reset();
    this.ctx.finishComposing();
  }

  reset(): void {
    this.composer.reset();
  }

  candidates(): Candidate[] {
    return [];
  }

  composingDisplay(): string {
    return '';
  }

  private syncPreview(): void {
    const cur = this.composer.current();
    if (cur.length === 0) {
      this.ctx.composingText('');
      this.ctx.finishComposing();
    } else {
      this.ctx.composingText(cur);
    }
  }
}

// 英文 T9 多击策略已废弃:英文一律 26 键(对齐搜狗/Gboard,九宫格中文切英文直接变 26 键英文)。
