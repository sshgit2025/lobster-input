/**
 * 拼音引擎(算法层)。组合 [PinyinDictionary] 与 [UserDictionary]。
 * 移植自 Android: keyboard/pinyin/PinyinEngine.kt(1005 行,逐行对齐:切分/匹配/评分/候选生成/调频)。
 *
 * 纯逻辑层:不 import 任何 @ohos/@kit 模块。
 *  - 词库 IO 经 [PinyinDictSource] 注入(生产实现 DictionaryLoader.ets);
 *  - 用户词典持久化经 UserDictionary 的 UserDictStorage 注入;
 *  - 安卓 Handler/Looper 回主线程 → 鸿蒙侧本就运行在主事件循环,监听器直接回调;
 *  - 安卓后台线程加载 → async/await + 词库解析分块让出事件循环。
 * 加载完成后通过 [PinyinLoadListener] 通知 UI。
 */
import { PinyinDictionary, PinyinDictSource, PrefixHit, T9Hit } from './PinyinDictionary';
import { CustomDictionary } from './CustomDictionary';
import { SentenceLanguageModel } from './SentenceLanguageModel';
import { UserDictionary } from './UserDictionary';
import { PinyinFuzzy, PinyinFuzzySettings } from './PinyinFuzzy';
import { BuiltinPrediction } from './BuiltinPrediction';
import { PinyinLoadState, PinyinLoadListener } from './PinyinLoadState';

/**
 * 一个拼音候选词。matchedLen = 该候选消耗的输入字符数。isEmoji:emoji 联想候选(选中不写词典)。
 * isSymbol:9 宫格 1 键的高频符号候选(选中按智能配对上屏,不写词典、不改联想链)。
 * isPunct:候选栏标点联想(2026-07-23),选中直接上屏(不配对)、不学习、不改联想链;
 * 与 isSymbol 严格隔离——不参与候选栏两侧收起契约、不触发 SmartPunctuation 配对。
 */
export class Candidate {
  readonly word: string;
  readonly matchedLen: number;
  readonly score: number;
  readonly isEmoji: boolean;
  readonly pinyin: string;
  readonly isSymbol: boolean;
  readonly isPunct: boolean;

  constructor(word: string, matchedLen: number, score: number, isEmoji: boolean = false, pinyin: string = '',
    isSymbol: boolean = false, isPunct: boolean = false) {
    this.word = word;
    this.matchedLen = matchedLen;
    this.score = score;
    this.isEmoji = isEmoji;
    this.pinyin = pinyin;
    this.isSymbol = isSymbol;
    this.isPunct = isPunct;
  }
}

/** 对齐 Kotlin Int.MIN_VALUE(DP 不可达哨兵)。 */
const INT_MIN = -2147483648;

/** 整句 DP 状态:score + 前驱位置 + 前驱词 + 本词拼音 key(拼音回溯用)。对齐 Kotlin SentSt。 */
class SentSt {
  readonly score: number;
  readonly from: number;
  readonly prevWord: string;
  readonly key: string;

  constructor(score: number, from: number, prevWord: string, key: string) {
    this.score = score;
    this.from = from;
    this.prevWord = prevWord;
    this.key = key;
  }
}

/** sentenceT9 结果:(句子, 覆盖位数, 拼音key串)。对齐 Kotlin Triple<String, Int, String>。 */
class SentenceHit {
  readonly whole: string;
  readonly covered: number;
  readonly pinyinKey: string;

  constructor(whole: string, covered: number, pinyinKey: string) {
    this.whole = whole;
    this.covered = covered;
    this.pinyinKey = pinyinKey;
  }
}

/** T9 补全候选中间体:(调整分, 词, 拼音key)。对齐 Kotlin Triple<Int, String, String>。 */
class CompHit {
  readonly adj: number;
  readonly word: string;
  readonly key: string;

  constructor(adj: number, word: string, key: string) {
    this.adj = adj;
    this.word = word;
    this.key = key;
  }
}

/** t9LeadingOptions 整段音节:(音节, 首词频级)。对齐 Kotlin Pair<String, Int>。 */
class SylLv {
  readonly syl: string;
  readonly lv: number;

  constructor(syl: string, lv: number) {
    this.syl = syl;
    this.lv = lv;
  }
}

/** t9LeadingOptions 短前导音节:(音节, 段长, 首词频级)。对齐 Kotlin Triple<String, Int, Int>。 */
class SylLenLv {
  readonly syl: string;
  readonly len: number;
  readonly lv: number;

  constructor(syl: string, len: number, lv: number) {
    this.syl = syl;
    this.len = len;
    this.lv = lv;
  }
}

/** bestT9SegPartial 结果:(音节列表, 已完整切分的最长前缀长度)。对齐 Kotlin Pair<List<String>, Int>。 */
class T9SegResult {
  readonly segs: string[];
  readonly covered: number;

  constructor(segs: string[], covered: number) {
    this.segs = segs;
    this.covered = covered;
  }
}

/** Map 条目排序中间体(Kotlin entries.sortedByDescending 等价)。 */
class CandEntry {
  readonly k: string;
  readonly st: SentSt;

  constructor(k: string, st: SentSt) {
    this.k = k;
    this.st = st;
  }
}

/** topT9Words 中间体:(词频级, 拼音key)。对齐 Kotlin Pair<Int, String>。 */
class LvKey {
  readonly lv: number;
  readonly key: string;

  constructor(lv: number, key: string) {
    this.lv = lv;
    this.key = key;
  }
}

export class PinyinEngine {

  private dict: PinyinDictionary = new PinyinDictionary();
  // 海量内置自定义词库(custom_dict v2,61 万词;镜像 Android PinyinEngine.kt customDict)
  private customDict: CustomDictionary = new CustomDictionary();
  private sentenceLm: SentenceLanguageModel = new SentenceLanguageModel();
  private userDict: UserDictionary;
  private fuzzy: PinyinFuzzySettings = new PinyinFuzzySettings();
  private loading: boolean = false;
  private loadStateValue: PinyinLoadState = PinyinLoadState.IDLE;
  private listeners: PinyinLoadListener[] = [];

  private t9: Map<string, string> = PinyinEngine.buildT9Map();
  private letter2digit: Map<string, string> = PinyinEngine.buildLetter2Digit();

  // ===== 切分歧义根治(修 huanameduoqian 被当成 huan|a|me...) =====
  // 业界标准:候选词拼音按"字→读音表"对齐切分(权威),不再用贪心最长/音节频率猜。
  private alignCache: Map<string, string[] | null> = new Map<string, string[] | null>();

  // 小缓存:同一(数字串,锁定栈)的显示与候选复用同一次计算,避免重复;学习后整体失效。
  private t9CacheKey: string | null = null;
  private t9CacheVal: Candidate[] = [];

  // 段内 top-K 词(记忆化,带拼音 key 供整句回溯)
  private topWordsCache: Map<string, T9Hit[]> = new Map<string, T9Hit[]>();

  // expandFullPinyin 记忆化:短音节段跨按键/段内高频重复,缓存后长句整句/切分/候选单步<1ms。
  private expandCache: Map<string, string[]> = new Map<string, string[]>();

  private static buildT9Map(): Map<string, string> {
    const m = new Map<string, string>();
    m.set('2', 'abc');
    m.set('3', 'def');
    m.set('4', 'ghi');
    m.set('5', 'jkl');
    m.set('6', 'mno');
    m.set('7', 'pqrs');
    m.set('8', 'tuv');
    m.set('9', 'wxyz');
    return m;
  }

  private static buildLetter2Digit(): Map<string, string> {
    const m = new Map<string, string>();
    const t9 = PinyinEngine.buildT9Map();
    const digits = Array.from(t9.keys());
    for (const d of digits) {
      const letters = t9.get(d) ?? '';
      for (const c of letters) {
        m.set(c, d);
      }
    }
    return m;
  }

  /** 安卓侧构造仅需 Context(内部建 UserDictionary);鸿蒙侧为保持算法层纯净,UserDictionary 外部注入。 */
  constructor(userDict: UserDictionary = new UserDictionary(null)) {
    this.userDict = userDict;
  }

  isReady(): boolean {
    return this.dict.isReady;
  }

  loadState(): PinyinLoadState {
    return this.loadStateValue;
  }

  addLoadListener(listener: PinyinLoadListener): void {
    this.listeners.push(listener);
    listener(this.loadStateValue, null);
  }

  removeLoadListener(listener: PinyinLoadListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /**
   * 异步加载词库(对齐安卓 loadAsync 的状态机与加载顺序:词库 → 用户词典 → 热词导入 → READY →
   * custom_dict v2 异步挂载)。
   * @param source 词库文本来源(DictionaryLoader 实现)
   * @param importHotwords 热词导入回调(DictionaryLoader 传 HotwordDictionaryBridge.importInto 包装;算法层不触 IO)
   */
  loadAsync(source: PinyinDictSource, importHotwords?: (userDict: UserDictionary) => Promise<void>): void {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.notifyState(PinyinLoadState.LOADING, null);
    this.doLoadInternal(source, importHotwords);
  }

  private async doLoadInternal(source: PinyinDictSource,
    importHotwords?: (userDict: UserDictionary) => Promise<void>): Promise<void> {
    let errMsg: string | null = null;
    let failed = false;
    try {
      await this.dict.load(source);
      await this.userDict.load();
      if (importHotwords !== undefined) {
        await importHotwords(this.userDict);
      }
    } catch (e) {
      failed = true;
      const err = e as Error;
      errMsg = err.message;
    }
    this.loading = false;
    if (!failed && this.dict.isReady) {
      this.notifyState(PinyinLoadState.READY, null);
      // 海量内置自定义词库(custom_dict v2,61 万词)READY 后异步挂载:
      // 不阻塞键盘可用(遮罩已解除),挂载前查询按空表返回;挂载完成后失效 T9 缓存与
      // 段内词缓存(镜像 Android PinyinEngine.kt:runCatching{customDict.load}+post 清缓存;
      // 鸿蒙侧解析分块让出事件循环,与查询同在主事件循环,无跨线程竞态)。
      try {
        const raw = await source.readRawFileBytes('custom_dict.txt');
        await this.customDict.load(raw);
      } catch (e) {
        // 对齐 Kotlin runCatching:自定义词库缺失/读取失败不致命
      }
      // 整句语言模型(词/字 bigram)READY 后异步挂载:修"打对拼音出弱智句";
      // 挂载前 boundaryScore 返回 0(退化为原词频整句),挂载完失效 T9 缓存。
      try {
        const charText = await source.readRawTextFile('char_bigram.txt');
        const wordText = await source.readRawTextFile('word_bigram.txt');
        this.sentenceLm.load(charText, wordText);
      } catch (e) {
        // LM 缺失/读取失败不致命:退化为原词频整句
      }
      this.t9CacheKey = null;
      this.topWordsCache.clear();
    } else {
      this.notifyState(PinyinLoadState.FAILED, errMsg);
    }
  }

  private notifyState(state: PinyinLoadState, detail: string | null): void {
    this.loadStateValue = state;
    // 安卓经 mainHandler.post 回主线程;鸿蒙侧本就在主事件循环,直接派发(快照防回调中增删监听器)
    const snapshot = this.listeners.slice();
    for (const l of snapshot) {
      l(state, detail);
    }
  }

  displaySegmented(input: string): string {
    return this.dict.displaySegmented(input);
  }

  learn(word: string): void {
    this.userDict.learn(word);
  }

  setFuzzy(settings: PinyinFuzzySettings): void {
    this.fuzzy = settings;
  }

  forget(word: string): void {
    this.userDict.forget(word);
  }

  private userBonus(word: string): number {
    return Math.min(this.userDict.bonus(word), PinyinEngine.USER_CAP) * PinyinEngine.USER_WEIGHT;
  }

  private lenBonus(word: string): number {
    return (Math.min(word.length, 5) - 1) * PinyinEngine.LEN_W;
  }

  private layerScore(layer: number, level: number, word: string, penalty: number = 0): number {
    return layer + level * PinyinEngine.LEVEL_W + this.lenBonus(word) - penalty + this.userBonus(word);
  }

  associations(prev: string, limit: number = 12): Candidate[] {
    // 用户自学习优先(个性化),内置 bigram 兜底(冷启动不为空),去重保序。
    const merged = new Set<string>();
    for (const w of this.userDict.nextWords(prev)) {
      merged.add(w);
    }
    for (const w of BuiltinPrediction.nextWords(prev)) {
      merged.add(w);
    }
    const out: Candidate[] = [];
    const arr = Array.from(merged);
    for (let i = 0; i < arr.length && i < limit; i++) {
      out.push(new Candidate(arr[i], 0, PinyinEngine.ASSOC_BASE - i));
    }
    return out;
  }

  learnSequence(prev: string | null, word: string): void {
    this.userDict.learn(word);
    if (prev !== null && prev.length > 0) {
      this.userDict.learnPair(prev, word);
    }
    // 学习立刻生效:清 T9 结果缓存(bigram 影响整句),下次同串重算
    this.t9CacheKey = null;
  }

  /**
   * 用户自造词学习(问题4:耗子尾汁类)。用户对同一拼音串逐词/逐字组合选完后,
   * 由控制层把「整串拼音 + 组合出的词」学进用户词典;下次输入同拼音(26 键或 T9)直接出整词。
   * 词库已有整词则跳过(调频已覆盖);拼音必须可完整切分(护栏,与自定义词同规则)。
   */
  learnPhrase(pinyin: string, word: string): void {
    if (pinyin.length === 0 || word.length < 2 || word.length > 8) {
      return;
    }
    if (!this.allValidSyllables(pinyin)) {
      return;
    }
    for (const e of this.dict.exactWords(pinyin)) {
      if (e.word === word) {
        return;
      }
    }
    let digits = '';
    for (const c of pinyin) {
      const d = this.letter2digit.get(c);
      if (d === undefined) {
        return;
      }
      digits += d;
    }
    this.userDict.learnPhrase(pinyin, digits, word);
    this.t9CacheKey = null;
  }

  /**
   * 26 键候选(业界对齐排序,已本地脚本电池验证:完整拼音错误率 26/30→1/30)。
   * 总原则:**消耗全部已输入字母的候选 > 忽略尾部字母的候选**。
   *  - 词层 = 整词精确 + 前缀补全(每缺失字母罚 PEN_MISS):youmeiy→有没有、dianhu→电话。
   *  - 整句只有消耗全部输入且无整词可覆盖时才置顶(修 nihao→"你哈哦" 压过 你好);
   *    部分覆盖(如 youmeiy 的"有没")沉到所有全消耗层之下。
   *  - 同词去重保最高分(避免 有没有 以不同 matchedLen 重复出现)。
   */
  candidates(input: string, limit: number = PinyinEngine.CAND_LIMIT): Candidate[] {
    if (!this.dict.isReady) {
      return [];
    }
    const pinyin = input.split('\'').join('');
    if (pinyin.length === 0) {
      return [];
    }
    const n = pinyin.length;

    const merged = new Map<string, Candidate>();
    const push = (word: string, matchedLen: number, score: number): void => {
      if (word.length === 0) {
        return;
      }
      const old = merged.get(word);
      if (old === undefined || score > old.score) {
        merged.set(word, new Candidate(word, matchedLen, score));
      }
    };

    // 词层:整词精确 + 前缀补全。高频补全(电话)可胜低频精确词(电弧),缺得越多罚越重。
    const exacts = this.dict.exactWords(pinyin);
    const prefixes = this.dict.prefixWords(pinyin, 400);
    // 自定义词(custom_dict v2):精确与主词库同层同权;前缀补全同罚分(镜像 Android PinyinEngine.kt)。
    const cExacts = this.customDict.exactWords(pinyin);
    const cPrefixes: PrefixHit[] = n >= 2 ? this.customDict.prefixWords(pinyin, 200) : [];
    // hasFullWord 计入自定义词:只有自定义词能整词覆盖时,整句不得抢 LAYER_SENTENCE 置顶。
    const hasFullWord = exacts.length > 0 || prefixes.length > 0 || cExacts.length > 0 || cPrefixes.length > 0;
    for (const e of exacts) {
      push(e.word, n, this.layerScore(PinyinEngine.LAYER_EXACT, e.level, e.word));
    }
    for (const p of prefixes) {
      push(p.word, p.keyLen, this.layerScore(PinyinEngine.LAYER_EXACT, p.level, p.word, (p.keyLen - n) * PinyinEngine.PEN_MISS));
    }
    for (const e of cExacts) {
      push(e.word, n, this.layerScore(PinyinEngine.LAYER_EXACT, e.level, e.word));
    }
    for (const p of cPrefixes) {
      // 低置信长尾词(lv<110)不做预测(打全才出):防弱补全把部分消耗高频词挤出前排
      if (p.level < PinyinEngine.CUSTOM_COMPLETION_MIN_LV) {
        continue;
      }
      push(p.word, p.keyLen, this.layerScore(PinyinEngine.LAYER_EXACT, p.level, p.word, (p.keyLen - n) * PinyinEngine.PEN_MISS));
    }

    const sent = this.sentenceCandidate(pinyin);
    if (sent !== null) {
      let layer = 0;
      if (sent.matchedLen >= n && !hasFullWord) {
        layer = PinyinEngine.LAYER_SENTENCE;        // 长句无整词:整句置顶
      } else if (sent.matchedLen >= n) {
        layer = PinyinEngine.LAYER_SENTENCE_FULL;   // 有整词:整句居次
      } else {
        layer = PinyinEngine.LAYER_SENTENCE_PARTIAL; // 忽略尾字母:沉底于全消耗层
      }
      push(sent.word, sent.matchedLen, layer + Math.max(sent.score, 0));
    }

    for (const e of this.dict.initialsExact(pinyin)) {
      push(e.word, n, this.layerScore(PinyinEngine.LAYER_ABBR, e.level, e.word));
    }
    for (const p of this.dict.initialsPrefix(pinyin, 60)) {
      push(p.word, p.keyLen, this.layerScore(PinyinEngine.LAYER_ABBR_PREFIX, p.level, p.word, (p.keyLen - n) * 15));
    }
    const sylList = this.dict.splitSyllables(pinyin);
    const firstSyl: string | null = sylList.length > 0 ? sylList[0] : null;
    if (firstSyl !== null && firstSyl !== pinyin && this.dict.isSyllable(firstSyl)) {
      for (const e of this.dict.exactWords(firstSyl)) {
        if (e.word.length === 1) {
          push(e.word, firstSyl.length, this.layerScore(PinyinEngine.LAYER_SINGLE, e.level, e.word));
        }
      }
    }
    // 模糊音/纠错隔离:即便其内部出现异常也绝不影响已生成的基础候选(防"候选突然全空")。
    try {
      this.fuzzyCandidates(pinyin, (w: string, lv: number): void => {
        push(w, n, this.layerScore(PinyinEngine.LAYER_FUZZY, lv, w));
      });
    } catch (e) {
      // 隔离:忽略模糊音层异常
    }
    try {
      if (merged.size < 3) {
        this.correctionCandidates(pinyin, (w: string, lv: number): void => {
          push(w, n, this.layerScore(PinyinEngine.LAYER_CORRECTION, lv, w));
        });
      }
    } catch (e) {
      // 隔离:忽略纠错层异常
    }
    // 用户自造词(耗子尾汁类,逐词组合学得):同自定义词规则,PHRASE_FREQ 保证学过必出。
    // 【用户选择记忆】自造词吃下整串输入 → 压过整句(LAYER_SENTENCE 基线,镜像 T9;
    // 曾 LAYER_EXACT=4.2M < 整句 5M,学过的组合在 26 键仍被整句压住)。
    this.userDict.eachPhrase((ppy: string, pdigits: string, word: string, cnt: number): void => {
      const boost = Math.min(cnt, 5) * PinyinEngine.LEVEL_W;
      if (ppy === pinyin) {
        push(word, n, PinyinEngine.LAYER_SENTENCE + PinyinEngine.PHRASE_FREQ * PinyinEngine.LEVEL_W + boost + this.lenBonus(word));
      } else if (pinyin.startsWith(ppy)) {
        push(word, ppy.length, PinyinEngine.LAYER_EXACT + PinyinEngine.PHRASE_FREQ * PinyinEngine.LEVEL_W + boost + this.lenBonus(word));
      } else if (n >= 2 && ppy.startsWith(pinyin)) {
        push(word, ppy.length,
          PinyinEngine.LAYER_EXACT + PinyinEngine.PHRASE_FREQ * PinyinEngine.LEVEL_W + boost + this.lenBonus(word) - (ppy.length - n) * PinyinEngine.PEN_MISS);
      }
    });
    // 分段兜底 + 字面兜底(已本地脚本验证):保证候选栏永不空白。
    if (merged.size < 2) {
      try {
        this.segmentedFallback(pinyin, (w: string, len: number, sc: number): void => {
          push(w, len, sc);
        });
      } catch (e) {
        // 隔离:忽略分段兜底异常
      }
    }
    if (merged.size === 0) {
      push(pinyin, n, PinyinEngine.LAYER_SINGLE - 1); // 字面兜底:输入串自身可上屏,分数垫底
    }
    const ranked: Candidate[] = [];
    merged.forEach((c: Candidate): void => {
      if (!this.userDict.isBlacklisted(c.word)) {
        ranked.push(c);
      }
    });
    ranked.sort((a: Candidate, b: Candidate) => b.score - a.score);
    // 【单字全量可达保底】打全拼音的精确候选绝不被联想潮水挤出(26 键无拼音选择器,
    // 候选列表是唯一通道;修「输入 a 打不出 锕」类生僻字不可达,本地脚本全音节扫描验证)。
    // 保底集并入自定义精确词:自定义词打全同样必可达(镜像 Android PinyinEngine.kt)。
    const exactSet = new Set<string>();
    for (const e of exacts) {
      exactSet.add(e.word);
    }
    for (const e of cExacts) {
      exactSet.add(e.word);
    }
    return this.takeWithExactGuarantee(ranked, limit, exactSet);
  }

  /** 取前 limit 个,但整串精确候选(打全拼音/数字码的字词)绝不被截出——单字全量可达保底。 */
  private takeWithExactGuarantee(ranked: Candidate[], limit: number, exactWords: Set<string>): Candidate[] {
    if (ranked.length <= limit) {
      return ranked;
    }
    const out: Candidate[] = ranked.slice(0, limit);
    if (exactWords.size > 0) {
      for (let i = limit; i < ranked.length; i++) {
        const c = ranked[i];
        if (exactWords.has(c.word)) {
          out.push(c);
        }
      }
    }
    return out;
  }

  /** 整串数字码的精确候选词集合(锁定态按边界过滤)——全量可达保底用。 */
  private t9ExactSet(digits: string, lockedSylls: string[]): Set<string> {
    const out = new Set<string>();
    const lockedPinyin = lockedSylls.join('');
    const bounds = lockedSylls.length === 0 ? new Set<number>() : this.lockedBounds(lockedSylls);
    for (const hit of this.dict.t9ExactWords(digits)) {
      if (lockedSylls.length === 0 || this.lockedCompatible(hit.word, hit.pinyinKey, 0, lockedPinyin, bounds)) {
        out.add(hit.word);
      }
    }
    // 保底集并入自定义精确词:自定义词打全数字码同样必可达(镜像 Android PinyinEngine.kt)
    for (const hit of this.customDict.t9ExactWords(digits)) {
      if (lockedSylls.length === 0 || this.lockedCompatible(hit.word, hit.pinyinKey, 0, lockedPinyin, bounds)) {
        out.add(hit.word);
      }
    }
    // 锁定态逐字组词通道:首锁定音节单字同样保底(锁 yi 必能点出 咦)
    if (lockedSylls.length > 0) {
      for (const e of this.dict.exactWords(lockedSylls[0])) {
        out.add(e.word);
      }
    }
    return out;
  }

  /** 模糊音候选(26 键全拼):整串能完整切成合法音节时,按开关派生等价音节组合查词。 */
  private fuzzyCandidates(pinyin: string, push: (w: string, lv: number) => void): void {
    if (!this.fuzzy.anyFuzzy) {
      return;
    }
    const syls = this.dict.splitSyllables(pinyin);
    if (syls.length === 0 || syls.join('') !== pinyin) {
      return;
    }
    for (const s of syls) {
      if (!this.dict.isSyllable(s)) {
        return;
      }
    }
    let combos: string[] = [''];
    for (const syl of syls) {
      const vars = Array.from(PinyinFuzzy.variants(syl, this.fuzzy));
      const next: string[] = [];
      for (const c of combos) {
        for (const v of vars) {
          next.push(c + v);
          if (next.length >= PinyinEngine.FUZZY_COMBO_CAP) {
            break;
          }
        }
      }
      combos = next;
      if (combos.length >= PinyinEngine.FUZZY_COMBO_CAP) {
        break;
      }
    }
    for (const key of combos) {
      if (key === pinyin) {
        continue;
      }
      for (const e of this.dict.exactWords(key)) {
        push(e.word, e.level);
      }
    }
  }

  /**
   * 分段兜底(对齐搜狗:任何输入都有候选)。从头沿"最长合法音节前缀"逐段出单字;
   * 遇到起不了合法音节的位置,把剩余原样作为字母候选(选中即上屏字母)。只取前 2 段,不递归全展开。
   */
  private segmentedFallback(pinyin: string, push: (w: string, len: number, score: number) => void): void {
    let pos = 0;
    let seg = 0;
    while (pos < pinyin.length && seg < 2) {
      const len = this.dict.longestSyllableAt(pinyin, pos);
      if (len === 0) {
        push(pinyin.substring(pos), pinyin.length, PinyinEngine.LAYER_SINGLE - 2);
        return;
      }
      const syl = pinyin.substring(pos, pos + len);
      for (const e of this.dict.exactWords(syl)) {
        if (e.word.length === 1) {
          push(e.word, pos + len, this.layerScore(PinyinEngine.LAYER_SINGLE, e.level, e.word));
        }
      }
      pos += len;
      seg++;
    }
  }

  /** 容错纠错(26 键全拼):整串无法切分时,对最后一段做编辑距离≤1 还原。 */
  private correctionCandidates(pinyin: string, push: (w: string, lv: number) => void): void {
    if (!this.fuzzy.correction || pinyin.length < 2) {
      return;
    }
    const syls = this.dict.splitSyllables(pinyin);
    if (syls.length === 0) {
      return;
    }
    const last = syls[syls.length - 1];
    if (this.dict.isSyllable(last)) {
      return;
    }
    const prefix = pinyin.substring(0, pinyin.length - last.length);
    for (const fixed of PinyinFuzzy.corrections(last, (s: string): boolean => this.dict.isSyllable(s))) {
      for (const e of this.dict.exactWords(prefix + fixed)) {
        push(e.word, e.level);
      }
    }
  }

  /**
   * 整句候选(26 键)。每词惩罚 SEG_PENALTY(与 T9 侧 sentenceFromPinyin 同款)逼最少词数,
   * 修碎拼垃圾("你哈哦"曾压过"你好");末段允许前缀补全,尾部残音节也能进整句
   * (youmeiy→有没+有、woxiangchif→我想+吃饭),matchedLen==n 表示消耗了全部输入。
   */
  private sentenceCandidate(input: string): Candidate | null {
    const n = input.length;
    if (n < 2) {
      return null;
    }
    const dp: number[] = new Array<number>(n + 1).fill(INT_MIN);
    const from: number[] = new Array<number>(n + 1).fill(-1);
    const word: string[] = new Array<string>(n + 1).fill('');
    dp[0] = 0;
    for (let i = 1; i <= n; i++) {
      const lo = Math.max(0, i - this.dict.maxSyllableLen * 4);
      for (let j = lo; j < i; j++) {
        if (dp[j] === INT_MIN) {
          continue;
        }
        let bestWord: string | null = null;
        let bestLv = 0;
        const b = this.dict.bestWord(input.substring(j, i));
        if (b !== null) {
          bestWord = b.word;
          bestLv = b.level;
        }
        // 自定义词参与切分成句:span bestWord 取 max(主词库, custom)(镜像 Android PinyinEngine.kt)
        const cb = this.customDict.bestWord(input.substring(j, i));
        if (cb !== null && (bestWord === null || cb.level > bestLv)) {
          bestWord = cb.word;
          bestLv = cb.level;
        }
        if (bestWord === null && i === n && j > 0) {
          // 尾段残音节:取最优前缀补全词(按缺失字母数微罚)参与整句
          let compWord: string | null = null;
          let compAdj = 0;
          for (const p of this.dict.prefixWords(input.substring(j, i), 30)) {
            const adj = p.level - (p.keyLen - (i - j)) * 8;
            if (compWord === null || adj > compAdj) {
              compWord = p.word;
              compAdj = adj;
            }
          }
          if (compWord !== null) {
            bestWord = compWord;
            bestLv = compAdj;
          }
        }
        if (bestWord === null) {
          continue;
        }
        const gain = bestLv - PinyinEngine.SEG_PENALTY + Math.min(this.userDict.bonus(bestWord), PinyinEngine.USER_CAP);
        if (dp[j] + gain > dp[i]) {
          dp[i] = dp[j] + gain;
          from[i] = j;
          word[i] = bestWord;
        }
      }
    }
    let end = n;
    while (end > 0 && dp[end] === INT_MIN) {
      end--;
    }
    if (end < 2 || from[end] < 0) {
      return null;
    }
    const parts: string[] = [];
    let cur = end;
    while (cur > 0 && from[cur] >= 0) {
      parts.push(word[cur]);
      cur = from[cur];
    }
    if (cur !== 0 || parts.length < 2) {
      return null;
    }
    parts.reverse();
    return new Candidate(parts.join(''), end, dp[end]);
  }

  /**
   * 把词的拼音 key 按字对齐切成音节(华纳+huana→[hua,na]、西安+xian→[xi,an])。
   * 对不齐(生僻字/数据缺失)返回 null,调用方回退贪心切分。
   */
  alignWordPinyin(word: string, key: string): string[] | null {
    if (word.length === 0 || key.length === 0) {
      return null;
    }
    const ck = word + '\u0001' + key;
    if (this.alignCache.has(ck)) {
      return this.alignCache.get(ck) ?? null;
    }
    let result: string[] | null = null;
    const acc: string[] = [];
    const dfs = (ci: number, pos: number): void => {
      if (result !== null) {
        return;
      }
      if (ci === word.length) {
        if (pos === key.length) {
          result = acc.slice();
        }
        return;
      }
      for (const r of this.dict.readingsOf(word.charAt(ci))) {
        if (key.startsWith(r, pos)) {
          acc.push(r);
          dfs(ci + 1, pos + r.length);
          acc.pop();
          if (result !== null) {
            return;
          }
        }
      }
    };
    dfs(0, 0);
    if (this.alignCache.size > 8000) {
      this.alignCache.clear();
    }
    this.alignCache.set(ck, result);
    return result;
  }

  /**
   * 锁定音节栈 → 边界位置集合(累积长度)。
   * 【单键锁定修复】尾项若只是音节前缀而非完整音节(单键 3 点选 d/f、残拼锁 zh 类),
   * 它只约束"读音从这些字母开始",不构成音节边界——候选读音可越过其末端继续铺开
   * (锁 d 后 的@de 合法)。非尾项保持边界(已被后续点选确认)。
   */
  private lockedBounds(locked: string[]): Set<number> {
    const bounds = new Set<number>();
    let acc = 0;
    for (let i = 0; i < locked.length; i++) {
      acc += locked[i].length;
      if (i === locked.length - 1 && !this.dict.isSyllable(locked[i])) {
        continue;
      }
      bounds.add(acc);
    }
    return bounds;
  }

  /**
   * 候选(word,key)从拼音位置 start 铺开,是否兼容锁定音节边界:
   * ①与锁定拼音重叠部分逐字母一致;②候选在锁定区内结束必须停在音节边界;
   * ③锁定区内部边界必须是候选字读音对齐后的边界(锁 hua 排除 换@huan)。
   */
  private lockedCompatible(word: string, key: string, start: number, lockedPinyin: string, bounds: Set<number>): boolean {
    const lockLen = lockedPinyin.length;
    if (start >= lockLen) {
      return true;
    }
    const end = start + key.length;
    const p = Math.min(end, lockLen);
    if (key.substring(0, p - start) !== lockedPinyin.substring(start, p)) {
      return false;
    }
    if (end < lockLen && !bounds.has(end)) {
      return false;
    }
    const inner: number[] = [];
    const boundArr = Array.from(bounds);
    for (const bv of boundArr) {
      if (bv >= start + 1 && bv < end) {
        inner.push(bv);
      }
    }
    if (inner.length === 0) {
      return true;
    }
    const aligned = this.alignWordPinyin(word, key);
    if (aligned === null) {
      return true; // 生僻字对不齐:不强杀(宁多勿漏)
    }
    const wb = new Set<number>();
    let acc = start;
    for (const s of aligned) {
      acc += s.length;
      wb.add(acc);
    }
    for (const iv of inner) {
      if (!wb.has(iv)) {
        return false;
      }
    }
    return true;
  }

  /** 候选显示拼音:字对齐切分优先(华纳+huana→hua'na),失败回退贪心。 */
  displaySplit(word: string, key: string): string {
    const aligned = this.alignWordPinyin(word, key);
    if (aligned !== null) {
      return aligned.join('\'');
    }
    return this.splitKnownPinyin(key);
  }

  /**
   * T9 候选(业界对齐,数字码索引直查,已本地脚本电池验证)。
   * 总原则与 26 键一致:**消耗全部输入的候选 > 忽略尾部输入的候选**。
   *  - 词层 = 逐前缀精确词(数字码直查,根治 DFS 512 截断丢词:shangban 曾永远打不出"上班")
   *    + 全消耗前缀补全(youmeiy→有没有、shaow→稍微,每缺失位罚 PEN_MISS)。
   *  - 全消耗精确词加 EXACT_FULL_BONUS:同码时精确词(要钱)永远压过补全词(晚上@wanshang)。
   *  - 整句全覆盖时置顶,部分覆盖沉底(镜像 26 键分层)。
   *
   * lockedSylls:拼音选择器锁定音节栈(切分歧义根治)——词层/补全/整句全部按锁定
   * 边界过滤(锁 hua 排除 换@huan),取代旧"锁定拼音串重查+贪心剩余段"路径。
   */
  candidatesT9(digits: string, limit: number = PinyinEngine.CAND_LIMIT, lockedSylls: string[] = []): Candidate[] {
    if (!this.dict.isReady || digits.length === 0) {
      return [];
    }
    const merged = new Map<string, Candidate>();
    const lockedPinyin = lockedSylls.join('');
    const bounds = lockedSylls.length === 0 ? new Set<number>() : this.lockedBounds(lockedSylls);
    const ok = (word: string, key: string): boolean =>
      lockedSylls.length === 0 || this.lockedCompatible(word, key, 0, lockedPinyin, bounds);
    const put = (word: string, matchedLen: number, score: number, pinyin: string = ''): void => {
      if (word.length === 0) {
        return;
      }
      const old = merged.get(word);
      if (old === undefined || score > old.score) {
        merged.set(word, new Candidate(word, matchedLen, score, false, pinyin));
      }
    };
    const consider = (word: string, matchedLen: number, base: number, level: number, pinyin: string): void => {
      put(word, matchedLen,
        matchedLen * PinyinEngine.MATCH_W + base + level * PinyinEngine.LEVEL_W + this.lenBonus(word) + this.userBonus(word),
        pinyin);
    };

    const n = digits.length;
    // 【单键锁定修复】锁定串已覆盖全部数字且尾项只是音节前缀(单键 3 锁 d/f、锁 zh 类):
    // 词层(L>=2)/补全(数字空间在共享键上扫不到目标声母)/锁定单字(须完整音节)全部无产出,
    // 旧实现落进绕过锁定的兜底 → "点了没反应"。此形态语义上等价于"26 键打了 d 这个前缀"
    // → 直接复用 26 键成熟预测通道(的/都/大),matchedLen=n:选词一次吃净全部数字与锁定栈。
    // 方案经 scratch-keyboard-verify/test_t9_prefix_lock.py 全量验证。
    if (lockedSylls.length > 0 && lockedPinyin.length >= n && !this.dict.isSyllable(lockedSylls[lockedSylls.length - 1])) {
      const preds = this.candidates(lockedPinyin, limit);
      const out: Candidate[] = [];
      for (const c of preds) {
        out.push(new Candidate(c.word, n, c.score, false, c.pinyin));
      }
      return out;
    }
    if (n >= 4) {
      // 整句联想(带锁定约束+拼音回溯):全覆盖置顶;部分覆盖沉底(镜像 26 键原则)。
      // top-2 路径:次优整句降 1 个词频级参与排序(用户学习翻转 #1 后原整句变体不消失)。
      const sents = this.sentenceT9(digits, lockedSylls);
      for (let rank = 0; rank < sents.length; rank++) {
        const sh = sents[rank];
        const layer = sh.covered >= n ? PinyinEngine.LAYER_SENTENCE : PinyinEngine.LAYER_SENTENCE_PARTIAL;
        put(sh.whole, sh.covered, sh.covered * PinyinEngine.MATCH_W + layer - rank * PinyinEngine.LEVEL_W, sh.pinyinKey);
      }
    }
    // 简拼(锁定态跳过:简拼词无完整读音,无法验证锁定边界)
    if (lockedSylls.length === 0 && n <= PinyinEngine.MAX_T9_WORD_DIGITS) {
      for (const s of this.expandInitials(digits)) {
        for (const e of this.dict.initialsExact(s)) {
          consider(e.word, n, PinyinEngine.LAYER_ABBR, e.level, '');
        }
      }
    }
    // 词层:逐前缀精确词(数字码索引直查,同码拼音全命中、无展开截断)。
    // 全消耗(L==n)加 EXACT_FULL_BONUS:同码时精确词永远压过下面的补全词。
    // 词层准入(主词库/自定义对称,镜像 Android PinyinEngine.kt):L<=9 照旧;L==n(全消耗)
    // 不限长——打全整词(第六章 10位/事业单位 11位/biang 14位)直接可排,不再只靠整句碰运气。
    const maxL = Math.min(n, Math.max(PinyinEngine.MAX_T9_WORD_DIGITS, this.customDict.maxDigitLen));
    for (let L = 2; L <= maxL; L++) {
      if (L > PinyinEngine.MAX_T9_WORD_DIGITS && L !== n) {
        continue;
      }
      const bonus = L === n ? PinyinEngine.EXACT_FULL_BONUS : 0;
      const seg = digits.substring(0, L);
      const mainHits = this.dict.t9ExactWords(seg);
      for (const hit of mainHits) {
        if (!ok(hit.word, hit.pinyinKey)) {
          continue;
        }
        // 【用户选择记忆】全消耗且用户选过(调频>0)的词层基线提到整句之上——
        // 对齐 RIME 动态调频/搜狗智能调频:用户显式选择 > 机器整句猜测(修 什么鬼/什么会 类)。
        const layer = (L === n && this.userBonus(hit.word) > 0) ? PinyinEngine.LAYER_SENTENCE : PinyinEngine.LAYER_EXACT;
        put(hit.word, L,
          L * PinyinEngine.MATCH_W + layer + bonus + hit.level * PinyinEngine.LEVEL_W + this.lenBonus(hit.word) + this.userBonus(hit.word),
          hit.pinyinKey);
      }
      // 自定义词层(custom_dict v2,镜像 Android PinyinEngine.kt):全消耗时——同码有主词库精确词
      // → 同层公平按词频竞争(防 61 万词劫持常用短码,九宫格正向核心保护);无主词精确词 →
      // LAYER_SENTENCE(破防了/什么鬼 类新词不被整句垃圾压住;biang showcase 语义保留)。
      for (const hit of this.customDict.t9ExactWords(seg)) {
        if (!ok(hit.word, hit.pinyinKey)) {
          continue;
        }
        let layer = PinyinEngine.LAYER_EXACT;
        if (L === n && this.userBonus(hit.word) > 0) {
          layer = PinyinEngine.LAYER_SENTENCE;
        } else if (L === n && mainHits.length === 0) {
          layer = PinyinEngine.LAYER_SENTENCE;
        }
        put(hit.word, L,
          L * PinyinEngine.MATCH_W + layer + bonus + hit.level * PinyinEngine.LEVEL_W + this.lenBonus(hit.word) + this.userBonus(hit.word),
          hit.pinyinKey);
      }
    }
    // 全消耗前缀补全(修"必须打全数字才出词"):数字码前缀直查,matchedLen=n 排在部分消耗词之上,
    // 缺失位数罚 PEN_MISS(与 26 键同值)。youmeiy(9686349)→有没有、shaow(74269)→稍微。
    // 补全是"预测",业界只置顶少量(修 尾@weizhi 被淹没):按调整分只取 top COMPLETION_TOP 入池,
    // 避免几百个"位置信息"类补全词把逐字组词通道的单字(尾)挤出候选池。
    if (n >= 2 && n <= PinyinEngine.MAX_T9_WORD_DIGITS) {
      const comps: CompHit[] = [];
      for (const p of this.dict.t9PrefixWords(digits, 200)) {
        if (!ok(p.word, p.pinyinKey)) {
          continue;
        }
        const adj = p.level * PinyinEngine.LEVEL_W + this.lenBonus(p.word) + this.userBonus(p.word) - (p.keyDigitLen - n) * PinyinEngine.PEN_MISS;
        comps.push(new CompHit(adj, p.word, p.pinyinKey));
      }
      // 自定义词补全并入统一 top-K 池(同罚分同量纲,镜像 Android PinyinEngine.kt);
      // 低置信长尾词(lv<110)不做预测。
      for (const p of this.customDict.t9PrefixWords(digits, 200)) {
        if (p.level < PinyinEngine.CUSTOM_COMPLETION_MIN_LV) {
          continue;
        }
        if (!ok(p.word, p.pinyinKey)) {
          continue;
        }
        const adj = p.level * PinyinEngine.LEVEL_W + this.lenBonus(p.word) + this.userBonus(p.word) - (p.keyDigitLen - n) * PinyinEngine.PEN_MISS;
        comps.push(new CompHit(adj, p.word, p.pinyinKey));
      }
      comps.sort((a: CompHit, b: CompHit) => b.adj - a.adj);
      for (let i = 0; i < comps.length && i < PinyinEngine.COMPLETION_TOP; i++) {
        put(comps[i].word, n, n * PinyinEngine.MATCH_W + PinyinEngine.LAYER_EXACT + comps[i].adj, comps[i].key);
      }
    }
    // 用户自造词(耗子尾汁类,逐词组合学得):整词精确压过垃圾整句;前缀预测同词层罚分规则。
    this.userDict.eachPhrase((pinyin: string, pdigits: string, word: string, cnt: number): void => {
      if (ok(word, pinyin)) {
        const boost = Math.min(cnt, 5) * PinyinEngine.LEVEL_W;
        if (digits.startsWith(pdigits)) {
          put(word, pdigits.length,
            pdigits.length * PinyinEngine.MATCH_W + PinyinEngine.LAYER_SENTENCE + PinyinEngine.PHRASE_FREQ * PinyinEngine.LEVEL_W + boost + this.lenBonus(word),
            pinyin);
        } else if (n >= 2 && pdigits.startsWith(digits)) {
          const sc = n * PinyinEngine.MATCH_W + PinyinEngine.LAYER_EXACT + (PinyinEngine.PHRASE_FREQ + Math.min(cnt, 5)) * PinyinEngine.LEVEL_W + this.lenBonus(word) - (pdigits.length - n) * PinyinEngine.PEN_MISS;
          put(word, n, sc, pinyin.substring(0, n));
        }
      }
    });
    // 锁定态:首锁定音节单字置入(逐字组词通道:锁 hua 必能点出 花/话/华)
    if (lockedSylls.length > 0) {
      const first = lockedSylls[0];
      for (const e of this.dict.exactWords(first)) {
        put(e.word, first.length,
          first.length * PinyinEngine.MATCH_W + PinyinEngine.LAYER_SINGLE + e.level * PinyinEngine.LEVEL_W + this.userBonus(e.word),
          first);
      }
    }
    // 永不空候选兜底:先取最长可成前缀的字/词
    if (merged.size === 0) {
      for (let L = Math.min(n, PinyinEngine.MAX_T9_WORD_DIGITS); L >= 1; L--) {
        for (const hit of this.dict.t9ExactWords(digits.substring(0, L))) {
          consider(hit.word, L, PinyinEngine.LAYER_SINGLE, hit.level, hit.pinyinKey);
        }
        if (merged.size > 0) {
          break;
        }
      }
    }
    // 仍空(尾段半音节,如单个「9」):用「已切前缀+尾段字母」查词 → **纯汉字**续词(我/一/仪),绝不放裸字母
    // 【单键锁定修复】兜底同样尊重锁定过滤(77 锁 q 不得回吐 p/r/s 词)
    if (merged.size === 0) {
      this.appendPartialChinese(digits, merged, lockedSylls.length === 0 ? null : ok);
    }
    const ranked: Candidate[] = [];
    merged.forEach((c: Candidate): void => {
      if (!this.userDict.isBlacklisted(c.word)) {
        ranked.push(c);
      }
    });
    ranked.sort((a: Candidate, b: Candidate) => b.score - a.score);
    // 【单字全量可达保底】整串数字码的精确候选(锁定过滤后)绝不被截出池
    return this.takeWithExactGuarantee(ranked, limit, this.t9ExactSet(digits, lockedSylls));
  }

  /**
   * 尾段半音节的纯汉字续词:已切前缀词 +「前缀+尾段首数字字母」前缀词。绝不产出可上屏的裸字母。
   * ok 非空时(锁定态)按锁定读音过滤(【单键锁定修复】)。
   */
  private appendPartialChinese(digits: string, merged: Map<string, Candidate>,
    ok: ((word: string, key: string) => boolean) | null = null): void {
    const segRes = this.bestT9SegPartial(digits);
    const segs = segRes.segs;
    const covered = segRes.covered;
    const coveredPinyin = segs.join('');
    const put = (w: string, mlen: number, score: number, py: string): void => {
      if (w.length === 0) {
        return;
      }
      if (ok !== null && !ok(w, py)) {
        return;
      }
      const old = merged.get(w);
      if (old === undefined || score > old.score) {
        merged.set(w, new Candidate(w, mlen, score, false, py));
      }
    };
    if (coveredPinyin.length > 0) {
      for (const e of this.dict.exactWords(coveredPinyin)) {
        put(e.word, covered, PinyinEngine.LAYER_EXACT + e.level * PinyinEngine.LEVEL_W + this.lenBonus(e.word) + this.userBonus(e.word), coveredPinyin);
      }
    }
    if (covered < digits.length) {
      const letters = this.t9.get(digits.charAt(covered)) ?? '';
      for (const letter of letters) {
        const pre = coveredPinyin + letter;
        for (const e of this.dict.exactWords(pre)) {
          put(e.word, digits.length, PinyinEngine.LAYER_ABBR + e.level * PinyinEngine.LEVEL_W, pre);
        }
        for (const p of this.dict.prefixWords(pre, 30)) {
          put(p.word, digits.length, PinyinEngine.LAYER_PREFIX + p.level * PinyinEngine.LEVEL_W - (p.keyLen - pre.length) * 15, pre);
        }
      }
    }
  }

  /**
   * 9 宫格「前导音节自选」(图1 mi/ni/o/m,已本地脚本验证)。
   * 只展开**前导 1..3 位数字**(不是整串!)得到可能的合法音节 + 单字母前缀,去重排序。
   * 只碰前导段 → 天然避开 expandFullPinyin 对长串的指数级爆炸(旧实现卡死根因)。
   *
   * 拼音选择器选项:**整段完整音节全部保留、排最前**(7426 的 qian/qiao/shao/pian/piao/shan
   * 一个不能少——修「qiao 打不出来」:低频长音节此前被 limit 按频率截断,用户无从细化),
   * 短前导音节按(频率,段长)补足。选择器可滑动,limit 放宽即可。已本地脚本花式验证 + 0.5ms。
   */
  t9LeadingOptions(digits: string, maxSeg: number = 3, limit: number = 8): string[] {
    if (!this.dict.isReady || digits.length === 0) {
      return [];
    }
    const fullLen = Math.min(maxSeg, digits.length);
    const seen = new Set<string>();
    const fulls: SylLv[] = [];  // 整段音节(len==fullLen)
    const shorts: SylLenLv[] = [];
    for (let L = fullLen; L >= 1; L--) {
      for (const exp of this.expandFullPinyin(digits.substring(0, L))) {
        if (this.dict.isSyllable(exp) && !seen.has(exp)) {
          seen.add(exp);
          const words = this.dict.exactWords(exp);
          const lv = words.length > 0 ? words[0].level : -1;
          if (L === fullLen) {
            fulls.push(new SylLv(exp, lv));
          } else {
            shorts.push(new SylLenLv(exp, L, lv));
          }
        }
      }
    }
    const letters = this.t9.get(digits.charAt(0)) ?? '';
    for (const c of letters) {
      if (this.dict.isSyllablePrefix(c) && !seen.has(c)) {
        seen.add(c);
        shorts.push(new SylLenLv(c, 1, -2));
      }
    }
    fulls.sort((a: SylLv, b: SylLv) => b.lv - a.lv);
    shorts.sort((a: SylLenLv, b: SylLenLv) => {
      if (b.lv !== a.lv) {
        return b.lv - a.lv;
      }
      return b.len - a.len;
    });
    const out: string[] = [];
    for (const f of fulls) {
      if (out.length >= limit) {
        break;
      }
      out.push(f.syl);
    }
    for (const s of shorts) {
      if (out.length >= limit) {
        break;
      }
      out.push(s.syl);
    }
    return out;
  }

  /**
   * 锁定段+待定段候选(完整专业九宫格,已本地脚本验证)。
   * lockedPinyin=已确认拼音前缀(如 "ni"),pending=未确认数字。只展开待定段**前 maxSyllableLen 位**,
   * 与锁定前缀拼接查词 → 永不整串展开,彻底避免卡死。
   */
  candidatesT9Locked(lockedPinyin: string, pending: string, limit: number = PinyinEngine.CAND_LIMIT): Candidate[] {
    if (!this.dict.isReady) {
      return [];
    }
    // 待定段能完整切分 → 用成熟 26 键 candidates() 从「锁定拼音+最优待定拼音」生成(与显示一一对应)
    if (pending.length === 0) {
      return this.candidates(lockedPinyin, limit);
    }
    const seg = this.bestT9Seg(pending);
    if (seg !== null) {
      return this.candidates(lockedPinyin + seg.join(''), limit);
    }
    const merged = new Map<string, Candidate>();
    const put = (w: string, mlen: number, score: number): void => {
      const old = merged.get(w);
      if (old === undefined || score > old.score) {
        merged.set(w, new Candidate(w, mlen, score));
      }
    };
    if (pending.length === 0) {
      // 与 Kotlin 源码逐行对齐保留(实际不可达:顶部已对 pending 为空提前返回)
      for (const e of this.dict.exactWords(lockedPinyin)) {
        put(e.word, lockedPinyin.length, PinyinEngine.LAYER_EXACT + e.level * PinyinEngine.LEVEL_W + this.lenBonus(e.word) + this.userBonus(e.word));
      }
      for (const p of this.dict.prefixWords(lockedPinyin, 100)) {
        put(p.word, lockedPinyin.length, PinyinEngine.LAYER_PREFIX + p.level * PinyinEngine.LEVEL_W - (p.keyLen - lockedPinyin.length) * 15);
      }
    } else {
      const win = pending.substring(0, Math.min(pending.length, this.dict.maxSyllableLen));
      for (const exp of this.expandFullPinyin(win)) {
        if (!this.dict.isSyllablePrefix(exp)) {
          continue;
        }
        const key = lockedPinyin + exp;
        for (const e of this.dict.exactWords(key)) {
          put(e.word, key.length, PinyinEngine.LAYER_EXACT + e.level * PinyinEngine.LEVEL_W + this.lenBonus(e.word) + this.userBonus(e.word));
        }
        for (const p of this.dict.prefixWords(key, 100)) {
          put(p.word, key.length, PinyinEngine.LAYER_PREFIX + p.level * PinyinEngine.LEVEL_W - (p.keyLen - key.length) * 15);
        }
      }
    }
    // 锁定态也保证非空
    if (merged.size === 0) {
      const src = lockedPinyin.length > 0 ? lockedPinyin : pending;
      if (src.length > 0) {
        put(src.charAt(0), 1, 0);
      }
    }
    const ranked: Candidate[] = [];
    merged.forEach((c: Candidate): void => {
      if (!this.userDict.isBlacklisted(c.word)) {
        ranked.push(c);
      }
    });
    ranked.sort((a: Candidate, b: Candidate) => b.score - a.score);
    return ranked.slice(0, limit);
  }

  /** 音节字母串 → T9 数字串(逐音节删除时把锁定音节退回待定数字)。 */
  syllableToDigits(syl: string): string {
    let sb = '';
    for (const c of syl) {
      sb += this.letter2digit.get(c) ?? c;
    }
    return sb;
  }

  /** 拼音键是否可完整切成合法音节(护栏1:不合法则显示/联动会怪,拒绝入库)。 */
  private allValidSyllables(pinyin: string): boolean {
    if (pinyin.length === 0) {
      return false;
    }
    let i = 0;
    while (i < pinyin.length) {
      let matched = 0;
      for (let L = Math.min(this.dict.maxSyllableLen, pinyin.length - i); L >= 1; L--) {
        if (this.dict.isSyllable(pinyin.substring(i, i + L))) {
          matched = L;
          break;
        }
      }
      if (matched === 0) {
        return false;
      }
      i += matched;
    }
    return true;
  }

  /**
   * T9 最优拼音切分(DP,已本地脚本验证):23744→[ce,shi]、64426→[ni,hao]。
   * 每音节惩罚 SEG_PENALTY(>最大词频)逼最少音节、优先长音节成词,避免碎切成 a'e'o 乱码。
   * 返回 covered==n 表示整串可切;否则为无法完整切分(半截输入),交由调用方走部分匹配。
   *
   * DP 切分,返回 (音节列表, 已完整切分的最长前缀长度)。
   */
  private bestT9SegPartial(digits: string): T9SegResult {
    if (!this.dict.isReady || digits.length === 0) {
      return new T9SegResult([], 0);
    }
    const n = digits.length;
    const dp: number[] = new Array<number>(n + 1).fill(INT_MIN);
    const backLen: number[] = new Array<number>(n + 1).fill(0);
    const backSyl: string[] = new Array<string>(n + 1).fill('');
    dp[0] = 0;
    for (let i = 1; i <= n; i++) {
      const maxL = Math.min(this.dict.maxSyllableLen, i);
      for (let L = 1; L <= maxL; L++) {
        if (dp[i - L] === INT_MIN) {
          continue;
        }
        let bestSyl: string | null = null;
        let bestLv = -1;
        for (const exp of this.expandFullPinyin(digits.substring(i - L, i))) {
          if (!this.dict.isSyllable(exp)) {
            continue;
          }
          const words = this.dict.exactWords(exp);
          const lv = words.length > 0 ? words[0].level : 0;
          if (lv > bestLv) {
            bestLv = lv;
            bestSyl = exp;
          }
        }
        if (bestSyl === null) {
          continue;
        }
        const score = dp[i - L] + bestLv - PinyinEngine.SEG_PENALTY;
        if (score > dp[i]) {
          dp[i] = score;
          backLen[i] = L;
          backSyl[i] = bestSyl;
        }
      }
    }
    let covered = 0;
    for (let i = n; i >= 0; i--) {
      if (dp[i] !== INT_MIN) {
        covered = i;
        break;
      }
    }
    const parts: string[] = [];
    let i2 = covered;
    while (i2 > 0) {
      parts.push(backSyl[i2]);
      i2 -= backLen[i2];
    }
    parts.reverse();
    return new T9SegResult(parts, covered);
  }

  /** T9 最优拼音切分(整串可切时返回,否则 null)。 */
  bestT9Seg(digits: string): string[] | null {
    const r = this.bestT9SegPartial(digits);
    return (r.covered === digits.length && r.covered > 0) ? r.segs : null;
  }

  /** 某数字的默认拼音字母(残段显示用):取第一个合法音节前缀字母。 */
  private defaultLetter(d: string): string {
    const letters = this.t9.get(d) ?? '';
    for (const c of letters) {
      if (this.dict.isSyllablePrefix(c)) {
        return c;
      }
    }
    return letters.length > 0 ? letters.charAt(0) : d;
  }

  /** 把已知合法拼音贪心最长切分成音节,用 ' 分隔(wanshan→wan'shan、ceshi→ce'shi)。 */
  private splitKnownPinyin(py: string): string {
    if (py.length === 0) {
      return py;
    }
    const parts: string[] = [];
    let i = 0;
    while (i < py.length) {
      let matched = 0;
      for (let L = Math.min(this.dict.maxSyllableLen, py.length - i); L >= 1; L--) {
        if (this.dict.isSyllable(py.substring(i, i + L))) {
          matched = L;
          break;
        }
      }
      if (matched === 0) {
        parts.push(py.substring(i));
        break;
      }
      parts.push(py.substring(i, i + matched));
      i += matched;
    }
    return parts.join('\'');
  }

  private t9Compute(digits: string, lockedSylls: string[] = []): Candidate[] {
    const key = lockedSylls.length === 0 ? digits : digits + '\u0001' + lockedSylls.join('\'');
    if (key === this.t9CacheKey) {
      return this.t9CacheVal;
    }
    const r = this.candidatesT9(digits, PinyinEngine.T9_POOL, lockedSylls);
    this.t9CacheKey = key;
    this.t9CacheVal = r;
    return r;
  }

  /**
   * T9 候选(多展开算法,准确出多音节整词如 完善/要钱)。与显示拼音一一对应:显示跟随 #1 候选读音。
   */
  candidatesForT9(digits: string, limit: number = PinyinEngine.CAND_LIMIT): Candidate[] {
    if (!this.dict.isReady) {
      return [];
    }
    return this.takeWithExactGuarantee(this.t9Compute(digits), limit, this.t9ExactSet(digits, []));
  }

  /**
   * 整句(作用于拼音串,与 sentenceT9 同款 segPenalty 抗碎切)。用于锁定态:尊重锁定读音又不碎成单字。
   * 修"锁定后候选碎成 进提按提按起 乱码"——26 键 sentenceCandidate 无每词惩罚会碎切。
   * (与 Kotlin 源码对齐保留:当前无调用方。)
   */
  private sentenceFromPinyin(pinyin: string): Candidate | null {
    const n = pinyin.length;
    if (n < 2) {
      return null;
    }
    const dp: number[] = new Array<number>(n + 1).fill(INT_MIN);
    const from: number[] = new Array<number>(n + 1).fill(-1);
    const word: string[] = new Array<string>(n + 1).fill('');
    dp[0] = 0;
    for (let i = 1; i <= n; i++) {
      const lo = Math.max(0, i - this.dict.maxSyllableLen * 4);
      for (let j = lo; j < i; j++) {
        if (dp[j] === INT_MIN) {
          continue;
        }
        const best = this.dict.bestWord(pinyin.substring(j, i));
        if (best === null) {
          continue;
        }
        const gain = best.level - PinyinEngine.SEG_PENALTY;
        if (dp[j] + gain > dp[i]) {
          dp[i] = dp[j] + gain;
          from[i] = j;
          word[i] = best.word;
        }
      }
    }
    let end = n;
    while (end > 0 && dp[end] === INT_MIN) {
      end--;
    }
    if (end < 2 || from[end] < 0) {
      return null;
    }
    const parts: string[] = [];
    let cur = end;
    while (cur > 0 && from[cur] >= 0) {
      parts.push(word[cur]);
      cur = from[cur];
    }
    if (cur !== 0 || parts.length < 2) {
      return null;
    }
    parts.reverse();
    return new Candidate(parts.join(''), end, end * PinyinEngine.MATCH_W + PinyinEngine.LAYER_SENTENCE, false, pinyin.substring(0, end));
  }

  /**
   * 锁定态候选(切分歧义根治重写):不再"锁定拼音串+贪心剩余段重查",而是在**数字空间
   * 全量检索**(与非锁定态同一通道 candidatesT9)+ 锁定音节边界过滤。
   * 锁 hua 后:换@huan 被边界过滤掉,话那么多钱@hua... 保留 → 候选与用户点选意图一致。
   * lockedSylls 为 null 时兼容旧调用(按 lockedPinyin 贪心拆,仅作降级)。
   */
  candidatesForT9Filtered(digits: string, lockedPinyin: string, limit: number = PinyinEngine.CAND_LIMIT,
    lockedSylls: string[] | null = null): Candidate[] {
    if (!this.dict.isReady) {
      return [];
    }
    if (lockedPinyin.length === 0) {
      return this.candidatesForT9(digits, limit);
    }
    const locked = lockedSylls ?? this.greedySylls(lockedPinyin);
    const r = this.takeWithExactGuarantee(this.t9Compute(digits, locked), limit, this.t9ExactSet(digits, locked));
    // 极端情况(锁定边界过滤后全空):回退 26 键通道保证候选非空
    if (r.length === 0) {
      return this.candidates(lockedPinyin, limit);
    }
    return r;
  }

  /** 贪心切音节(仅作旧调用降级;正常路径 Controller 直接传锁定栈)。 */
  private greedySylls(py: string): string[] {
    const parts: string[] = [];
    let i = 0;
    while (i < py.length) {
      let m = 0;
      for (let L = Math.min(this.dict.maxSyllableLen, py.length - i); L >= 1; L--) {
        if (this.dict.isSyllable(py.substring(i, i + L))) {
          m = L;
          break;
        }
      }
      if (m === 0) {
        break;
      }
      parts.push(py.substring(i, i + m));
      i += m;
    }
    return parts;
  }

  /** 识别拼音显示(带锁定):跟随过滤后 #1 候选读音(字对齐切分);无则锁定音节 + 剩余段部分显示。 */
  t9DisplayFiltered(digits: string, lockedPinyin: string, lockedSylls: string[] | null = null): string {
    if (!this.dict.isReady || digits.length === 0) {
      return digits;
    }
    if (lockedPinyin.length === 0) {
      return this.t9DisplayPinyin(digits);
    }
    const locked = lockedSylls ?? this.greedySylls(lockedPinyin);
    // 【单键锁定修复】全部数字都被锁定覆盖:组合区忠实显示用户点选(锁 d 显示 d,
    // 而非 #1 补全候选的完整读音 de——用户显式点选优先于机器预测)。
    if (lockedPinyin.length >= digits.length) {
      return locked.join('\'');
    }
    const firstList = this.candidatesForT9Filtered(digits, lockedPinyin, 1, locked);
    if (firstList.length > 0 && firstList[0].pinyin.length > 0) {
      return this.displaySplit(firstList[0].word, firstList[0].pinyin);
    }
    const remain = lockedPinyin.length < digits.length ? digits.substring(lockedPinyin.length) : '';
    const remainDisp = remain.length === 0 ? '' : this.t9DisplayPinyin(remain);
    const pieces: string[] = [];
    const lockedJoined = locked.join('\'');
    if (lockedJoined.length > 0) {
      pieces.push(lockedJoined);
    }
    if (remainDisp.length > 0) {
      pieces.push(remainDisp);
    }
    return pieces.join('\'');
  }

  /**
   * T9 识别拼音显示串:跟随 #1 候选的读音,按**字对齐**切分(华纳→hua'na 而非 huan'a,
   * 话那么多钱→hua'na'me'duo'qian),保证与首候选严格对应且无幻觉音节。
   * 无候选拼音(简拼)时回退:已切前缀 + 尾段残位默认字母(ce'shi'w),绝不显示原始数字。
   */
  t9DisplayPinyin(digits: string): string {
    if (!this.dict.isReady || digits.length === 0) {
      return digits;
    }
    const computed = this.t9Compute(digits);
    if (computed.length > 0 && computed[0].pinyin.length > 0) {
      return this.displaySplit(computed[0].word, computed[0].pinyin);
    }
    const segRes = this.bestT9SegPartial(digits);
    const parts: string[] = segRes.segs.slice();
    for (let idx = segRes.covered; idx < digits.length; idx++) {
      parts.push(this.defaultLetter(digits.charAt(idx)));
    }
    return parts.join('\'');
  }

  /** 是否合法拼音音节(拼音选择器高亮判定用)。 */
  isSyllable(s: string): boolean {
    return this.dict.isSyllable(s);
  }

  /** 数字段最优切分的第一个音节(拼音选择器高亮用;锁定态 #1 候选无 pinyin 时的兜底)。 */
  t9FirstSyllable(digits: string): string {
    if (!this.dict.isReady || digits.length === 0) {
      return '';
    }
    const segRes = this.bestT9SegPartial(digits);
    if (segRes.segs.length > 0) {
      return segRes.segs[0];
    }
    return this.defaultLetter(digits.charAt(0));
  }

  /**
   * 整句联想:**top-K 状态 DP**(每位置保留 K 条不同末词路径,段内取 top-K 词)+ 用户 bigram 转移加成
   * (learnPair 越用越准,已验证:你好呀/买点东西/再吃个火锅/可以啊小哥哥 学习后修复)+ 自定义词跳转 +
   * 最远可达前缀。SENT_PEN=380 为电池扫描最优(独立于显示切分的 SEG_PENALTY)。
   * 本地脚本验证:电池 25 句无学习 14 全对(81%),学习后 19 全对(92%);热态单步 1.3ms。
   *
   * 返回 (句子, 覆盖位数, 拼音key串)。拼音回溯:整句候选不再是"无读音黑箱"——显示拼音
   * 跟随 #1 候选时,话那么多钱→hua'na'me'duo'qian(修 ne 幻觉:旧 bestT9SegPartial 按
   * 音节频率瞎猜出词典中不存在的组合)。lockedSylls:锁定音节边界约束(锁 hua 排除跨界词)。
   */
  private sentenceT9(digits: string, lockedSylls: string[] = []): SentenceHit[] {
    const raw = digits.length;
    if (raw < 4) {
      return [];
    }
    const lockedPinyin = lockedSylls.join('');
    const bounds = lockedSylls.length === 0 ? new Set<number>() : this.lockedBounds(lockedSylls);
    const n = Math.min(raw, PinyinEngine.MAX_T9_SENTENCE);
    // dp[i]: 末词 -> SentSt
    const dp: Map<string, SentSt>[] = [];
    for (let i = 0; i <= n; i++) {
      dp.push(new Map<string, SentSt>());
    }
    dp[0].set('', new SentSt(0, -1, '', ''));
    const cand = new Map<string, SentSt>();
    for (let i = 1; i <= n; i++) {
      cand.clear();
      const relax = (w: string, base: number, j: number, key: string): void => {
        // 锁定约束:词铺在拼音区间 [j, j+key.length);与锁定边界/字母冲突则弃
        if (lockedSylls.length > 0 && !this.lockedCompatible(w, key, j, lockedPinyin, bounds)) {
          return;
        }
        dp[j].forEach((st: SentSt, pw: string): void => {
          let g = base;
          if (pw.length > 0) {
            // 整句语言模型:跨词边界打分(词bigram 中心化 delta / 字bigram OOV veto)。
            // 修"打对拼音出弱智句"(因为你搬过来→因为你包裹来);挂载前返回 0(退化原行为)。
            g += this.sentenceLm.boundaryScore(pw, w);
            const c = this.userDict.pairCount(pw, w);
            if (c > 0) {
              g += Math.min(c, 2) * PinyinEngine.BIGRAM_W;
            }
          }
          const sc = st.score + g;
          const old = cand.get(w);
          if (old === undefined || sc > old.score) {
            cand.set(w, new SentSt(sc, j, pw, key));
          }
        });
      };
      const lo = Math.max(0, i - PinyinEngine.MAX_T9_SEG);
      for (let j = lo; j < i; j++) {
        if (dp[j].size === 0) {
          continue;
        }
        const segWords = this.topT9Words(digits.substring(j, i));
        for (const t of segWords) {
          relax(t.word, t.level - PinyinEngine.SENT_PEN, j, t.pinyinKey);
        }
        // 末段残段(i==n 且无精确词):前缀补全参与整句(youmeiy 的尾"y"→有、
        // woxiangchih 的尾"h"→吃喝),缺失位微罚(对齐 26 键 sentenceCandidate *8)。
        if (i === n && j > 0 && segWords.length === 0) {
          let compW: string | null = null;
          let compAdj = 0;
          let compKey = '';
          for (const p of this.dict.t9PrefixWords(digits.substring(j, i), 30)) {
            const adj = p.level - (p.keyDigitLen - (i - j)) * 8;
            if (compW === null || adj > compAdj) {
              compW = p.word;
              compAdj = adj;
              compKey = p.pinyinKey;
            }
          }
          if (compW !== null) {
            relax(compW, compAdj - PinyinEngine.SENT_PEN, j, compKey.substring(0, i - j));
          }
        }
      }
      // 用户自造词跳转:学过的组合词(耗子尾汁)整句直达
      this.userDict.eachPhrase((ppy: string, pdigits: string, word: string, cnt: number): void => {
        const len = pdigits.length;
        if (i >= len && dp[i - len].size > 0 && digits.startsWith(pdigits, i - len)) {
          relax(word, (PinyinEngine.PHRASE_FREQ + Math.min(cnt, 5)) * PinyinEngine.LEVEL_W, i - len, ppy);
        }
      });
      // (custom_dict v2)自定义词已并入 topT9Words 词源以同量纲增益参与所有 span——
      // 废弃旧"freq*LEVEL_W 千倍跳转增益"(单词条 showcase 设计,海量词会摧毁整句评分体系)。
      // 【错键容忍,对齐 Gboard 插入错误解码】把第 i-1 位当"误触"跳过:状态原样前移
      // 一位、重罚 GAP_PEN(>任何成词净收益,正常/残拼输入永不偏好跳过)。修「连敲错
      // 几个键后候选/拼音永久冻结,需狂按回退」——垃圾段后的合法输入重新参与解码,
      // matchedLen 含跳过位 → 选词一次性吃掉误触数字。锁定前缀区内禁止跳过。
      if (i - 1 >= lockedPinyin.length) {
        dp[i - 1].forEach((st: SentSt, pw: string): void => {
          const sc = st.score - PinyinEngine.GAP_PEN;
          const old = cand.get(pw);
          if (old === undefined || sc > old.score) {
            cand.set(pw, new SentSt(sc, st.from, st.prevWord, st.key));
          }
        });
      }
      if (cand.size > 0) {
        const arr: CandEntry[] = [];
        cand.forEach((st: SentSt, k: string): void => {
          arr.push(new CandEntry(k, st));
        });
        arr.sort((a: CandEntry, b: CandEntry) => b.st.score - a.st.score);
        for (let t = 0; t < arr.length && t < PinyinEngine.SENT_TOPK; t++) {
          dp[i].set(arr[t].k, arr[t].st);
        }
      }
    }
    let cov = 0;
    for (let i = n; i >= 2; i--) {
      if (dp[i].size > 0) {
        cov = i;
        break;
      }
    }
    if (cov < 2) {
      return [];
    }
    // 【整句 top-2】输出最优+次优两条路径(dp 本就保留 SENT_TOPK 状态):
    // 用户学习翻转 #1 后(什么鬼),原整句(什么会)仍作为次优候选可选(对齐搜狗整句变体)。
    const results: SentenceHit[] = [];
    const seen = new Set<string>();
    const endArr: CandEntry[] = [];
    dp[cov].forEach((st: SentSt, k: string): void => {
      endArr.push(new CandEntry(k, st));
    });
    endArr.sort((a: CandEntry, b: CandEntry) => b.st.score - a.st.score);
    const top = Math.min(2, endArr.length);
    for (let e = 0; e < top; e++) {
      let w = endArr[e].k;
      const parts: string[] = [];
      const keys: string[] = [];
      let i = cov;
      let broken = false; // 对齐 Kotlin continue@outer
      while (i > 0) {
        const st = dp[i].get(w);
        if (st === undefined) {
          broken = true;
          break;
        }
        if (w.length > 0) { // 空态载体(头部垃圾)不产出词
          parts.push(w);
          keys.push(st.key);
        }
        i = st.from;
        w = st.prevWord;
      }
      if (broken || parts.length === 0) {
        continue;
      }
      // 跳过位数 = 覆盖位数 - 各词拼音位数之和;有跳过时允许单词句
      // (77+你好:垃圾头+单词也要能出候选并吃掉垃圾),纯净路径仍要求 ≥2 词。
      let keyLen = 0;
      for (const k of keys) {
        keyLen += k.length;
      }
      if (parts.length < 2 && cov - keyLen <= 0) {
        continue;
      }
      parts.reverse();
      keys.reverse();
      const whole = parts.join('');
      if (seen.has(whole)) {
        continue;
      }
      seen.add(whole);
      results.push(new SentenceHit(whole, cov, keys.join('')));
    }
    return results;
  }

  // 段内 top-K 词(记忆化,带拼音 key 供整句回溯):top-1 会剪掉 买点/再 等同码次频词,
  // K=3 让 bigram 学习有路径可选。数字码索引直查:同码拼音全命中,长段无 DFS 截断。
  private topT9Words(seg: string): T9Hit[] {
    const cached = this.topWordsCache.get(seg);
    if (cached !== undefined) {
      return cached;
    }
    const best = new Map<string, LvKey>();
    for (const hit of this.dict.t9ExactWords(seg)) {
      const old = best.get(hit.word);
      const oldLv = old !== undefined ? old.lv : -1;
      if (hit.level > oldLv) {
        best.set(hit.word, new LvKey(hit.level, hit.pinyinKey));
      }
    }
    // 自定义词作为普通词参与整句(lv 与主词库同量纲,同 map 取更高 lv;镜像 Android PinyinEngine.kt)
    for (const hit of this.customDict.t9ExactWords(seg)) {
      const old = best.get(hit.word);
      const oldLv = old !== undefined ? old.lv : -1;
      if (hit.level > oldLv) {
        best.set(hit.word, new LvKey(hit.level, hit.pinyinKey));
      }
    }
    const arr: T9Hit[] = [];
    best.forEach((v: LvKey, w: string): void => {
      arr.push(new T9Hit(w, v.lv, v.key));
    });
    arr.sort((a: T9Hit, b: T9Hit) => b.level - a.level);
    const r = arr.slice(0, PinyinEngine.SENT_TOPK);
    if (this.topWordsCache.size > 8000) {
      this.topWordsCache.clear();
    }
    this.topWordsCache.set(seg, r);
    return r;
  }

  private expandInitials(digits: string): string[] {
    const out: string[] = [];
    const sb: string[] = new Array<string>(digits.length).fill('');
    const dfs = (pos: number): void => {
      if (out.length >= 120) {
        return;
      }
      if (pos === digits.length) {
        out.push(sb.join(''));
        return;
      }
      const letters = this.t9.get(digits.charAt(pos));
      if (letters === undefined) {
        return;
      }
      for (const c of letters) {
        sb[pos] = c;
        if (this.dict.initialsHasPrefix(sb.slice(0, pos + 1).join(''))) {
          dfs(pos + 1);
        }
      }
    };
    dfs(0);
    return out;
  }

  private expandFullPinyin(digits: string): string[] {
    const cached = this.expandCache.get(digits);
    if (cached !== undefined) {
      return cached;
    }
    const r = this.expandFullPinyinRaw(digits);
    if (this.expandCache.size > 4000) {
      this.expandCache.clear();
    }
    this.expandCache.set(digits, r);
    return r;
  }

  private expandFullPinyinRaw(digits: string): string[] {
    const out: string[] = [];
    const sb: string[] = new Array<string>(digits.length).fill('');
    const dfs = (pos: number, sylStart: number): void => {
      if (out.length >= 512) {
        return;
      }
      if (pos === digits.length) {
        out.push(sb.join(''));
        return;
      }
      const letters = this.t9.get(digits.charAt(pos));
      if (letters === undefined) {
        return;
      }
      for (const c of letters) {
        sb[pos] = c;
        const curSyl = sb.slice(sylStart, pos + 1).join('');
        if (this.dict.isSyllablePrefix(curSyl)) {
          dfs(pos + 1, sylStart);
          if (this.dict.isSyllable(curSyl)) {
            dfs(pos + 1, pos + 1);
          }
        }
      }
    };
    dfs(0, 0);
    return out;
  }

  // ===== 对齐 Kotlin companion object 常量 =====
  private static readonly LEVEL_W = 1_000;
  private static readonly LEN_W = 400;
  private static readonly LAYER_SENTENCE = 5_000_000;
  private static readonly LAYER_EXACT = 4_000_000;
  private static readonly LAYER_SENTENCE_FULL = 3_900_000;    // 整句(全消耗但已有整词):居次
  private static readonly LAYER_SENTENCE_PARTIAL = 1_800_000; // 整句(忽略尾字母):沉底于全消耗层
  private static readonly PEN_MISS = 8_000;                   // 前缀补全每缺失字母罚分(≈8 个词频级)
  private static readonly EXACT_FULL_BONUS = 60_000;          // T9 全消耗精确词加成:同码时精确(要钱)必压补全(晚上)
  private static readonly COMPLETION_TOP = 12;                // T9 补全预测入池上限(业界:预测只置顶少量,防淹没单字)
  // 自定义词参与"补全预测"的最低词频等级:预测必须高置信(jieba 标定真实常用≥110 或精选热词 142);
  // 长尾词(base残余/ext默认55)只在"打全"时可达——防弱补全把部分消耗高频词(我想@woxiangch)挤出前排。
  private static readonly CUSTOM_COMPLETION_MIN_LV = 110;
  // 2026-07 修「yi 打不出咦」:词库去除 30/key 构建截断后大音节(yi=137字)全量入库,
  // 100/120 会把锁定单音节的尾部单字再次截掉 → 200/300 + takeWithExactGuarantee 保证全量可达。
  static readonly CAND_LIMIT = 200;                           // 候选显示上限(40/60 会把中频单字如 尾@weizhi 截掉)
  private static readonly T9_POOL = 300;                      // T9 结果缓存池大小
  private static readonly PHRASE_FREQ = 200;                  // 用户自造词基准词频级(高于最高静态词频,学过必出)
  private static readonly LAYER_FUZZY = 3_500_000;
  private static readonly LAYER_ABBR = 3_000_000;
  private static readonly LAYER_PREFIX = 2_000_000;
  private static readonly LAYER_CORRECTION = 1_500_000;
  private static readonly LAYER_ABBR_PREFIX = 1_000_000;
  private static readonly LAYER_SINGLE = 0;
  private static readonly FUZZY_COMBO_CAP = 24;
  private static readonly USER_WEIGHT = 20_000;
  private static readonly USER_CAP = 20;
  private static readonly MATCH_W = 1_000_000;
  private static readonly MAX_T9_WORD_DIGITS = 9;
  private static readonly ASSOC_BASE = 10_000_000;
  private static readonly MAX_T9_SEG = 13; // 8→13:让 逛一逛(12位)/吃火锅(9位) 等词库长短语参与整句(脚本验证)
  private static readonly MAX_T9_SENTENCE = 64; // 整句联想最大数字位数(≈21字);记忆化后单步<1ms
  private static readonly SEG_PENALTY = 300;
  private static readonly SENT_PEN = 380;  // 整句每词惩罚(电池扫描最优,独立于显示切分)
  private static readonly GAP_PEN = 600;   // 错键容忍:跳过一位"误触"的罚分(>最大成词净收益)
  private static readonly SENT_TOPK = 3;   // 状态 DP 每位置/每段保留路径数
  private static readonly BIGRAM_W = 200;  // 用户 bigram 每次共现加成(封顶2次=400)
}
