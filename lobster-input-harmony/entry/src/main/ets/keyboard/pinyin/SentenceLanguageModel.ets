/**
 * 整句语言模型(2026-07,九宫格智能整句核心):词级 bigram(主)+ 字级 bigram OOV veto(兜底)。
 *
 * 修"打对拼音却出弱智句"(因为你搬过来→因为你包裹来):原整句 DP 只按词频打分,无上下文语言模型。
 * 给整句 DP 的**跨词边界**打分:词 bigram 命中→中心化 delta(奖励好搭配),未命中→字级 OOV veto(仅罚)。
 * 参数与 tools/keyboard-verify/engine_lm.py、Android SentenceLanguageModel.kt 逐一对齐(回归 13/13 验证)。
 *
 * IO 隔离:文本经 DictionaryLoader.readRawTextFile 注入(算法层不触 @kit)。词/字 bigram 各 ~5.8K/35K key,
 * 解析成 Map<string, Map<string, number>>(权重 number),内存可接受;挂载在 READY 后异步不阻塞冷启动。
 */
export class SentenceLanguageModel {
  private wordBi: Map<string, Map<string, number>> = new Map();
  private charBi: Map<string, Map<string, number>> = new Map();
  private ready: boolean = false;

  isReady(): boolean {
    return this.ready;
  }

  /** 注入 char_bigram.txt / word_bigram.txt 文本(DictionaryLoader 读入)。 */
  load(charText: string, wordText: string): void {
    this.charBi = SentenceLanguageModel.parse(charText);
    this.wordBi = SentenceLanguageModel.parse(wordText);
    this.ready = this.charBi.size > 0 || this.wordBi.size > 0;
  }

  private static parse(text: string): Map<string, Map<string, number>> {
    const map = new Map<string, Map<string, number>>();
    if (!text) {
      return map;
    }
    const lines = text.split('\n');
    for (let li = 0; li < lines.length; li++) {
      const line = lines[li];
      const tab = line.indexOf('\t');
      if (tab <= 0) {
        continue;
      }
      const k1 = line.substring(0, tab);
      const toks = line.substring(tab + 1).split(' ');
      const inner = new Map<string, number>();
      let i = 0;
      while (i + 1 < toks.length) {
        const k2 = toks[i];
        const w = parseInt(toks[i + 1], 10);
        if (k2.length > 0 && !isNaN(w)) {
          inner.set(k2, w);
        }
        i += 2;
      }
      if (inner.size > 0) {
        map.set(k1, inner);
      }
    }
    return map;
  }

  /** 跨词边界打分:词 bigram 命中→中心化 delta;未命中→字级 OOV veto。整句 DP 每次词转移调用一次。 */
  boundaryScore(pw: string, w: string): number {
    if (!this.ready || pw.length === 0 || w.length === 0) {
      return 0;
    }
    const wd = this.wordDelta(pw, w);
    if (wd !== null) {
      return wd;
    }
    return this.charVeto(pw.charAt(pw.length - 1), w.charAt(0));
  }

  private wordDelta(pw: string, w: string): number | null {
    const d = this.wordBi.get(pw);
    if (d === undefined) {
      return null;
    }
    const b = d.get(w);
    if (b === undefined) {
      return null;
    }
    const x = Math.trunc((b - SentenceLanguageModel.WREF) * SentenceLanguageModel.WBETA);
    if (x > SentenceLanguageModel.WHI) {
      return SentenceLanguageModel.WHI;
    }
    if (x < -SentenceLanguageModel.WLO) {
      return -SentenceLanguageModel.WLO;
    }
    return x;
  }

  private charVeto(prevLast: string, curFirst: string): number {
    const d = this.charBi.get(prevLast);
    if (d === undefined) {
      return -SentenceLanguageModel.LM_LO;
    }
    const wv = d.get(curFirst);
    if (wv === undefined) {
      return -SentenceLanguageModel.LM_LO;
    }
    const x = Math.trunc((wv - SentenceLanguageModel.LM_REF) * SentenceLanguageModel.LM_BETA);
    if (x >= 0) {
      return 0;
    }
    return x > -SentenceLanguageModel.LM_LO ? x : -SentenceLanguageModel.LM_LO;
  }

  // 与 tools/keyboard-verify/engine_lm.py 逐一对齐(勿单独改,须同步 Python 参照并重跑回归)
  private static readonly WREF: number = -700;
  private static readonly WBETA: number = 0.13;
  private static readonly WHI: number = 55;
  private static readonly WLO: number = 40;
  private static readonly LM_REF: number = -520;
  private static readonly LM_BETA: number = 0.16;
  private static readonly LM_LO: number = 70;
}
