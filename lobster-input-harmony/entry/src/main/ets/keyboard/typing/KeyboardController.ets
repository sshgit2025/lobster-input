// 对齐 Android: keyboard/typing/KeyboardController.kt(612 行,打字状态中枢,逐行复刻)
import { Candidate, PinyinEngine } from '../pinyin/PinyinEngine';
import { PinyinLoadState } from '../pinyin/PinyinLoadState';
import { ComposingTextBridge } from './composing/ComposingTextBridge';
import { EmojiData } from './EmojiData';
import {
  ChineseQwertyStrategy,
  ChineseT9Strategy,
  EnglishQwertyStrategy,
  InputStrategy,
  KoreanStrategy,
  RussianStrategy,
  StrategyContext,
  StringBuilder
} from './InputStrategy';
import { LayoutState } from './KeyboardLayoutFactory';
import { KeyboardRenderer } from './KeyboardRenderer';
import { InputLang, KbStr, KeySpec, KeyType, TypingKeyboardHost } from './KeyModels';
import { SmartPunctuation } from './SmartPunctuation';
import { PunctuationSuggestion } from './PunctuationSuggestion';
import { SymbolData } from './SymbolData';

/**
 * 键盘输入状态机(控制层)。组合、候选、模式切换、Enter/Space 语义、撤销、组合预览。
 */
export class KeyboardController implements StrategyContext {
  private readonly host: TypingKeyboardHost;
  readonly engine: PinyinEngine;
  private readonly composingBridge?: ComposingTextBridge;

  readonly composing: StringBuilder = new StringBuilder();
  // 输入语种(中/英/俄/韩)。中英为核心语种;俄韩为扩展语种(独立布局,LANG 环 + 工具页直达)。
  private inputLang: InputLang;

  private get chineseMode(): boolean {
    return this.inputLang === InputLang.ZH;
  }

  private nineGrid: boolean;
  private shiftOn: boolean = false;
  private capsLock: boolean = false;
  private symbolPage: boolean = false;
  private numberPage: boolean = false;
  private emojiPage: boolean = false;
  private clipPage: boolean = false;
  private toolsPage: boolean = false;
  private symBoardPage: boolean = false;
  private symbolPageIndex: number = 0;
  private strategy: InputStrategy;
  private lastWord?: string;
  /**
   * 候选栏标点联想 v2(2026-07-23,test_punct_suggestion.py 模型):
   * 同一 lastWord 点选过标点后不再重复推荐——仅在取不到光标前文本时的兜底抑制;
   * 取得到上文时以文本实时判定为唯一事实源(退格删标点自然恢复)。
   */
  private punctConsumedFor?: string;
  private renderer?: KeyboardRenderer;
  private inputBlocked: boolean = false;

  /**
   * 9 宫格拼音选择器锁定的音节栈(问题2:锁定即消耗,LIFO 回退)。
   * 过滤模型:composing 保留全部数字不消耗,候选按锁定读音前缀过滤;
   * 选择器只展示未锁定剩余段的选项——全部锁定后选择器消失;
   * 选词按消耗从栈头对齐扣减(剩余锁定保持,选词后选择器不再弹出);
   * 回退键先 LIFO 撤销栈顶锁定,栈空才删数字(对齐搜狗音节点选交互)。
   */
  private readonly t9LockedSyllables: string[] = [];

  private get t9LockedPinyin(): string {
    return this.t9LockedSyllables.join('');
  }

  /**
   * 9 宫格 1 键(@#)符号候选态:候选栏展示 SymbolData.key1Symbols 固定高频符号
   * (对齐豆包;test_key1_symbols.py 模型验证)。点选符号后保持(可连点);
   * 任何其它按键(字母/删除/空格/回车/切页)即退出,恢复常规候选逻辑。
   */
  private symCandidateMode: boolean = false;

  /**
   * 组词会话(问题4:用户自造词):同一拼音串被用户**分多次选词**消耗完时,
   * 把「整串拼音 + 组合出的词」学进用户词典(耗子尾汁类,下次直接出整词)。
   * 会话在 composing 从空到非空时开始;删除/丢弃/切模式即中止(防学到脏数据)。
   */
  private readonly sessionWords: StringBuilder = new StringBuilder();
  private readonly sessionPinyin: StringBuilder = new StringBuilder();
  private sessionPicks: number = 0;
  private sessionValid: boolean = true;

  constructor(host: TypingKeyboardHost, engine: PinyinEngine, composingBridge?: ComposingTextBridge) {
    this.host = host;
    this.engine = engine;
    this.composingBridge = composingBridge;
    this.inputLang = host.inputLangDefault();
    this.nineGrid = host.isNineGridDefault();
    this.strategy = this.pickStrategy();
  }

  private sessionReset(): void {
    this.sessionWords.setLength(0);
    this.sessionPinyin.setLength(0);
    this.sessionPicks = 0;
    this.sessionValid = true;
  }

  private sessionRecordPick(c: Candidate, consumedPinyin: string): void {
    if (!this.sessionValid) return;
    if (consumedPinyin.length === 0 || c.word.length === 0) {
      this.sessionValid = false;
      return;
    }
    this.sessionWords.append(c.word);
    this.sessionPinyin.append(consumedPinyin);
    this.sessionPicks++;
  }

  private sessionMaybeLearn(): void {
    // 【用户选择记忆,对齐 RIME encode_commit_history】≥1 次选词拼完整串即编码上屏历史:
    // 单次点选整句拼出的候选(什么鬼)也必须学(learnPhrase 自带护栏:2-8 字/可切分/
    // 词库已有整词跳过),否则下次同串默认仍是机器整句(什么会)。
    if (this.sessionValid && this.sessionPicks >= 1 && !this.isPasswordField()) {
      this.engine.learnPhrase(this.sessionPinyin.toString(), this.sessionWords.toString());
    }
    this.sessionReset();
  }

  /** 组合区击键:composing 为空时开始新组词会话。 */
  private onComposingKeystroke(): void {
    if (this.composing.isEmpty()) this.sessionReset();
  }

  /**
   * 问题3:多输入框连续填充的模式保持(对齐 Gboard 会话内布局粘性)。
   * 用户**手动**切到数字键盘页后置位;同一键盘会话内切换输入框(验证码逐格跳转)时 reset()
   * 会恢复数字页,而不是回到拼音初始态。用户手动切回字母页/切布局/键盘收起(会话结束)时清除。
   */
  private stickyNumberPage: boolean = false;

  /**
   * 英文框自动切换(邮箱/URI/密码,对齐 Gboard/搜狗):进入时自动切英文,只在会话内生效,
   * 不写用户偏好;离开英文框(下一次 reset 非英文框)恢复用户原偏好。
   */
  private autoEnglishOverride: boolean = false;

  // Android Handler 重复删除 → setTimeout 链(句柄 number)
  private deleteTimer: number = -1;
  private deleteRepeating: boolean = false;
  private readonly deleteRunnable: () => void = () => {
    if (!this.deleteRepeating) return;
    this.doDelete();
    this.deleteTimer = setTimeout(this.deleteRunnable, 48);
  };

  bind(renderer: KeyboardRenderer): void {
    this.renderer = renderer;
  }

  setInputBlocked(blocked: boolean): void {
    this.inputBlocked = blocked;
    this.renderer?.setInputBlocked(blocked);
  }

  // 非中文一律 26 键式布局(对齐搜狗/Gboard 默认:九宫格中文切英/俄/韩直接变对应 26 键式布局,
  // T9 多击输入已过时);nineGrid 偏好只作用于中文,切回中文仍是九宫格。
  private pickStrategy(): InputStrategy {
    if (this.inputLang === InputLang.RU) return new RussianStrategy(this);
    if (this.inputLang === InputLang.KO) return new KoreanStrategy(this);
    if (this.chineseMode && this.nineGrid) return new ChineseT9Strategy(this);
    if (this.chineseMode) return new ChineseQwertyStrategy(this);
    return new EnglishQwertyStrategy(this);
  }

  get shiftActive(): boolean {
    return this.shiftOn || this.capsLock;
  }

  commit(text: string): void {
    this.host.onCommit(text);
  }

  deleteBeforeCursor(): void {
    this.host.onDeleteBeforeCursor();
  }

  composingText(text: string): void {
    this.host.onComposingText(text);
  }

  finishComposing(): void {
    this.host.onFinishComposing();
  }

  isPasswordField(): boolean {
    return this.host.isPasswordField();
  }

  isMicAvailable(): boolean {
    return this.host.isMicAvailable();
  }

  /**
   * 拼音选择器竖排选项(左侧):当前编辑段(锁定前缀之后的剩余数字)的可选读音。
   * 如 9267426 锁定 "wan" 后,剩余 "7426" → [shan, sha, ...] 供细化;无输入则空。
   */
  t9PinyinOptions(): string[] {
    if (!this.t9Active || this.composing.isEmpty()) return [];
    const remain = this.t9LockedPinyin.length < this.composing.length
      ? this.composing.substring(this.t9LockedPinyin.length) : '';
    if (remain.length === 0) {
      // 【常驻可改选,2026-07-11 对齐搜狗/百度】全部锁定后选择器不再消失:
      // 显示末段的可选读音(当前锁定项保底在列),点其它项即改选(selectT9Pinyin 替换末段)。
      // 方案经 test_t9_selector_persist.py 模型验证。
      if (this.t9LockedSyllables.length === 0) return [];
      const last = this.t9LockedSyllables[this.t9LockedSyllables.length - 1];
      const segStart = this.t9LockedPinyin.length - last.length;
      const opts: string[] = this.engine.t9LeadingOptions(this.composing.substring(segStart), 6, 12).slice();
      if (!opts.includes(last)) opts.unshift(last);
      return opts;
    }
    // maxSeg=6 覆盖 4-6 字母长音节;limit=12(选择器可滑动)+ 引擎整段音节全保留(修 qiao 被截断);
    // 再保证高亮项(首候选读音)始终在列可点(本地脚本花式验证)
    const opts: string[] = this.engine.t9LeadingOptions(remain, 6, 12).slice();
    const active = this.t9ActiveOption();
    if (active.length > 0 && !opts.includes(active)) opts.unshift(active);
    return opts;
  }

  /**
   * 当前编辑段应高亮的读音 = #1 候选在锁定前缀之后的首音节。
   * 用字对齐切分取音节(话那么多钱@huanameduoqian 锁定 hua 后高亮 na,而不是贪心切出 name/nam);
   * 对不齐(生僻字)回退贪心;无候选读音回退剩余段最优首音节。
   */
  t9ActiveOption(): string {
    // 全锁定态:高亮用户点选的末段(常驻可改选,与 t9PinyinOptions 的末段选项对应)
    if (this.composing.isNotEmpty() && this.t9LockedPinyin.length >= this.composing.length) {
      return this.t9LockedSyllables.length > 0
        ? this.t9LockedSyllables[this.t9LockedSyllables.length - 1] : '';
    }
    const cands = this.currentCandidates();
    const top: Candidate | undefined = cands.length > 0 ? cands[0] : undefined;
    const py = top?.pinyin;
    if (top !== undefined && py !== undefined && py.length > 0 && py.length > this.t9LockedPinyin.length) {
      const aligned = this.engine.alignWordPinyin(top.word, py);
      if (aligned !== null) {
        let acc = 0;
        for (let i = 0; i < aligned.length; i++) {
          const syl = aligned[i];
          if (acc === this.t9LockedPinyin.length) return syl;
          acc += syl.length;
          if (acc > this.t9LockedPinyin.length) break; // 锁定边界与对齐不一致:回退贪心
        }
      }
      const rest = py.substring(this.t9LockedPinyin.length);
      for (let L = Math.min(6, rest.length); L >= 1; L--) {
        if (this.engine.isSyllable(rest.substring(0, L))) return rest.substring(0, L);
      }
    }
    const remain = this.t9LockedPinyin.length < this.composing.length
      ? this.composing.substring(this.t9LockedPinyin.length) : '';
    return remain.length === 0 ? '' : this.engine.t9FirstSyllable(remain);
  }

  /**
   * 用户点选拼音选择器某读音:压入锁定栈(不消耗数字),候选按读音前缀收窄。
   * 全锁定态(2026-07-11 常驻可改选)= 改选末段:pop 末段再压新项;放不下则恢复原样(防御)。
   */
  selectT9Pinyin(syl: string): void {
    const clean = syl.split("'").join('');
    if (clean.length === 0) return;
    if (this.t9LockedPinyin.length + clean.length <= this.composing.length) {
      this.t9LockedSyllables.push(clean);
    } else if (this.t9LockedSyllables.length > 0 && this.t9LockedPinyin.length >= this.composing.length) {
      const last = this.t9LockedSyllables.pop() as string;
      if (this.t9LockedPinyin.length + clean.length <= this.composing.length) {
        this.t9LockedSyllables.push(clean);
      } else {
        this.t9LockedSyllables.push(last);
      }
    }
    this.host.onKeyFeedback();
    this.refreshCandidates();
  }

  /**
   * 选词消耗锁定栈:从栈头按消耗的拼音位数对齐扣减(T9 一字母一数字)。
   * 剩余锁定保持 → 选词后选择器不再重弹(问题2核心);消耗跨音节边界时整体清空(安全回退)。
   */
  private t9ConsumeLocked(consumed: number): void {
    let left = consumed;
    while (left > 0 && this.t9LockedSyllables.length > 0) {
      const head = this.t9LockedSyllables[0];
      if (left >= head.length) {
        left -= head.length;
        this.t9LockedSyllables.shift();
      } else {
        this.t9LockedSyllables.length = 0;
        return;
      }
    }
  }

  private get t9Active(): boolean {
    return this.nineGrid && this.chineseMode && !this.symbolPage && !this.numberPage && !this.emojiPage &&
      !this.clipPage && !this.symBoardPage;
  }

  /** 当前有效候选来源(带拼音选择器锁定音节栈过滤:数字空间检索+锁定边界裁决)。 */
  private currentCandidates(): Candidate[] {
    return this.t9Active
      ? this.engine.candidatesForT9Filtered(this.composing.toString(), this.t9LockedPinyin, undefined,
        this.t9LockedSyllables)
      : this.strategy.candidates();
  }

  refreshCandidates(): void {
    if (this.t9Active && this.composing.isNotEmpty()) {
      // 9 宫格:组合区显示识别拼音(跟随过滤后#1),候选=过滤候选,左侧竖排=拼音选择器
      // 核心(候选+识别拼音)必须先渲染且不可被装饰性选择器拖垮
      const display = this.engine.t9DisplayFiltered(this.composing.toString(), this.t9LockedPinyin,
        this.t9LockedSyllables);
      this.composingBridge?.update(display);
      this.renderer?.renderCandidates(display, this.injectEmoji(this.currentCandidates()), this.layoutSwitchText());
      // 拼音选择器为装饰增强:任何异常都隔离,绝不阻塞核心打字
      try {
        this.renderer?.renderPinyinSelector(this.t9PinyinOptions(), this.t9ActiveOption());
      } catch (e) {
        // 装饰性能力异常隔离(对齐 Kotlin runCatching)
      }
    } else if (this.composing.isNotEmpty()) {
      this.renderer?.renderPinyinSelector([], '');
      const display = this.strategy.composingDisplay();
      this.composingBridge?.update(this.chineseMode ? display : '');
      this.renderer?.renderCandidates(display, this.injectEmoji(this.strategy.candidates()), this.layoutSwitchText());
    } else if (this.symCandidateMode) {
      // 1 键符号候选态(组合区为空时展示;对齐豆包)
      this.renderer?.renderPinyinSelector([], '');
      this.composingBridge?.update('');
      const symbols = SymbolData.key1Symbols.map((it: string) => new Candidate(it, 0, 0, false, '', true));
      this.renderer?.renderCandidates('', symbols, this.layoutSwitchText());
    } else if (this.chineseMode && this.lastWord !== undefined && !this.isPasswordField()) {
      // 密码框:不展示句子联想(隐私),避免泄露上文用词
      const lastWord: string = this.lastWord;
      this.renderer?.renderPinyinSelector([], '');
      this.composingBridge?.update('');
      // 标点联想 v2(头部注入,仅中文):取得到上文以文本判定为唯一事实源;
      // 取不到上文走词法规则 + punctConsumedFor 兜底防重复
      let puncts: Candidate[] = [];
      const bt = this.host.textBeforeCursor(64);
      if (bt.length > 0) {
        puncts = PunctuationSuggestion.suggestions(lastWord, bt)
          .map((it: string) => new Candidate(it, 0, 0, false, '', false, true));
      } else if (this.punctConsumedFor !== lastWord) {
        puncts = PunctuationSuggestion.suggestions(lastWord, '')
          .map((it: string) => new Candidate(it, 0, 0, false, '', false, true));
      }
      const emojis = EmojiData.associations(lastWord).map((it: string) => new Candidate(it, 0, 0, true));
      this.renderer?.renderCandidates('', puncts.concat(emojis).concat(this.engine.associations(lastWord)),
        this.layoutSwitchText());
    } else {
      this.renderer?.renderPinyinSelector([], '');
      this.composingBridge?.update('');
      this.renderer?.renderCandidates('', [], this.layoutSwitchText());
    }
  }

  /** 打字时把 emoji 混进候选(业界做法):命中首选词的 emoji 映射就插到首选词之后。 */
  private injectEmoji(cands: Candidate[]): Candidate[] {
    if (cands.length === 0 || this.isPasswordField()) return cands;
    const emojis = EmojiData.associations(cands[0].word);
    if (emojis.length === 0) return cands;
    const out: Candidate[] = [cands[0]];
    emojis.forEach((it: string) => out.push(new Candidate(it, 0, 0, true)));
    for (let i = 1; i < cands.length; i++) out.push(cands[i]);
    return out;
  }

  consumeShift(): void {
    if (this.shiftOn && !this.capsLock) {
      this.shiftOn = false;
      this.renderer?.rebuildKeyboard();
    }
  }

  // 非中文强制 26 键式布局(T9 多击已废弃);nineGrid 偏好保留,切回中文自动还原九宫格
  layoutState(): LayoutState {
    return new LayoutState(this.chineseMode, this.chineseMode && this.nineGrid, this.symbolPage, this.numberPage,
      this.symbolPageIndex, this.inputLang, this.nextModeLabel());
  }

  isEmojiPage(): boolean {
    return this.emojiPage;
  }

  isToolsPage(): boolean {
    return this.toolsPage;
  }

  recentEmojis(): string[] {
    return this.host.recentEmojis();
  }

  /** 齿轮:打开/关闭工具子页(不加高面板,替换键区)。 */
  openTools(): void {
    this.discardComposing();
    this.lastWord = undefined;
    this.toolsPage = true;
    this.emojiPage = false;
    this.clipPage = false;
    this.symbolPage = false;
    this.numberPage = false;
    this.symBoardPage = false;
    this.renderer?.rebuildKeyboard();
    this.refreshCandidates();
  }

  isSymBoardPage(): boolean {
    return this.symBoardPage;
  }

  recentSymbols(): string[] {
    return this.host.recentSymbols();
  }

  /** 分类符号板选中:智能配对上屏 + 记入最近使用(键盘/语音共用存储)。 */
  selectSymbol(symbol: string): void {
    this.host.onKeyFeedback();
    const closing = SmartPunctuation.closingFor(symbol);
    if (closing !== undefined) {
      this.host.onCommitPair(symbol, closing);
    } else {
      this.host.onCommit(symbol);
    }
    this.host.recordRecentSymbol(symbol);
    // 【符号板单击回跳】对齐搜狗"更多符号"面板:点选即回到进入前的输入布局
    if (this.symBoardPage) {
      this.symBoardPage = false;
      this.renderer?.rebuildKeyboard();
    }
    this.refreshCandidates();
  }

  /** 工具子页里的动作:切布局 / emoji / 剪贴板 / 俄语 / 韩语键盘;完成后关闭工具页。 */
  runTool(tool: string): void {
    this.toolsPage = false;
    if (tool === 'layout') {
      this.toggleLayout();
    } else if (tool === 'emoji') {
      this.emojiPage = true;
      this.renderer?.rebuildKeyboard();
      this.refreshCandidates();
    } else if (tool === 'clip') {
      if (!this.isPasswordField()) {
        this.clipPage = true;
      }
      this.renderer?.rebuildKeyboard();
      this.refreshCandidates();
    } else if (tool === 'lang_ru') {
      // 已在该语种 → 回语言组默认键盘(中英组回中/英,俄韩语境回对应语种)
      this.setLanguage(this.inputLang === InputLang.RU ? this.host.groupDefaultLang() : InputLang.RU);
    } else if (tool === 'lang_ko') {
      this.setLanguage(this.inputLang === InputLang.KO ? this.host.groupDefaultLang() : InputLang.KO);
    } else {
      this.renderer?.rebuildKeyboard();
      this.refreshCandidates();
    }
  }

  isClipPage(): boolean {
    return this.clipPage;
  }

  clipboardHistory(): string[] {
    return this.host.clipboardHistory();
  }

  quickPhrases(): string[] {
    return this.host.quickPhrases();
  }

  removeClipboardItem(item: string): void {
    this.host.removeClipboardItem(item);
  }

  clearClipboard(): void {
    this.host.clearClipboard();
  }

  /** 选中剪贴板/快捷短语:上屏(不写词典)。 */
  selectClip(text: string): void {
    this.host.onKeyFeedback();
    this.host.onCommit(text);
  }

  /** 选中 emoji:上屏 + 记录最近(不写拼音用户词典)。 */
  selectEmoji(emoji: string): void {
    this.host.onKeyFeedback();
    this.host.onCommit(emoji);
    this.host.recordRecentEmoji(emoji);
  }

  isShiftActive(): boolean {
    return this.shiftOn;
  }

  isCapsLock(): boolean {
    return this.capsLock;
  }

  isChineseMode(): boolean {
    return this.chineseMode;
  }

  currentLang(): InputLang {
    return this.inputLang;
  }

  returnVoiceText(): string {
    return this.host.localize(KbStr.RETURN_VOICE);
  }

  // 布局切换(26↔九宫格)仅对中文有意义;英/俄/韩隐藏该按钮(返回空串)
  layoutSwitchText(): string {
    if (!this.chineseMode) return '';
    return this.nineGrid ? this.host.localize(KbStr.QWERTY) : this.host.localize(KbStr.NINEGRID);
  }

  enterKeyLabel(): string {
    return this.host.enterKeyLabel();
  }

  canUndo(): boolean {
    return this.host.canUndo();
  }

  handleKey(spec: KeySpec): void {
    if (this.inputBlocked) return;
    this.host.onKeyFeedback();
    // 1 键符号候选态:除再次点 1 键外,任何按键都先退出(点选候选不走此入口,可连点)
    if (spec.type !== KeyType.SYM_CANDS) {
      this.symCandidateMode = false;
    }
    switch (spec.type) {
      // shiftValue:韩语双辅音/复合元音(ㅂ→ㅃ);拉丁/西里尔大小写由策略内部处理
      case KeyType.LETTER: {
        this.onComposingKeystroke();
        this.strategy.onAlpha(this.shiftActive && spec.shiftValue !== undefined ? spec.shiftValue : spec.main);
        break;
      }
      case KeyType.T9: { // 新数字进待定段,锁定段保持
        this.onComposingKeystroke();
        const v = spec.value;
        if (v === undefined) return;
        this.strategy.onAlpha(v);
        break;
      }
      case KeyType.DELETE:
        this.doDelete();
        break;
      case KeyType.SPACE:
        this.onSpace();
        break;
      case KeyType.ENTER:
        this.onEnter();
        break;
      case KeyType.SHIFT:
        this.onShift();
        break;
      case KeyType.LANG:
        this.toggleLanguage();
        break;
      case KeyType.LAYOUT:
        this.toggleLayout();
        break;
      // 模式轮换键(全布局常驻):中文九宫格→中文26键→英文→俄语→韩语 循环
      case KeyType.MODE_CYCLE:
        this.cycleMode();
        break;
      // 分类符号板(最近/中文/英文/括号/数学/序号/货币/箭头)
      case KeyType.SYM_BOARD: {
        this.discardComposing();
        this.lastWord = undefined;
        this.symBoardPage = true;
        this.symbolPage = false;
        this.numberPage = false;
        this.emojiPage = false;
        this.clipPage = false;
        this.renderer?.onEnterSymBoard();
        this.renderer?.rebuildKeyboard();
        this.refreshCandidates();
        break;
      }
      // 手动进数字页 → 会话内粘性(问题3:验证码逐格填充,焦点跳转后仍保持数字键盘)
      case KeyType.NUM: {
        this.discardComposing();
        this.lastWord = undefined;
        this.numberPage = true;
        this.stickyNumberPage = true;
        this.symbolPage = false;
        this.symBoardPage = false;
        this.renderer?.rebuildKeyboard();
        this.refreshCandidates();
        break;
      }
      case KeyType.SYMBOL: {
        this.discardComposing();
        this.lastWord = undefined;
        this.symbolPage = true;
        this.numberPage = false;
        this.symBoardPage = false;
        this.symbolPageIndex = 0;
        this.renderer?.rebuildKeyboard();
        this.refreshCandidates();
        break;
      }
      // 手动回字母页 → 解除数字页粘性
      case KeyType.ALPHA: {
        this.symbolPage = false;
        this.numberPage = false;
        this.stickyNumberPage = false;
        this.emojiPage = false;
        this.clipPage = false;
        this.toolsPage = false;
        this.symBoardPage = false;
        this.renderer?.rebuildKeyboard();
        this.refreshCandidates();
        break;
      }
      case KeyType.EMOJI: {
        this.discardComposing();
        this.lastWord = undefined;
        this.emojiPage = true;
        this.clipPage = false;
        this.symbolPage = false;
        this.numberPage = false;
        this.symBoardPage = false;
        this.renderer?.rebuildKeyboard();
        this.refreshCandidates();
        break;
      }
      case KeyType.CLIP: {
        if (!this.isPasswordField()) {
          this.discardComposing();
          this.lastWord = undefined;
          this.clipPage = true;
          this.emojiPage = false;
          this.symbolPage = false;
          this.numberPage = false;
          this.symBoardPage = false;
          this.renderer?.rebuildKeyboard();
          this.refreshCandidates();
        }
        break;
      }
      case KeyType.SYM_PAGE: {
        this.symbolPageIndex = this.symbolPageIndex === 0 ? 1 : 0;
        this.renderer?.rebuildKeyboard();
        break;
      }
      // 9 宫格 1 键(@#):候选栏出固定高频符号候选(对齐豆包;test_key1_symbols.py 模型)
      case KeyType.SYM_CANDS: {
        this.discardComposing();
        this.symCandidateMode = true;
        this.refreshCandidates();
        break;
      }
      case KeyType.SYM_CHAR: {
        this.discardComposing();
        const ch = spec.value ?? spec.main;
        const closing = SmartPunctuation.closingFor(ch);
        if (closing !== undefined) {
          this.host.onCommitPair(ch, closing);
        } else {
          this.host.onCommit(ch);
        }
        // 标点不清空 lastWord:保留句子联想上下文(修联想断链)
        // (v2:标点联想抑制改由 host.textBeforeCursor 实时判定,本分支零改动)
        // 【符号页单击回跳】对齐搜狗/百度/豆包:符号页点一个符号上屏即回到进入前的
        // 输入布局(inputLang/nineGrid 从未被符号页改动,清页即还原);数字例外——
        // 首行 1-0 常用于连续输入年份/金额(test_symbol_autoreturn.py 模型)。
        if (this.symbolPage && !(ch.length === 1 && ch >= '0' && ch <= '9')) {
          this.symbolPage = false;
          this.symbolPageIndex = 0;
          this.renderer?.rebuildKeyboard();
        }
        this.refreshCandidates();
        break;
      }
      case KeyType.SYLLABLE: {
        // 仅 26 键中文的分词键('分隔音节);9 宫格已改用标点键,不再走此分支
        if (this.nineGrid) {
          if (this.composing.isNotEmpty()) {
            const cands = this.currentCandidates();
            if (cands.length > 0) this.selectCandidate(cands[0]);
          }
        } else if (this.chineseMode) {
          this.composing.append("'");
          this.refreshCandidates();
        }
        break;
      }
      case KeyType.UNDO:
        this.host.undoLastCommit();
        break;
      case KeyType.GAP:
        break;
      default:
        break;
    }
  }

  handleLongPress(spec: KeySpec): void {
    if (this.inputBlocked) return;
    // 长按语种轮换已取消(不可发现):语种/布局切换统一走 MODE_CYCLE 常驻轮换键 + 工具页磁贴
    const v = spec.longValue;
    if (v === undefined) return;
    this.host.onKeyFeedback();
    this.discardComposing();
    this.lastWord = undefined;
    // 长按字母(俄语 е→ё)跟随 shift 大小写;数字/符号不受影响
    // (Kotlin isLetter() 等价判定:有大小写差异的单字符;无大小写字符 uppercase 后不变,行为一致)
    const isLetter = v.length === 1 && v.toLowerCase() !== v.toUpperCase();
    const out = this.shiftActive && isLetter ? v.toUpperCase() : v;
    this.host.onCommit(out);
    this.consumeShift();
    this.refreshCandidates();
  }

  selectCandidate(c: Candidate): void {
    if (c.isPunct) {
      // 标点联想候选:直接上屏(不配对)、不学习、保 lastWord(联想链不断)、
      // 同一 lastWord 不再重复推荐标点(词语联想继续)。
      this.host.onCommit(c.word);
      this.punctConsumedFor = this.lastWord;
      this.refreshCandidates();
      return;
    }
    if (c.isSymbol) {
      // 1 键符号候选:括号/书名号成套插入(光标后无文字才成套,有文字只插前半;
      // 后半直接上屏);不写词典、不改 lastWord(联想链不断);列表保持可连点。
      const closing = SmartPunctuation.closingFor(c.word);
      if (closing !== undefined && !this.host.hasTextAfterCursor()) {
        this.host.onCommitPair(c.word, closing);
      } else {
        this.host.onCommit(c.word);
      }
      this.refreshCandidates();
      return;
    }
    if (c.isEmoji) {
      this.host.onCommit(c.word);
      this.host.recordRecentEmoji(c.word);
      // 选 emoji = 放弃当前拼音串(emoji 是该词候选的替代);不改 lastWord(联想链不断)
      this.composing.setLength(0);
      this.sessionReset();
      this.refreshCandidates();
      return;
    }
    this.host.onCommit(c.word);
    // 密码框:不写用户词典/不调频(隐私合规)
    if (!this.isPasswordField()) this.engine.learnSequence(this.lastWord ?? null, c.word);
    this.lastWord = c.word;
    // 逐词消耗:消耗该候选的 matchedLen(T9 里拼音长度==数字位数),保留剩余继续打下一词。
    // 如 237449 选「测试」(消耗23744)→ 剩「9」继续打「仪」;残留只是暂留,用户可删。
    const consumedLen = Math.min(c.matchedLen, this.composing.length);
    // 锁定栈从头对齐扣减:已锁定的剩余音节保持锁定,选词后选择器不再重弹(问题2)
    this.t9ConsumeLocked(consumedLen);
    // 组词会话:记录本次消耗的拼音段(T9 用候选实际读音,26 键用输入字母)
    let consumedPinyin: string;
    if (this.t9Active) {
      consumedPinyin = c.pinyin.length > 0 && c.pinyin.length === consumedLen ? c.pinyin : '';
    } else {
      consumedPinyin = this.composing.substring(0, consumedLen).split("'").join('');
    }
    this.sessionRecordPick(c, consumedPinyin);
    const remain = c.matchedLen >= this.composing.length ? '' : this.composing.substring(c.matchedLen);
    this.composing.setLength(0);
    this.composing.append(remain);
    if (this.composing.isEmpty()) this.sessionMaybeLearn();
    this.refreshCandidates();
  }

  /** 空格滑动移光标:仅在无 composing 时移动文档光标。 */
  moveCursor(steps: number): void {
    if (this.inputBlocked || this.composing.isNotEmpty()) return;
    this.lastWord = undefined;
    this.host.onMoveCursor(steps);
  }

  /** 长按候选删词:加入黑名单,候选不再出现(emoji/密码框不处理)。 */
  forgetCandidate(c: Candidate): void {
    if (c.isEmoji || this.isPasswordField() || c.word.length === 0) return;
    this.engine.forget(c.word);
    this.refreshCandidates();
  }

  returnToVoice(): void {
    this.host.onReturnToVoice();
  }

  onMicRecordStart(): void {
    this.host.onKeyboardMicStart();
  }

  onMicRecordEnd(): void {
    this.host.onKeyboardMicStop();
  }

  toggleLayout(): void {
    this.discardComposing();
    this.nineGrid = !this.nineGrid;
    this.host.persistNineGrid(this.nineGrid);
    this.composing.setLength(0);
    this.symbolPage = false;
    this.numberPage = false;
    this.stickyNumberPage = false;
    this.emojiPage = false;
    this.clipPage = false;
    this.toolsPage = false;
    this.symBoardPage = false;
    this.lastWord = undefined;
    this.strategy = this.pickStrategy();
    this.strategy.reset();
    this.renderer?.rebuildKeyboard();
    this.refreshCandidates();
  }

  onDeletePressDown(): void {
    if (this.inputBlocked) return;
    this.host.onKeyFeedback();
    this.doDelete();
    this.deleteRepeating = true;
    this.deleteTimer = setTimeout(this.deleteRunnable, 380);
  }

  onDeletePressUp(): void {
    this.deleteRepeating = false;
    if (this.deleteTimer !== -1) {
      clearTimeout(this.deleteTimer);
      this.deleteTimer = -1;
    }
  }

  private doDelete(): void {
    this.symCandidateMode = false; // 长按连删直呼此处,不经 handleKey
    // 韩语组字态:逐 jamo 拆解(닭→달→다→ㄷ),拆完再走文档删除
    if (this.strategy.onDelete()) return;
    // 9 宫格:回退键先 LIFO 撤销上一个点选的音节(问题2:连续回退逐个重选,与脚本验证模型一致);
    // 锁定栈空才删数字
    if (this.t9Active && this.composing.isNotEmpty()) {
      if (this.t9LockedSyllables.length > 0) {
        this.t9LockedSyllables.pop();
        this.refreshCandidates();
        return;
      }
      this.composing.setLength(this.composing.length - 1);
      this.refreshCandidates();
      return;
    }
    if (this.composing.isNotEmpty()) {
      this.composing.setLength(this.composing.length - 1);
      this.refreshCandidates();
    } else {
      this.lastWord = undefined;
      this.sessionReset();
      this.host.onDeleteBeforeCursor();
      this.refreshCandidates();
    }
  }

  private onSpace(): void {
    if (this.composing.isNotEmpty()) {
      const cands = this.currentCandidates();
      if (cands.length > 0) {
        this.selectCandidate(cands[0]);
        return;
      }
    }
    this.strategy.flush(); // 韩语:先定稿组合中音节再上屏空格
    // 空格不清空 lastWord:保留句子联想上下文
    this.host.onCommit(' ');
    this.refreshCandidates();
  }

  private onEnter(): void {
    if (this.composing.isNotEmpty()) {
      const cands = this.currentCandidates();
      if (cands.length > 0) {
        this.selectCandidate(cands[0]);
        return;
      }
    }
    this.strategy.flush();
    this.lastWord = undefined;
    this.host.onEnter();
    this.refreshCandidates();
  }

  private onShift(): void {
    if (this.capsLock) {
      this.capsLock = false;
      this.shiftOn = false;
    } else if (this.shiftOn) {
      this.capsLock = true;
    } else {
      this.shiftOn = true;
    }
    this.renderer?.rebuildKeyboard();
  }

  /**
   * LANG 键轮换序列:中英为核心恒在;App 界面语言为俄/韩时对应语种加入环首(该语境下是主输入语言);
   * 用户从工具页临时进入俄/韩键盘时,该语种也入环(可一键轮回中英)。
   * 中英组用户看到的仍是纯 中↔EN 两态,与旧行为完全一致。
   */
  private langRing(): InputLang[] {
    const ring: InputLang[] = [];
    const groupDef = this.host.groupDefaultLang();
    if (groupDef === InputLang.RU || groupDef === InputLang.KO) ring.push(groupDef);
    if ((this.inputLang === InputLang.RU || this.inputLang === InputLang.KO) && !ring.includes(this.inputLang)) {
      ring.push(this.inputLang);
    }
    ring.push(InputLang.ZH);
    ring.push(InputLang.EN);
    return ring;
  }

  private toggleLanguage(): void {
    const ring = this.langRing();
    const next = ring[(ring.indexOf(this.inputLang) + 1) % ring.length];
    this.setLanguage(next);
  }

  /**
   * 模式轮换键(问题3:替代不可发现的长按切换):布局+语种都算模式,循环序列
   * 中文九宫格 → 中文26键 → 英文 → 俄语 → 韩语 → 中文九宫格…
   * 该键在所有打字布局常驻(含俄/韩),保证任何模式都能继续轮换,业务闭环。
   */
  private modeRing(): InputLang[] {
    // **只循环语言**(中文九宫格 → 英文 → 俄语 → 韩语 → 中文),中文永远沿用记住的布局。
    // 2026-07 修复:旧环把 [中九,中26,英,俄,韩] 串一起,中九→英要经过中26 并 persistNineGrid(false),
    // 之后 LANG 切回中文就停在中26(反人类)。语言与布局解耦(对齐搜狗/Gboard):
    // 语言切换绝不改中文布局偏好;九宫格↔26键由工具页布局磁贴独立切换(见 toggleLayout)。
    return [InputLang.ZH, InputLang.EN, InputLang.RU, InputLang.KO];
  }

  cycleMode(): void {
    const ring = this.modeRing();
    let idx = ring.indexOf(this.inputLang);
    if (idx < 0) {
      idx = 0;
    }
    const next = ring[(idx + 1) % ring.length];
    this.discardComposing();
    this.inputLang = next;
    // 语言/布局正交:切语言绝不动 nineGrid(切回中文自动用记住的九宫格/26键偏好)。
    this.autoEnglishOverride = false;
    this.host.persistInputLang(next);
    this.composing.setLength(0);
    this.symbolPage = false;
    this.numberPage = false;
    this.emojiPage = false;
    this.clipPage = false;
    this.toolsPage = false;
    this.symBoardPage = false;
    this.lastWord = undefined;
    this.strategy = this.pickStrategy();
    this.strategy.reset();
    this.renderer?.rebuildKeyboard();
    this.refreshCandidates();
  }

  /** 轮换键下一模式短标签(画在图标下方,预告下一站语言,用户可预期)。 */
  nextModeLabel(): string {
    const ring = this.modeRing();
    let idx = ring.indexOf(this.inputLang);
    if (idx < 0) {
      idx = 0;
    }
    return ring[(idx + 1) % ring.length].keyLabel;
  }

  /** 切换输入语种(LANG 环 / 工具页直达共用):手动选择写回偏好,解除自动接管。 */
  setLanguage(lang: InputLang): void {
    this.discardComposing();
    this.inputLang = lang;
    // 用户手动切语种:解除英文框自动切换接管,且写回用户偏好(与业界一致,手动选择优先)
    this.autoEnglishOverride = false;
    this.host.persistInputLang(lang);
    this.composing.setLength(0);
    this.symbolPage = false;
    this.numberPage = false;
    this.emojiPage = false;
    this.clipPage = false;
    this.toolsPage = false;
    this.symBoardPage = false;
    this.lastWord = undefined;
    this.strategy = this.pickStrategy();
    this.strategy.reset();
    this.renderer?.rebuildKeyboard();
    this.refreshCandidates();
  }

  /** 切换模式时丢弃拼音组合串(不上屏);韩语组合音节例外——已在目标框可见,定稿保留(业界一致)。 */
  private discardComposing(): void {
    this.strategy.flush();
    this.t9LockedSyllables.length = 0;
    this.toolsPage = false;
    // 1 键符号候选态一并退出(不经 handleKey 的入口);SYM_CANDS 键自身在 discard 之后才置位
    this.symCandidateMode = false;
    this.sessionReset();
    if (this.composing.isNotEmpty()) {
      this.composing.setLength(0);
      this.composingBridge?.clear();
    }
  }

  /**
   * 输入框切换/键盘拉起时的状态复位(问题3:模式保持的核心决策点,对齐 Gboard/搜狗)。
   *  - 数字/电话框:自动进数字键盘页(输入框类型感知,优先级最高)。
   *  - 会话内粘性:用户上个框手动切了数字页(验证码场景),焦点跳到下一格继续保持。
   *  - 邮箱/URI/密码框:自动切英文模式(仅会话内,不写用户偏好);离开后恢复用户偏好。
   *  - 其余状态(composing/符号页/工具页)一律清理,不残留。
   */
  reset(): void {
    this.t9LockedSyllables.length = 0;
    this.symCandidateMode = false;
    this.sessionReset();
    this.strategy.flush();
    this.composing.setLength(0);
    this.strategy.reset();
    this.symbolPage = false;
    this.numberPage = false;
    this.emojiPage = false;
    this.clipPage = false;
    this.toolsPage = false;
    this.symBoardPage = false;
    this.symbolPageIndex = 0;
    this.lastWord = undefined;
    this.composingBridge?.clear();
    // App 界面语言跨组切换(中英组↔俄↔韩):清空全部模式暂存,回到新语言组默认键盘。
    // 组内互切(中英界面语言互换)不触发,粘性与语种状态一直生效。
    if (this.host.consumeLangGroupChange()) {
      this.stickyNumberPage = false;
      this.autoEnglishOverride = false;
      this.inputLang = this.host.inputLangDefault();
      this.strategy = this.pickStrategy();
      this.strategy.reset();
    }
    if (this.host.isNumericField() || this.stickyNumberPage) this.numberPage = true;
    // 英文框自动切英文;离开英文框时恢复用户偏好(autoEnglishOverride 标记"当前英文态是自动切的")
    if (this.host.isEnglishField()) {
      if (this.inputLang !== InputLang.EN) {
        this.inputLang = InputLang.EN;
        this.autoEnglishOverride = true;
        this.strategy = this.pickStrategy();
      }
    } else if (this.autoEnglishOverride) {
      this.autoEnglishOverride = false;
      const prefer = this.host.inputLangDefault();
      if (this.inputLang !== prefer) {
        this.inputLang = prefer;
        this.strategy = this.pickStrategy();
      }
    }
    this.renderer?.rebuildKeyboard();
    this.refreshCandidates();
  }

  /** 键盘会话结束(键盘收起):清除会话级粘性,下次拉起回归输入框类型感知 + 用户偏好。 */
  onSessionEnd(): void {
    this.strategy.flush();
    this.stickyNumberPage = false;
    if (this.autoEnglishOverride) {
      this.autoEnglishOverride = false;
      const prefer = this.host.inputLangDefault();
      if (this.inputLang !== prefer) {
        this.inputLang = prefer;
        this.strategy = this.pickStrategy();
      }
    }
  }

  onEngineLoadState(state: PinyinLoadState, detail?: string): void {
    const blocked = state === PinyinLoadState.LOADING || state === PinyinLoadState.FAILED;
    this.setInputBlocked(blocked || this.inputBlocked);
    this.renderer?.renderEngineState(state, detail);
  }
}
