/**
 * 产品内置自定义扩展词库(custom_dict v2,61 万词)。数据访问层,与 [PinyinDictionary] 同构。
 * 镜像 Android: keyboard/pinyin/CustomDictionary.kt(逐行对齐)。
 *  - 文件与主词库同格式:`拼音连写key\t词1 lv1 词2 lv2 ...`(key 升序、key 内 lv 降序),
 *    由 tools/keyboard-verify/gen_custom_dict.py 生成,**与主词库零重复**、词频等级同量纲。
 *  - 存储用**字节表**(Uint8Array 字节 + Int32Array 行偏移索引 + 字节二分,镜像 iOS ByteTable/
 *    Android byte[]):59 万 key 若用 String 并行数组会撑爆热堆且拖垮 GC,单 buffer 对 GC 友好;
 *    词条文本不预解码,命中行才把小片段解码成 String。
 *  - T9 数字码索引:行号按 key 的数字码字典序排列(Int32Array 排列,数字码查询时由 key 字节
 *    即时换算比较,不存储 59 万数字码串)。
 *
 * 纯逻辑层:不 import 任何 @ohos/@kit 模块。原始字节由 DictionaryLoader 以
 * resourceManager.getRawFileContent 读入 Uint8Array 后经 [load] 注入(IO 隔离架构);
 * 解析/建索引分块 setTimeout 让出事件循环(镜像 PinyinDictionary 的分块模式,
 * 替代安卓的后台线程加载)。
 *
 * 加载约定:数据在生成期已保证「全 CJK 2-8 字、拼音可完整切分合法音节、可映射数字码」,
 * 运行时**不做**贪心 allValidSyllables 校验(贪心会误杀 zuoleyinianduo 这类回溯才可切的合法键),
 * 只跳过注释/坏行。由 PinyinEngine 在主词库 READY 后**异步挂载**,挂载前查询按空表返回。
 */
import { WordLevel, PrefixHit, T9Hit, T9PrefixHit } from './PinyinDictionary';

/** 对齐 Kotlin companion object 字节常量。 */
const NL = 10;   // '\n'
const TAB = 9;   // '\t'
const SP = 32;   // ' '
const HASH = 35; // '#'

/** 对齐 Kotlin Int.MAX_VALUE(wordsAt 默认不限量)。 */
const INT_MAX = 2147483647;

/** 分块解析让出事件循环(镜像 PinyinDictionary.yieldLoop,对齐安卓后台线程加载不阻塞 UI)。 */
function yieldLoop(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}

/**
 * 纯逻辑 UTF-8 解码(命中行的小片段才调用;算法层不 import util.TextDecoder)。
 * 数据生成期已保证合法 UTF-8,越界/坏序列不做防御(与 Kotlin String(bytes,...) 语义一致)。
 */
function utf8Decode(bytes: Uint8Array, start: number, end: number): string {
  let out = '';
  let i = start;
  while (i < end) {
    const b0 = bytes[i];
    if (b0 < 0x80) {
      out += String.fromCharCode(b0);
      i += 1;
    } else if (b0 < 0xE0) {
      out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
      i += 2;
    } else if (b0 < 0xF0) {
      out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
      i += 3;
    } else {
      // 4 字节序列 → 代理对(𰻞 等扩展区汉字)
      const cp = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
      const v = cp - 0x10000;
      out += String.fromCharCode(0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF));
      i += 4;
    }
  }
  return out;
}

export class CustomDictionary {

  private isReadyFlag: boolean = false;

  get isReady(): boolean {
    return this.isReadyFlag;
  }

  private bytes: Uint8Array = new Uint8Array(0);
  private lineStart: Int32Array = new Int32Array(0);
  private keyLen: Int32Array = new Int32Array(0);
  private lineEnd: Int32Array = new Int32Array(0);
  /** 行号排列:按 key 的 T9 数字码字典序(同码内按行号即 key 序,稳定)。 */
  private t9Order: Int32Array = new Int32Array(0);

  private maxDigitLenValue: number = 0;

  /** 自定义词最长数字码(T9 词层循环上限,biang=14 位不受 MAX_T9_WORD_DIGITS 截断)。 */
  get maxDigitLen(): number {
    return this.maxDigitLenValue;
  }

  /** 字母 charCode → 数字 charCode('2'~'9'),0=不可映射。对齐 Kotlin letter2digit ByteArray(128)。 */
  private letter2digit: Int32Array = CustomDictionary.buildLetter2Digit();

  private static buildLetter2Digit(): Int32Array {
    const t = new Int32Array(128);
    const groups: string[] = ['abc', 'def', 'ghi', 'jkl', 'mno', 'pqrs', 'tuv', 'wxyz'];
    for (let gi = 0; gi < groups.length; gi++) {
      const digitCode = 50 + gi; // '2'.charCodeAt(0) === 50
      for (const c of groups[gi]) {
        t[c.charCodeAt(0)] = digitCode;
      }
    }
    return t;
  }

  /** 解析注入的词库字节并建 T9 索引(镜像 Kotlin load(context);分块让出事件循环)。 */
  async load(data: Uint8Array): Promise<void> {
    const starts: number[] = [];
    const klens: number[] = [];
    const ends: number[] = [];
    let i = 0;
    const n = data.length;
    let lineNo = 0;
    while (i < n) {
      const start = i;
      let tab = -1;
      let j = i;
      while (j < n && data[j] !== NL) {
        if (data[j] === TAB && tab < 0) {
          tab = j;
        }
        j++;
      }
      // 跳过注释行与无 TAB 的坏行(数据生成期已保证合法,这里只防御格式损坏)
      if (tab > start && data[start] !== HASH) {
        starts.push(start);
        klens.push(tab - start);
        ends.push(j);
      }
      i = j + 1;
      lineNo++;
      if ((lineNo & 0x3FFF) === 0x3FFF) {
        await yieldLoop();
      }
    }
    this.bytes = data;
    this.lineStart = Int32Array.from(starts);
    this.keyLen = Int32Array.from(klens);
    this.lineEnd = Int32Array.from(ends);
    await this.buildT9Order();
    this.isReadyFlag = true;
  }

  /** 数字码排列:临时物化数字码串排序(异步挂载阶段,峰值内存随后 GC),常驻仅 Int32Array。 */
  private async buildT9Order(): Promise<void> {
    const count = this.lineStart.length;
    const digitKeys: (string | null)[] = new Array<string | null>(count).fill(null);
    let maxLen = 0;
    for (let idx = 0; idx < count; idx++) {
      const s = this.lineStart[idx];
      const kl = this.keyLen[idx];
      let sb = '';
      let valid = true;
      for (let k = 0; k < kl; k++) {
        const b = this.bytes[s + k];
        const d = b < 128 ? this.letter2digit[b] : 0;
        if (d === 0) {
          valid = false;
          break;
        }
        sb += String.fromCharCode(d);
      }
      if (!valid) {
        continue;
      }
      digitKeys[idx] = sb;
      if (kl > maxLen) {
        maxLen = kl;
      }
      if ((idx & 0x3FFF) === 0x3FFF) {
        await yieldLoop();
      }
    }
    this.maxDigitLenValue = maxLen;
    const order: number[] = [];
    for (let idx = 0; idx < count; idx++) {
      if (digitKeys[idx] !== null) {
        order.push(idx);
      }
    }
    // 一次性 sort(在异步挂载阶段,允许):数字码字典序,同码按行号(即 key 序)稳定,对齐 Kotlin sortedBy
    order.sort((a: number, b: number) => {
      const da = digitKeys[a] as string;
      const db = digitKeys[b] as string;
      if (da < db) {
        return -1;
      }
      if (da > db) {
        return 1;
      }
      return a - b;
    });
    this.t9Order = Int32Array.from(order);
  }

  // ===== 拼音键查询(字节二分,镜像 Kotlin/iOS ByteTable) =====

  /** 查询串 → 字节码数组(key 均为 ASCII 拼音字母,charCode 即字节值)。 */
  private encodeQuery(s: string): number[] {
    const out: number[] = [];
    for (let k = 0; k < s.length; k++) {
      out.push(s.charCodeAt(k));
    }
    return out;
  }

  private compareKeyAt(index: number, q: number[]): number {
    const s = this.lineStart[index];
    const len = this.keyLen[index];
    const m = Math.min(len, q.length);
    for (let k = 0; k < m; k++) {
      const a = this.bytes[s + k];
      const b = q[k];
      if (a !== b) {
        return a < b ? -1 : 1;
      }
    }
    return len < q.length ? -1 : (len > q.length ? 1 : 0);
  }

  private lowerBound(q: number[]): number {
    let lo = 0;
    let hi = this.lineStart.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (this.compareKeyAt(mid, q) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  private keyStartsWith(index: number, q: number[]): boolean {
    if (this.keyLen[index] < q.length) {
      return false;
    }
    const s = this.lineStart[index];
    for (let k = 0; k < q.length; k++) {
      if (this.bytes[s + k] !== q[k]) {
        return false;
      }
    }
    return true;
  }

  private keyAt(index: number): string {
    return utf8Decode(this.bytes, this.lineStart[index], this.lineStart[index] + this.keyLen[index]);
  }

  /** 解析行内候选:`词1 lv1 词2 lv2 ...`(与主词库 SortedTable.wordsAt 同语义)。 */
  private wordsAt(index: number, limit: number = INT_MAX): WordLevel[] {
    const out: WordLevel[] = [];
    let p = this.lineStart[index] + this.keyLen[index] + 1;
    const end = this.lineEnd[index];
    while (p < end && out.length < limit) {
      let q = p;
      while (q < end && this.bytes[q] !== SP) {
        q++;
      }
      if (q >= end) {
        break;
      }
      const word = utf8Decode(this.bytes, p, q);
      let r = q + 1;
      let lv = 0;
      let any = false;
      while (r < end && this.bytes[r] !== SP) {
        const c = this.bytes[r] - 48; // '0'
        if (c >= 0 && c <= 9) {
          lv = lv * 10 + c;
          any = true;
        }
        r++;
      }
      if (word.length > 0 && any) {
        out.push(new WordLevel(word, lv));
      }
      p = r + 1;
    }
    return out;
  }

  /** 整键精确查词(与主词库 exactWords 同语义)。 */
  exactWords(key: string): WordLevel[] {
    if (!this.isReadyFlag || key.length === 0) {
      return [];
    }
    const q = this.encodeQuery(key);
    const i = this.lowerBound(q);
    if (i >= this.lineStart.length || this.compareKeyAt(i, q) !== 0) {
      return [];
    }
    return this.wordsAt(i);
  }

  bestWord(key: string): WordLevel | null {
    if (!this.isReadyFlag || key.length === 0) {
      return null;
    }
    const q = this.encodeQuery(key);
    const i = this.lowerBound(q);
    if (i >= this.lineStart.length || this.compareKeyAt(i, q) !== 0) {
      return null;
    }
    const ws = this.wordsAt(i, 1);
    return ws.length > 0 ? ws[0] : null;
  }

  /** 前缀补全:每个更长同前缀 key 取首选词,返回 (词, 等级, key长)(与主词库 prefixWords 同语义)。 */
  prefixWords(prefix: string, limit: number): PrefixHit[] {
    if (!this.isReadyFlag || prefix.length === 0) {
      return [];
    }
    const q = this.encodeQuery(prefix);
    const out: PrefixHit[] = [];
    let i = this.lowerBound(q);
    while (i < this.lineStart.length && out.length < limit) {
      if (!this.keyStartsWith(i, q)) {
        break;
      }
      if (this.keyLen[i] !== q.length) {
        const ws = this.wordsAt(i, 1);
        if (ws.length > 0) {
          out.push(new PrefixHit(ws[0].word, ws[0].level, this.keyLen[i]));
        }
      }
      i++;
    }
    return out;
  }

  // ===== T9 数字码查询(排列二分,数字码由 key 字节即时换算) =====

  /** key(行 index)的数字码 与 查询数字码 逐位比较;prefixOnly 时 key 更长视为相等(前缀命中)。 */
  private compareDigitsAt(index: number, digits: string, prefixOnly: boolean): number {
    const s = this.lineStart[index];
    const len = this.keyLen[index];
    const m = Math.min(len, digits.length);
    for (let k = 0; k < m; k++) {
      const b = this.bytes[s + k];
      const d = b < 128 ? this.letter2digit[b] : 0;
      const q = digits.charCodeAt(k);
      if (d !== q) {
        return d < q ? -1 : 1;
      }
    }
    if (prefixOnly && len >= digits.length) {
      return 0;
    }
    return len < digits.length ? -1 : (len > digits.length ? 1 : 0);
  }

  private t9LowerBound(digits: string): number {
    let lo = 0;
    let hi = this.t9Order.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (this.compareDigitsAt(this.t9Order[mid], digits, false) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /** 数字码精确查词:跨同码拼音合并,返回 (词, 等级, 拼音key)(与主词库 t9ExactWords 同语义)。 */
  t9ExactWords(digits: string): T9Hit[] {
    if (!this.isReadyFlag || digits.length === 0) {
      return [];
    }
    const out: T9Hit[] = [];
    let i = this.t9LowerBound(digits);
    while (i < this.t9Order.length) {
      const ref = this.t9Order[i];
      if (this.compareDigitsAt(ref, digits, false) !== 0) {
        break;
      }
      const key = this.keyAt(ref);
      for (const e of this.wordsAt(ref)) {
        out.push(new T9Hit(e.word, e.level, key));
      }
      i++;
    }
    return out;
  }

  /** 数字码前缀补全:每个更长同前缀码取首选词(与主词库 t9PrefixWords 同语义)。 */
  t9PrefixWords(digits: string, limit: number): T9PrefixHit[] {
    if (!this.isReadyFlag || digits.length === 0) {
      return [];
    }
    const out: T9PrefixHit[] = [];
    let i = this.t9LowerBound(digits);
    while (i < this.t9Order.length && out.length < limit) {
      const ref = this.t9Order[i];
      if (this.compareDigitsAt(ref, digits, true) !== 0) {
        break;
      }
      if (this.keyLen[ref] !== digits.length) {
        const ws = this.wordsAt(ref, 1);
        if (ws.length > 0) {
          out.push(new T9PrefixHit(ws[0].word, ws[0].level, this.keyLen[ref], this.keyAt(ref)));
        }
      }
      i++;
    }
    return out;
  }
}
