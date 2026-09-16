/**
 * 拼音词库(数据访问层)。词库来源:成熟开源 rime-ice(雾凇拼音)。
 * 移植自 Android: keyboard/pinyin/PinyinDictionary.kt(逐行对齐)。
 *
 * 纯逻辑层:不 import 任何 @ohos/@kit 模块。词库文本经 [PinyinDictSource] 由外部(DictionaryLoader)喂入;
 * 解析大文件时分块 setTimeout 让出事件循环(替代安卓的后台线程加载)。
 *
 * 含两张按 key 排序的表(二分查找,内存友好):
 *  - full     全拼连写 → 候选(pinyin_dict.txt)
 *  - initials 首字母简拼 → 候选(initials_dict.txt),支持业界标准简拼(cs→测试、nh→你好)
 * 另含合法音节集合(音节切分、9 宫格还原)。
 */

/** 词库文本来源(IO 注入点,由 DictionaryLoader 实现;对齐安卓 context.assets.open)。 */
export interface PinyinDictSource {
  /** 读取 rawfile/dict/<name> 的完整 UTF-8 文本。 */
  readRawTextFile(name: string): Promise<string>;

  /**
   * 读取 rawfile/dict/<name> 的原始字节(不解码)。custom_dict v2 字节表专用:
   * 16.7MB 词库直接以 Uint8Array 注入 CustomDictionary,避免整文件 String 化撑爆热堆
   * (镜像 Android context.assets.open(name).readBytes())。
   */
  readRawFileBytes(name: string): Promise<Uint8Array>;
}

/** (词, 词频等级)。对齐 Kotlin Pair<String, Int>。 */
export class WordLevel {
  readonly word: string;
  readonly level: number;

  constructor(word: string, level: number) {
    this.word = word;
    this.level = level;
  }
}

/** 前缀补全命中:(词, 等级, key 长度)。对齐 Kotlin Triple<String, Int, Int>。 */
export class PrefixHit {
  readonly word: string;
  readonly level: number;
  readonly keyLen: number;

  constructor(word: string, level: number, keyLen: number) {
    this.word = word;
    this.level = level;
    this.keyLen = keyLen;
  }
}

/** T9 数字码精确命中:(词, 等级, 拼音key)。对齐 Kotlin Triple<String, Int, String>。 */
export class T9Hit {
  readonly word: string;
  readonly level: number;
  readonly pinyinKey: string;

  constructor(word: string, level: number, pinyinKey: string) {
    this.word = word;
    this.level = level;
    this.pinyinKey = pinyinKey;
  }
}

/** T9 数字码前缀补全命中。对齐 Kotlin data class T9PrefixHit。 */
export class T9PrefixHit {
  readonly word: string;
  readonly level: number;
  readonly keyDigitLen: number;
  readonly pinyinKey: string;

  constructor(word: string, level: number, keyDigitLen: number, pinyinKey: string) {
    this.word = word;
    this.level = level;
    this.keyDigitLen = keyDigitLen;
    this.pinyinKey = pinyinKey;
  }
}

/** T9 索引构建中间行:(数字码, full 表行号)。 */
class T9Row {
  readonly digits: string;
  readonly ref: number;

  constructor(digits: string, ref: number) {
    this.digits = digits;
    this.ref = ref;
  }
}

/** 分块解析让出事件循环(对齐安卓后台线程加载不阻塞 UI 的语义)。 */
function yieldLoop(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}

/** Kotlin String.toIntOrNull 等价:可选 +/- 前缀 + 纯十进制数字,否则 null。 */
function toIntOrNull(s: string): number | null {
  if (s.length === 0) {
    return null;
  }
  let i = 0;
  const first = s.charAt(0);
  if (first === '+' || first === '-') {
    if (s.length === 1) {
      return null;
    }
    i = 1;
  }
  for (; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 48 || c > 57) {
      return null;
    }
  }
  return parseInt(s, 10);
}

/** 一张按 key 升序排列的词表:并行数组 + 二分。对齐 Kotlin 内部类 SortedTable。 */
class SortedTable {
  keys: string[] = [];
  vals: string[] = [];

  /** 解析词库文本(行格式 key\tvalue)。分块让出事件循环,避免长时间阻塞。 */
  async load(text: string): Promise<void> {
    const ks: string[] = [];
    const vs: string[] = [];
    const lines = text.split('\n');
    for (let li = 0; li < lines.length; li++) {
      let line = lines[li];
      // 兼容 CRLF(安卓 BufferedReader.readLine 会剥掉 \r)
      if (line.length > 0 && line.charAt(line.length - 1) === '\r') {
        line = line.substring(0, line.length - 1);
      }
      const tab = line.indexOf('\t');
      if (tab <= 0) {
        continue;
      }
      ks.push(line.substring(0, tab));
      vs.push(line.substring(tab + 1));
      if ((li & 0x3FFF) === 0x3FFF) {
        await yieldLoop();
      }
    }
    this.keys = ks;
    this.vals = vs;
  }

  get size(): number {
    return this.keys.length;
  }

  indexOfKey(key: string): number {
    let lo = 0;
    let hi = this.keys.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >>> 1;
      const mk = this.keys[mid];
      if (mk < key) {
        lo = mid + 1;
      } else if (mk > key) {
        hi = mid - 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  lowerBound(key: string): number {
    let lo = 0;
    let hi = this.keys.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (this.keys[mid] < key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  wordsAt(index: number): WordLevel[] {
    const parts = this.vals[index].split(' ');
    const out: WordLevel[] = [];
    let i = 0;
    while (i + 1 < parts.length) {
      const w = parts[i];
      const lv = toIntOrNull(parts[i + 1]) ?? 0;
      if (w.length > 0) {
        out.push(new WordLevel(w, lv));
      }
      i += 2;
    }
    return out;
  }

  exact(key: string): WordLevel[] {
    const idx = this.indexOfKey(key);
    return idx < 0 ? [] : this.wordsAt(idx);
  }

  hasPrefix(prefix: string): boolean {
    const lb = this.lowerBound(prefix);
    return lb < this.keys.length && this.keys[lb].startsWith(prefix);
  }

  /** 前缀匹配:收集以 prefix 开头(长度大于 prefix)的 key 的首选词。 */
  prefix(prefix: string, limit: number): PrefixHit[] {
    const out: PrefixHit[] = [];
    let pi = this.lowerBound(prefix);
    while (pi < this.keys.length && out.length < limit) {
      const k = this.keys[pi];
      if (!k.startsWith(prefix)) {
        break;
      }
      if (k.length !== prefix.length) {
        const words = this.wordsAt(pi);
        if (words.length > 0) {
          out.push(new PrefixHit(words[0].word, words[0].level, k.length));
        }
      }
      pi++;
    }
    return out;
  }
}

export class PinyinDictionary {

  private isReadyFlag: boolean = false;

  get isReady(): boolean {
    return this.isReadyFlag;
  }

  private full: SortedTable = new SortedTable();
  private initials: SortedTable = new SortedTable();

  private syllables: Set<string> = new Set<string>();
  private syllablePrefixes: Set<string> = new Set<string>();
  private maxSyllableLenValue: number = 6;

  get maxSyllableLen(): number {
    return this.maxSyllableLenValue;
  }

  // ---- 字读音表(切分歧义的权威裁决数据) ----
  // 由词典单字条目构建:key 为合法音节的行,其单字词都记为该字的读音(华→hua、纳→na)。
  // 用于把候选词拼音按字对齐切分(华纳+huana→hua|na),取代贪心最长匹配(huan|a)。
  private charReadings: Map<string, string[]> = new Map<string, string[]>();

  // ---- T9 数字码索引(业界标准:词库按数字码直查,根治 DFS 展开截断丢词) ----
  // full 表每个拼音 key 预转数字码后排序;同码不同拼音的行都会命中(shangban/qiangban 同码)。
  private t9Keys: string[] = [];
  private t9Refs: number[] = [];

  async load(source: PinyinDictSource): Promise<void> {
    this.isReadyFlag = false;
    const fullText = await source.readRawTextFile('pinyin_dict.txt');
    await this.full.load(fullText);
    if (this.full.size === 0) {
      return;
    }
    const initialsText = await source.readRawTextFile('initials_dict.txt');
    await this.initials.load(initialsText);
    const syllablesText = await source.readRawTextFile('syllables.txt');
    this.loadSyllables(syllablesText);
    await this.buildT9Index();
    this.buildCharReadings();
    this.isReadyFlag = true;
  }

  readingsOf(c: string): string[] {
    return this.charReadings.get(c) ?? [];
  }

  private buildCharReadings(): void {
    for (let idx = 0; idx < this.full.keys.length; idx++) {
      const key = this.full.keys[idx];
      if (!this.syllables.has(key)) {
        continue;
      }
      for (const e of this.full.wordsAt(idx)) {
        if (e.word.length === 1) {
          const ch = e.word.charAt(0);
          let list = this.charReadings.get(ch);
          if (list === undefined) {
            list = [];
            this.charReadings.set(ch, list);
          }
          if (!list.includes(key)) {
            list.push(key);
          }
        }
      }
    }
    // 长读音在前:对齐 DFS 先试长音节,减少回溯
    this.charReadings.forEach((list: string[]) => {
      list.sort((a: string, b: string) => b.length - a.length);
    });
  }

  private loadSyllables(text: string): void {
    const lines = text.split('\n');
    for (const raw of lines) {
      const s = raw.trim();
      if (s.length === 0) {
        continue;
      }
      this.syllables.add(s);
      for (let i = 1; i <= s.length; i++) {
        this.syllablePrefixes.add(s.substring(0, i));
      }
      if (s.length > this.maxSyllableLenValue) {
        this.maxSyllableLenValue = s.length;
      }
    }
  }

  isSyllable(s: string): boolean {
    return this.syllables.has(s);
  }

  isSyllablePrefix(s: string): boolean {
    return this.syllablePrefixes.has(s);
  }

  /** 返回 input 从 pos 起的最长合法音节长度,无则 0(候选兜底用,纯查表)。 */
  longestSyllableAt(input: string, pos: number): number {
    const maxLen = Math.min(this.maxSyllableLenValue, input.length - pos);
    for (let len = maxLen; len >= 1; len--) {
      if (this.syllables.has(input.substring(pos, pos + len))) {
        return len;
      }
    }
    return 0;
  }

  // ---- 全拼 ----
  exactWords(key: string): WordLevel[] {
    return this.full.exact(key);
  }

  prefixWords(prefix: string, limit: number): PrefixHit[] {
    return this.full.prefix(prefix, limit);
  }

  bestWord(key: string): WordLevel | null {
    const words = this.full.exact(key);
    return words.length > 0 ? words[0] : null;
  }

  private async buildT9Index(): Promise<void> {
    const letter2digit = new Map<string, string>();
    const groups: string[] = ['abc', 'def', 'ghi', 'jkl', 'mno', 'pqrs', 'tuv', 'wxyz'];
    const digitsOfGroup: string[] = ['2', '3', '4', '5', '6', '7', '8', '9'];
    for (let gi = 0; gi < groups.length; gi++) {
      for (const c of groups[gi]) {
        letter2digit.set(c, digitsOfGroup[gi]);
      }
    }
    const rows: T9Row[] = [];
    for (let idx = 0; idx < this.full.keys.length; idx++) {
      const key = this.full.keys[idx];
      let sb = '';
      let bad = false;
      for (const c of key) {
        const d = letter2digit.get(c);
        if (d === undefined) {
          // 对齐 Kotlin continue@outer:key 含不可映射字符则整行跳过
          bad = true;
          break;
        }
        sb += d;
      }
      if (bad) {
        continue;
      }
      rows.push(new T9Row(sb, idx));
      if ((idx & 0x3FFF) === 0x3FFF) {
        await yieldLoop();
      }
    }
    rows.sort((a: T9Row, b: T9Row) => {
      if (a.digits < b.digits) {
        return -1;
      }
      if (a.digits > b.digits) {
        return 1;
      }
      return 0;
    });
    const tk: string[] = [];
    const tr: number[] = [];
    for (const r of rows) {
      tk.push(r.digits);
      tr.push(r.ref);
    }
    this.t9Keys = tk;
    this.t9Refs = tr;
  }

  private t9LowerBound(key: string): number {
    let lo = 0;
    let hi = this.t9Keys.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (this.t9Keys[mid] < key) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /** 数字码精确查词:跨同码拼音合并,返回 (词, 等级, 拼音key)。 */
  t9ExactWords(digits: string): T9Hit[] {
    if (digits.length === 0) {
      return [];
    }
    const out: T9Hit[] = [];
    let i = this.t9LowerBound(digits);
    while (i < this.t9Keys.length && this.t9Keys[i] === digits) {
      const ref = this.t9Refs[i];
      const key = this.full.keys[ref];
      for (const e of this.full.wordsAt(ref)) {
        out.push(new T9Hit(e.word, e.level, key));
      }
      i++;
    }
    return out;
  }

  /** 数字码前缀补全:每个更长同前缀码取首选词,返回 (词, 等级, 码长, 拼音key)。 */
  t9PrefixWords(digits: string, limit: number): T9PrefixHit[] {
    if (digits.length === 0) {
      return [];
    }
    const out: T9PrefixHit[] = [];
    let i = this.t9LowerBound(digits);
    while (i < this.t9Keys.length && out.length < limit) {
      const dk = this.t9Keys[i];
      if (!dk.startsWith(digits)) {
        break;
      }
      if (dk.length !== digits.length) {
        const ref = this.t9Refs[i];
        const words = this.full.wordsAt(ref);
        if (words.length > 0) {
          out.push(new T9PrefixHit(words[0].word, words[0].level, dk.length, this.full.keys[ref]));
        }
      }
      i++;
    }
    return out;
  }

  // ---- 简拼 ----
  initialsExact(key: string): WordLevel[] {
    return this.initials.exact(key);
  }

  initialsPrefix(prefix: string, limit: number): PrefixHit[] {
    return this.initials.prefix(prefix, limit);
  }

  initialsHasPrefix(prefix: string): boolean {
    return this.initials.hasPrefix(prefix);
  }

  // ---- 音节切分 ----
  splitSyllables(input: string): string[] {
    const out: string[] = [];
    let pos = 0;
    const n = input.length;
    while (pos < n) {
      if (input.charAt(pos) === '\'') {
        pos++;
        continue;
      }
      let matched = -1;
      const maxLen = Math.min(this.maxSyllableLenValue, n - pos);
      for (let len = maxLen; len >= 1; len--) {
        if (this.syllables.has(input.substring(pos, pos + len))) {
          matched = len;
          break;
        }
      }
      if (matched > 0) {
        out.push(input.substring(pos, pos + matched));
        pos += matched;
      } else {
        out.push(input.substring(pos));
        break;
      }
    }
    return out;
  }

  displaySegmented(input: string): string {
    return this.splitSyllables(input).join('\'');
  }
}
