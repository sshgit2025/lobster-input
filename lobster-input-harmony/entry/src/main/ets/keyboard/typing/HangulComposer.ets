// 对齐 Android: keyboard/typing/HangulComposer.kt(含最近修复的「孤元音吞辅音」bug,以当前源码为准)

/**
 * Hangul 2-set(두벌식)组字自动机(与 scratch-keyboard-verify/hangul_composer.py 参照实现逐行对齐)。
 * Unicode:音节 = 0xAC00 + (cho*21 + jung)*28 + jong。
 * 复合中声(ㅗ+ㅏ=ㅘ)、复合终声(ㄹ+ㄱ=ㄺ)、终声借调(닭+이=달기→닭이)、逐 jamo 退格拆解。
 * (Kotlin Char → ArkTS 单字符 string;Pair 键 → 两字符拼接字符串键。)
 */
export class HangulComposer {
  private cho?: string;
  private jung?: string;
  private jong?: string;

  isEmpty(): boolean {
    return this.cho === undefined && this.jung === undefined && this.jong === undefined;
  }

  /** 当前组合中显示的字符(未定稿,恒 ≤1 字符)。 */
  current(): string {
    const c = this.cho;
    const j = this.jung;
    if (c !== undefined && j !== undefined) {
      const ci = HangulComposer.CHO.indexOf(c);
      const ji = HangulComposer.JUNG.indexOf(j);
      const gi = this.jong !== undefined ? HangulComposer.JONG.indexOf(this.jong) : 0;
      return String.fromCharCode(0xAC00 + (ci * 21 + ji) * 28 + gi);
    }
    if (c !== undefined) return c;
    if (j !== undefined) return j;
    return '';
  }

  reset(): void {
    this.cho = undefined;
    this.jung = undefined;
    this.jong = undefined;
  }

  /** 输入一个 compatibility jamo(单字符),返回需定稿上屏的文本(可空串)。 */
  feed(jamo: string): string {
    return HangulComposer.VOWELS.has(jamo) ? this.feedVowel(jamo) : this.feedConsonant(jamo);
  }

  private feedConsonant(c: string): string {
    if (this.cho === undefined && this.jung === undefined) {
      this.cho = c;
      return '';
    }
    if (this.jung === undefined) {
      // 只有 cho:辅音+辅音 → 前一个定稿,新辅音开始(双辅音走 shift,不自动合并)
      const out = this.cho ?? '';
      this.reset();
      this.cho = c;
      return out;
    }
    if (this.jong === undefined) {
      // 【修 孤元音丢辅音】终声必须挂在完整 cho+jung 音节上;孤元音(cho=null)挂终声后
      // current() 渲染不出、辅音被静默吞掉(ㅏ+ㄱ 曾丢 ㄱ)。标准行为:孤元音定稿,辅音另起。
      if (this.cho !== undefined && HangulComposer.JONG_SET.has(c)) {
        this.jong = c;
        return '';
      }
      // 孤元音 / ㄸㅃㅉ 不能作终声:定稿当前,新起
      const out = this.current();
      this.reset();
      this.cho = c;
      return out;
    }
    const comb = HangulComposer.JONG_COMBINE.get(this.jong + c);
    if (comb !== undefined) {
      this.jong = comb;
      return '';
    }
    const out = this.current();
    this.reset();
    this.cho = c;
    return out;
  }

  private feedVowel(v: string): string {
    const g = this.jong;
    if (g !== undefined) {
      // 终声借调:复合终声拆最后一个辅音做新 cho,单终声整个移走
      const split = HangulComposer.JONG_SPLIT.get(g);
      if (split !== undefined) {
        this.jong = split.charAt(0);
        const out = this.current();
        this.reset();
        this.cho = split.charAt(1);
        this.jung = v;
        return out;
      }
      this.jong = undefined;
      const out = this.current();
      this.reset();
      this.cho = g;
      this.jung = v;
      return out;
    }
    const j = this.jung;
    if (j !== undefined) {
      const comb = HangulComposer.JUNG_COMBINE.get(j + v);
      if (comb !== undefined) {
        this.jung = comb;
        return '';
      }
      const out = this.current();
      this.reset();
      this.jung = v;
      return out;
    }
    this.jung = v;
    return '';
  }

  /** 组合态内逐 jamo 拆解;返回 false 表示无组合态(需删文档字符)。 */
  backspace(): boolean {
    const g = this.jong;
    if (g !== undefined) {
      const split = HangulComposer.JONG_SPLIT.get(g);
      this.jong = split !== undefined ? split.charAt(0) : undefined;
      return true;
    }
    const j = this.jung;
    if (j !== undefined) {
      const split = HangulComposer.JUNG_SPLIT.get(j);
      this.jung = split !== undefined ? split.charAt(0) : undefined;
      return true;
    }
    if (this.cho !== undefined) {
      this.cho = undefined;
      return true;
    }
    return false;
  }

  private static readonly CHO: string = 'ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ';
  private static readonly JUNG: string = 'ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ';
  // JONG[0] 为占位(无终声);indexOf 用于 Unicode 组装
  private static readonly JONG: string = ' ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ';

  private static buildJongSet(): Set<string> {
    const s = new Set<string>();
    for (let i = 1; i < HangulComposer.JONG.length; i++) s.add(HangulComposer.JONG.charAt(i));
    return s;
  }

  private static buildVowels(): Set<string> {
    const s = new Set<string>();
    for (let i = 0; i < HangulComposer.JUNG.length; i++) s.add(HangulComposer.JUNG.charAt(i));
    return s;
  }

  private static buildJungCombine(): Map<string, string> {
    const m = new Map<string, string>();
    m.set('ㅗㅏ', 'ㅘ');
    m.set('ㅗㅐ', 'ㅙ');
    m.set('ㅗㅣ', 'ㅚ');
    m.set('ㅜㅓ', 'ㅝ');
    m.set('ㅜㅔ', 'ㅞ');
    m.set('ㅜㅣ', 'ㅟ');
    m.set('ㅡㅣ', 'ㅢ');
    return m;
  }

  private static buildJongCombine(): Map<string, string> {
    const m = new Map<string, string>();
    m.set('ㄱㅅ', 'ㄳ');
    m.set('ㄴㅈ', 'ㄵ');
    m.set('ㄴㅎ', 'ㄶ');
    m.set('ㄹㄱ', 'ㄺ');
    m.set('ㄹㅁ', 'ㄻ');
    m.set('ㄹㅂ', 'ㄼ');
    m.set('ㄹㅅ', 'ㄽ');
    m.set('ㄹㅌ', 'ㄾ');
    m.set('ㄹㅍ', 'ㄿ');
    m.set('ㄹㅎ', 'ㅀ');
    m.set('ㅂㅅ', 'ㅄ');
    return m;
  }

  /** 复合 jamo → 两字符拆解串(charAt(0)=first,charAt(1)=second)。 */
  private static buildSplit(combine: Map<string, string>): Map<string, string> {
    const m = new Map<string, string>();
    combine.forEach((value: string, key: string) => {
      m.set(value, key);
    });
    return m;
  }

  private static readonly JONG_SET: Set<string> = HangulComposer.buildJongSet();
  private static readonly VOWELS: Set<string> = HangulComposer.buildVowels();
  private static readonly JUNG_COMBINE: Map<string, string> = HangulComposer.buildJungCombine();
  private static readonly JONG_COMBINE: Map<string, string> = HangulComposer.buildJongCombine();
  private static readonly JUNG_SPLIT: Map<string, string> = HangulComposer.buildSplit(HangulComposer.JUNG_COMBINE);
  private static readonly JONG_SPLIT: Map<string, string> = HangulComposer.buildSplit(HangulComposer.JONG_COMBINE);
}
