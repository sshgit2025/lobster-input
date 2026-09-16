/**
 * 用户个性化词典:选词调频 + bigram 句子联想。
 * 移植自 Android: keyboard/pinyin/UserDictionary.kt(逐行对齐)。
 * 写入采用 debounce(2s) 批量刷盘,避免高频 I/O(对齐安卓 Handler.postDelayed)。
 *
 * 持久化语义对齐安卓 SharedPreferences(同 key、同序列化格式):
 * 本文件保持纯逻辑(不 import @ohos/@kit),存储通过 [UserDictStorage] 注入,
 * 生产实现见 DictionaryLoader.ets 的 PreferencesUserDictStorage(@kit.ArkData preferences)。
 */

/** 键值存储抽象(对齐安卓 SharedPreferences.getString/putString 语义;apply 为异步落盘)。 */
export interface UserDictStorage {
  /** 读取字符串;不存在返回 null。 */
  getString(key: string): Promise<string | null>;

  /** 写入字符串(异步落盘,对齐 editor.apply)。 */
  putString(key: string, value: string): Promise<void>;
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

/** 内部排序用键值对。 */
class EntryKV {
  readonly key: string;
  readonly count: number;

  constructor(key: string, count: number) {
    this.key = key;
    this.count = count;
  }
}

const KEY_FREQ = 'ime_pinyin_user_freq';
const KEY_BIGRAM = 'ime_pinyin_user_bigram';
const KEY_BLACKLIST = 'ime_pinyin_user_blacklist';
const KEY_PHRASES = 'ime_pinyin_user_phrases';
const MAX_FREQ = 2000;
const MAX_BIGRAM_KEYS = 1500;
const MAX_NEXT = 16;
const MAX_BLACKLIST = 500;
const MAX_PHRASE_KEYS = 500;
const MAX_PHRASE_PER_KEY = 4;
const FLUSH_DELAY_MS = 2000;

export class UserDictionary {

  private freq: Map<string, number> = new Map<string, number>();
  private bigram: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();
  private blacklist: Set<string> = new Set<string>();
  /** 用户自造词:拼音 key → (词 → 选中次数)。digits 由拼音派生,加载时重建。 */
  private phrases: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();
  private phraseDigits: Map<string, string> = new Map<string, string>();
  private storage: UserDictStorage | null;
  private dirtyFreq: boolean = false;
  private dirtyBigram: boolean = false;
  private dirtyBlacklist: boolean = false;
  private dirtyPhrases: boolean = false;
  private flushTimer: number = -1;

  /** storage 传 null 时为纯内存模式(单测用);生产传 PreferencesUserDictStorage。 */
  constructor(storage: UserDictStorage | null = null) {
    this.storage = storage;
  }

  async load(): Promise<void> {
    const s = this.storage;
    if (s === null) {
      return;
    }
    const rawFreq = await s.getString(KEY_FREQ);
    if (rawFreq !== null) {
      for (const entry of rawFreq.split(';')) {
        const i = entry.lastIndexOf(':');
        if (i <= 0) {
          continue;
        }
        const w = entry.substring(0, i);
        const c = toIntOrNull(entry.substring(i + 1));
        if (c === null) {
          continue;
        }
        this.freq.set(w, c);
      }
    }
    const rawBigram = await s.getString(KEY_BIGRAM);
    if (rawBigram !== null) {
      for (const line of rawBigram.split('\n')) {
        const tab = line.indexOf('\t');
        if (tab <= 0) {
          continue;
        }
        const a = line.substring(0, tab);
        const map = new Map<string, number>();
        for (const pair of line.substring(tab + 1).split(' ')) {
          const k = pair.lastIndexOf(':');
          if (k <= 0) {
            continue;
          }
          const c = toIntOrNull(pair.substring(k + 1));
          if (c === null) {
            continue;
          }
          map.set(pair.substring(0, k), c);
        }
        if (map.size > 0) {
          this.bigram.set(a, map);
        }
      }
    }
    const rawBlacklist = await s.getString(KEY_BLACKLIST);
    if (rawBlacklist !== null) {
      for (const w of rawBlacklist.split('\n')) {
        if (w.length > 0) {
          this.blacklist.add(w);
        }
      }
    }
    const rawPhrases = await s.getString(KEY_PHRASES);
    if (rawPhrases !== null) {
      // 行格式:pinyin\tword:count word:count ...
      for (const line of rawPhrases.split('\n')) {
        const tab = line.indexOf('\t');
        if (tab <= 0) {
          continue;
        }
        const py = line.substring(0, tab);
        const map = new Map<string, number>();
        for (const pair of line.substring(tab + 1).split(' ')) {
          const k = pair.lastIndexOf(':');
          if (k <= 0) {
            continue;
          }
          const c = toIntOrNull(pair.substring(k + 1));
          if (c === null) {
            continue;
          }
          map.set(pair.substring(0, k), c);
        }
        if (map.size > 0) {
          this.phrases.set(py, map);
          const d = this.toDigits(py);
          if (d !== null) {
            this.phraseDigits.set(py, d);
          }
        }
      }
    }
  }

  private toDigits(pinyin: string): string | null {
    let sb = '';
    for (const c of pinyin) {
      let d = '';
      if (c === 'a' || c === 'b' || c === 'c') {
        d = '2';
      } else if (c === 'd' || c === 'e' || c === 'f') {
        d = '3';
      } else if (c === 'g' || c === 'h' || c === 'i') {
        d = '4';
      } else if (c === 'j' || c === 'k' || c === 'l') {
        d = '5';
      } else if (c === 'm' || c === 'n' || c === 'o') {
        d = '6';
      } else if (c === 'p' || c === 'q' || c === 'r' || c === 's') {
        d = '7';
      } else if (c === 't' || c === 'u' || c === 'v') {
        d = '8';
      } else if (c === 'w' || c === 'x' || c === 'y' || c === 'z') {
        d = '9';
      } else {
        return null;
      }
      sb += d;
    }
    return sb;
  }

  /** 学习自造词(引擎已做音节/长度护栏)。 */
  learnPhrase(pinyin: string, digits: string, word: string): void {
    let map = this.phrases.get(pinyin);
    if (map === undefined) {
      map = new Map<string, number>();
      this.phrases.set(pinyin, map);
    }
    map.set(word, (map.get(word) ?? 0) + 1);
    this.phraseDigits.set(pinyin, digits);
    this.blacklist.delete(word);
    if (map.size > MAX_PHRASE_PER_KEY) {
      const entries: EntryKV[] = [];
      map.forEach((c: number, w: string) => {
        entries.push(new EntryKV(w, c));
      });
      entries.sort((a: EntryKV, b: EntryKV) => b.count - a.count);
      map.clear();
      for (let i = 0; i < entries.length && i < MAX_PHRASE_PER_KEY; i++) {
        map.set(entries[i].key, entries[i].count);
      }
    }
    if (this.phrases.size > MAX_PHRASE_KEYS) {
      // 淘汰总次数最小的拼音 key(不淘汰刚学的)
      let minKey = '';
      let minSum = 0;
      let hasMin = false;
      this.phrases.forEach((m: Map<string, number>, py: string) => {
        let sum = 0;
        m.forEach((c: number) => {
          sum += c;
        });
        if (!hasMin || sum < minSum) {
          hasMin = true;
          minKey = py;
          minSum = sum;
        }
      });
      if (hasMin && minKey !== pinyin) {
        this.phrases.delete(minKey);
        this.phraseDigits.delete(minKey);
      }
    }
    this.dirtyPhrases = true;
    this.scheduleFlush();
  }

  /** 遍历全部自造词:(拼音, 数字码, 词, 次数)。候选生成用。 */
  eachPhrase(action: (pinyin: string, digits: string, word: string, count: number) => void): void {
    const pys = Array.from(this.phrases.keys());
    for (const py of pys) {
      const map = this.phrases.get(py);
      if (map === undefined) {
        continue;
      }
      const d = this.phraseDigits.get(py);
      if (d === undefined) {
        continue;
      }
      const words = Array.from(map.keys());
      for (const w of words) {
        const c = map.get(w);
        if (c === undefined) {
          continue;
        }
        action(py, d, w, c);
      }
    }
  }

  phrasesView(): Map<string, Map<string, number>> {
    return this.phrases;
  }

  phraseDigitsView(): Map<string, string> {
    return this.phraseDigits;
  }

  bonus(word: string): number {
    return this.freq.get(word) ?? 0;
  }

  isBlacklisted(word: string): boolean {
    return this.blacklist.has(word);
  }

  /** 长按删词:加入黑名单(候选不再出现)+ 清掉已学调频/联想/自造词。 */
  forget(word: string): void {
    if (word.length === 0) {
      return;
    }
    this.blacklist.add(word);
    if (this.blacklist.size > MAX_BLACKLIST) {
      // 对齐 Kotlin iterator().remove():删除最早插入的一个
      const firstArr = Array.from(this.blacklist.values());
      if (firstArr.length > 0) {
        this.blacklist.delete(firstArr[0]);
      }
    }
    this.freq.delete(word);
    this.bigram.delete(word);
    this.bigram.forEach((m: Map<string, number>) => {
      m.delete(word);
    });
    this.phrases.forEach((m: Map<string, number>) => {
      m.delete(word);
    });
    // 对齐 Kotlin phrases.entries.removeAll { it.value.isEmpty() }(注意:安卓侧不清 phraseDigits,保持一致)
    const emptyKeys: string[] = [];
    this.phrases.forEach((m: Map<string, number>, py: string) => {
      if (m.size === 0) {
        emptyKeys.push(py);
      }
    });
    for (const k of emptyKeys) {
      this.phrases.delete(k);
    }
    this.dirtyFreq = true;
    this.dirtyBigram = true;
    this.dirtyBlacklist = true;
    this.dirtyPhrases = true;
    this.scheduleFlush();
  }

  learn(word: string): void {
    if (word.length === 0) {
      return;
    }
    this.freq.set(word, (this.freq.get(word) ?? 0) + 1);
    if (this.freq.size > MAX_FREQ) {
      const entries: EntryKV[] = [];
      this.freq.forEach((c: number, w: string) => {
        entries.push(new EntryKV(w, c));
      });
      entries.sort((a: EntryKV, b: EntryKV) => b.count - a.count);
      const keepN = Math.floor(MAX_FREQ * 3 / 4);
      this.freq.clear();
      for (let i = 0; i < entries.length && i < keepN; i++) {
        this.freq.set(entries[i].key, entries[i].count);
      }
    }
    this.scheduleFlush(true, false);
  }

  learnPair(a: string, b: string): void {
    if (a.length === 0 || b.length === 0 || a === b) {
      return;
    }
    let map = this.bigram.get(a);
    if (map === undefined) {
      map = new Map<string, number>();
      this.bigram.set(a, map);
    }
    map.set(b, (map.get(b) ?? 0) + 1);
    if (map.size > MAX_NEXT) {
      const entries: EntryKV[] = [];
      map.forEach((c: number, w: string) => {
        entries.push(new EntryKV(w, c));
      });
      entries.sort((x: EntryKV, y: EntryKV) => y.count - x.count);
      map.clear();
      for (let i = 0; i < entries.length && i < MAX_NEXT; i++) {
        map.set(entries[i].key, entries[i].count);
      }
    }
    if (this.bigram.size > MAX_BIGRAM_KEYS) {
      let minKey = '';
      let minSum = 0;
      let hasMin = false;
      this.bigram.forEach((m: Map<string, number>, k: string) => {
        let sum = 0;
        m.forEach((c: number) => {
          sum += c;
        });
        if (!hasMin || sum < minSum) {
          hasMin = true;
          minKey = k;
          minSum = sum;
        }
      });
      if (hasMin && minKey !== a) {
        this.bigram.delete(minKey);
      }
    }
    this.scheduleFlush(false, true);
  }

  nextWords(a: string): string[] {
    const map = this.bigram.get(a);
    if (map === undefined) {
      return [];
    }
    const entries: EntryKV[] = [];
    map.forEach((c: number, w: string) => {
      entries.push(new EntryKV(w, c));
    });
    entries.sort((x: EntryKV, y: EntryKV) => y.count - x.count);
    const out: string[] = [];
    for (const e of entries) {
      out.push(e.key);
    }
    return out;
  }

  /** 词对共现次数(整句 DP 的 bigram 转移加成用)。 */
  pairCount(a: string, b: string): number {
    const map = this.bigram.get(a);
    if (map === undefined) {
      return 0;
    }
    return map.get(b) ?? 0;
  }

  private scheduleFlush(freq: boolean = false, bigram: boolean = false): void {
    if (freq) {
      this.dirtyFreq = true;
    }
    if (bigram) {
      this.dirtyBigram = true;
    }
    if (this.flushTimer >= 0) {
      clearTimeout(this.flushTimer);
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flushNow();
    }, FLUSH_DELAY_MS);
  }

  private flushNow(): void {
    const s = this.storage;
    if (s === null) {
      // 纯内存模式:仅复位脏标记
      this.dirtyFreq = false;
      this.dirtyBigram = false;
      this.dirtyBlacklist = false;
      this.dirtyPhrases = false;
      return;
    }
    if (this.dirtyFreq) {
      let sb = '';
      const words = Array.from(this.freq.keys());
      for (const w of words) {
        if (w.includes(';') || w.includes(':')) {
          continue;
        }
        const c = this.freq.get(w);
        if (c === undefined) {
          continue;
        }
        if (sb.length > 0) {
          sb += ';';
        }
        sb += w + ':' + c;
      }
      this.dirtyFreq = false;
      s.putString(KEY_FREQ, sb).catch(() => {
      });
    }
    if (this.dirtyBigram) {
      let sb = '';
      const keys = Array.from(this.bigram.keys());
      for (const a of keys) {
        if (a.includes('\t') || a.includes(' ') || a.includes(':')) {
          continue;
        }
        const map = this.bigram.get(a);
        if (map === undefined) {
          continue;
        }
        if (sb.length > 0) {
          sb += '\n';
        }
        sb += a + '\t';
        let first = true;
        const bs = Array.from(map.keys());
        for (const b of bs) {
          if (b.includes(' ') || b.includes(':')) {
            continue;
          }
          const c = map.get(b);
          if (c === undefined) {
            continue;
          }
          if (!first) {
            sb += ' ';
          }
          sb += b + ':' + c;
          first = false;
        }
      }
      this.dirtyBigram = false;
      s.putString(KEY_BIGRAM, sb).catch(() => {
      });
    }
    if (this.dirtyBlacklist) {
      const kept: string[] = [];
      const words = Array.from(this.blacklist.values());
      for (const w of words) {
        if (!w.includes('\n')) {
          kept.push(w);
        }
      }
      this.dirtyBlacklist = false;
      s.putString(KEY_BLACKLIST, kept.join('\n')).catch(() => {
      });
    }
    if (this.dirtyPhrases) {
      let sb = '';
      const pys = Array.from(this.phrases.keys());
      for (const py of pys) {
        if (py.includes('\t') || py.includes(' ') || py.includes('\n')) {
          continue;
        }
        const map = this.phrases.get(py);
        if (map === undefined) {
          continue;
        }
        if (sb.length > 0) {
          sb += '\n';
        }
        sb += py + '\t';
        let first = true;
        const words = Array.from(map.keys());
        for (const w of words) {
          if (w.includes(' ') || w.includes(':')) {
            continue;
          }
          const c = map.get(w);
          if (c === undefined) {
            continue;
          }
          if (!first) {
            sb += ' ';
          }
          sb += w + ':' + c;
          first = false;
        }
      }
      this.dirtyPhrases = false;
      s.putString(KEY_PHRASES, sb).catch(() => {
      });
    }
  }
}
