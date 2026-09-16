// 对齐 Android: keyboard/typing/KeyboardLayoutFactory.kt
import { InputLang, KbStr, KeySpec, KeyType, TypingKeyboardHost } from './KeyModels';

/**
 * 布局状态(Kotlin 嵌套 data class KeyboardLayoutFactory.LayoutState → ArkTS 独立类)。
 */
export class LayoutState {
  readonly chineseMode: boolean;
  readonly nineGrid: boolean;
  readonly symbolPage: boolean;
  readonly numberPage: boolean;
  readonly symbolPageIndex: number;
  readonly lang: InputLang;
  /** 模式轮换键的下一站短标签(画在循环图标下方,预告下一模式)。 */
  readonly nextModeLabel: string;

  constructor(chineseMode: boolean, nineGrid: boolean, symbolPage: boolean, numberPage: boolean,
    symbolPageIndex: number, lang?: InputLang, nextModeLabel?: string) {
    this.chineseMode = chineseMode;
    this.nineGrid = nineGrid;
    this.symbolPage = symbolPage;
    this.numberPage = numberPage;
    this.symbolPageIndex = symbolPageIndex;
    this.lang = lang ?? (chineseMode ? InputLang.ZH : InputLang.EN);
    this.nextModeLabel = nextModeLabel ?? '';
  }
}

/**
 * 键盘布局工厂(工厂模式)。按当前模式产出 [行[键]],不含状态或绘制。
 */
export class KeyboardLayoutFactory {
  private readonly host: TypingKeyboardHost;

  constructor(host: TypingKeyboardHost) {
    this.host = host;
  }

  build(state: LayoutState): KeySpec[][] {
    if (state.numberPage) return this.numberRows(state);
    if (state.symbolPage) return this.symbolRows(state);
    if (state.lang === InputLang.RU) return this.russianRows(state);
    if (state.lang === InputLang.KO) return this.koreanRows(state);
    if (state.nineGrid) return this.nineGridRows(state);
    return this.qwertyRows(state);
  }

  private langKey(state: LayoutState, weight: number): KeySpec {
    let label: string;
    if (state.lang === InputLang.ZH) {
      label = this.host.localize(KbStr.CH);
    } else if (state.lang === InputLang.EN) {
      label = this.host.localize(KbStr.EN);
    } else {
      label = state.lang.keyLabel;
    }
    return new KeySpec(KeyType.LANG, label, { weight: weight });
  }

  /**
   * 模式轮换键(问题3:替代"切26"和长按切语种):自绘循环箭头图标 + 下一模式短标签,
   * 全部打字布局(九宫格/26键/俄/韩)常驻同位,循环 中9→中26→EN→РУ→한。
   */
  private modeCycleKey(state: LayoutState, weight: number): KeySpec {
    return new KeySpec(KeyType.MODE_CYCLE, '', { sub: state.nextModeLabel, weight: weight });
  }

  private comma(state: LayoutState, weight: number): KeySpec {
    return new KeySpec(KeyType.SYM_CHAR, '，', { value: state.chineseMode ? '，' : ',', weight: weight });
  }

  private period(state: LayoutState, weight: number): KeySpec {
    return new KeySpec(KeyType.SYM_CHAR, '。', { value: state.chineseMode ? '。' : '.', weight: weight });
  }

  private qwertyRows(state: LayoutState): KeySpec[][] {
    const row1Long = '1234567890';
    const lettersWithLong = (s: string, longs?: string): KeySpec[] => {
      const out: KeySpec[] = [];
      for (let i = 0; i < s.length; i++) {
        const longValue = longs !== undefined && i < longs.length ? longs.charAt(i) : undefined;
        out.push(new KeySpec(KeyType.LETTER, s.charAt(i), { longValue: longValue }));
      }
      return out;
    };
    const row3: KeySpec[] = [];
    row3.push(new KeySpec(KeyType.SHIFT, '', { weight: 1.5 }));
    lettersWithLong('zxcvbnm').forEach((k: KeySpec) => row3.push(k));
    // 中文 26 键分词键(')收进 row3(对齐 iOS),把 row4 槽位让给模式轮换键
    if (state.chineseMode) row3.push(new KeySpec(KeyType.SYLLABLE, this.host.localize(KbStr.SYLLABLE), { weight: 1.0 }));
    row3.push(new KeySpec(KeyType.DELETE, '', { weight: 1.5 }));
    const row4: KeySpec[] = [
      this.langKey(state, 1.3),
      new KeySpec(KeyType.SYMBOL, '?123', { weight: 1.1 }),
      this.modeCycleKey(state, 0.95),
      new KeySpec(KeyType.SPACE, this.host.localize(KbStr.SPACE), { weight: 2.6 }),
      this.comma(state, 0.95),
      this.period(state, 0.95),
      new KeySpec(KeyType.ENTER, this.host.enterKeyLabel(), { weight: 1.4 })
    ];
    const row2: KeySpec[] = [new KeySpec(KeyType.GAP, '', { weight: 0.5 })];
    lettersWithLong('asdfghjkl').forEach((k: KeySpec) => row2.push(k));
    row2.push(new KeySpec(KeyType.GAP, '', { weight: 0.5 }));
    return [
      lettersWithLong('qwertyuiop', row1Long),
      row2,
      row3, row4
    ];
  }

  /**
   * 俄语 ЙЦУКЕН(标准移动端 3 行:11/11/9+shift+del,对齐 Gboard/iOS 系统俄语键盘)。
   * ё=长按 е,ъ=长按 ь(业界惯例:低频字母走长按不占键位)。
   */
  private russianRows(state: LayoutState): KeySpec[][] {
    const letters = (s: string, longs?: Map<string, string>): KeySpec[] => {
      const out: KeySpec[] = [];
      for (let i = 0; i < s.length; i++) {
        const ch = s.charAt(i);
        out.push(new KeySpec(KeyType.LETTER, ch, { longValue: longs?.get(ch) }));
      }
      return out;
    };
    const row3Longs = new Map<string, string>();
    row3Longs.set('ь', 'ъ');
    const row3: KeySpec[] = [];
    row3.push(new KeySpec(KeyType.SHIFT, '', { weight: 1.3 }));
    letters('ячсмитьбю', row3Longs).forEach((k: KeySpec) => row3.push(k));
    row3.push(new KeySpec(KeyType.DELETE, '', { weight: 1.3 }));
    const row4: KeySpec[] = [
      this.langKey(state, 1.3),
      new KeySpec(KeyType.SYMBOL, '?123', { weight: 1.1 }),
      this.modeCycleKey(state, 0.95),
      new KeySpec(KeyType.SPACE, this.host.localize(KbStr.SPACE), { weight: 2.6 }),
      this.comma(state, 0.95),
      this.period(state, 0.95),
      new KeySpec(KeyType.ENTER, this.host.enterKeyLabel(), { weight: 1.4 })
    ];
    const row1Longs = new Map<string, string>();
    row1Longs.set('е', 'ё');
    return [
      letters('йцукенгшщзх', row1Longs),
      letters('фывапролджэ'),
      row3, row4
    ];
  }

  /**
   * 韩语 2-set 두벌식(左辅音右元音,对齐 Gboard/iOS 系统韩语键盘)。
   * 双辅音/复合元音走 shift(ㅂ→ㅃ、ㅐ→ㅒ);复合元音 ㅘㅝㅢ 等由组字自动机连击合成。
   */
  private koreanRows(state: LayoutState): KeySpec[][] {
    const jamo = (s: string, shifts?: Map<string, string>): KeySpec[] => {
      const out: KeySpec[] = [];
      for (let i = 0; i < s.length; i++) {
        const ch = s.charAt(i);
        out.push(new KeySpec(KeyType.LETTER, ch, { shiftValue: shifts?.get(ch) }));
      }
      return out;
    };
    const row1Shift = new Map<string, string>();
    row1Shift.set('ㅂ', 'ㅃ');
    row1Shift.set('ㅈ', 'ㅉ');
    row1Shift.set('ㄷ', 'ㄸ');
    row1Shift.set('ㄱ', 'ㄲ');
    row1Shift.set('ㅅ', 'ㅆ');
    row1Shift.set('ㅐ', 'ㅒ');
    row1Shift.set('ㅔ', 'ㅖ');
    const row3: KeySpec[] = [];
    row3.push(new KeySpec(KeyType.SHIFT, '', { weight: 1.3 }));
    jamo('ㅋㅌㅊㅍㅠㅜㅡ').forEach((k: KeySpec) => row3.push(k));
    row3.push(new KeySpec(KeyType.DELETE, '', { weight: 1.3 }));
    const row4: KeySpec[] = [
      this.langKey(state, 1.3),
      new KeySpec(KeyType.SYMBOL, '?123', { weight: 1.1 }),
      this.modeCycleKey(state, 0.95),
      new KeySpec(KeyType.SPACE, this.host.localize(KbStr.SPACE), { weight: 2.6 }),
      this.comma(state, 0.95),
      this.period(state, 0.95),
      new KeySpec(KeyType.ENTER, this.host.enterKeyLabel(), { weight: 1.4 })
    ];
    const row2: KeySpec[] = [new KeySpec(KeyType.GAP, '', { weight: 0.5 })];
    jamo('ㅁㄴㅇㄹㅎㅗㅓㅏㅣ').forEach((k: KeySpec) => row2.push(k));
    row2.push(new KeySpec(KeyType.GAP, '', { weight: 0.5 }));
    return [
      jamo('ㅂㅈㄷㄱㅅㅛㅕㅑㅐㅔ', row1Shift),
      row2,
      row3, row4
    ];
  }

  private nineGridRows(state: LayoutState): KeySpec[][] {
    // 对齐豆包/搜狗:第1列逗号,分词键=数字1(右上角小数字),字母键显示对应数字 2-9,单独 0 键。
    return [
      [
        this.comma(state, 1.0),
        // 1 键位:@#(对齐豆包)——点击在候选栏出固定高频符号候选(SymbolData.key1Symbols),长按出数字 1
        new KeySpec(KeyType.SYM_CANDS, '@#', { sub: '1', longValue: '1', weight: 1.3 }),
        new KeySpec(KeyType.T9, 'ABC', { sub: '2', value: '2', longValue: '2', weight: 1.3 }),
        new KeySpec(KeyType.T9, 'DEF', { sub: '3', value: '3', longValue: '3', weight: 1.3 }),
        new KeySpec(KeyType.DELETE, '', { weight: 1.1 })
      ],
      [
        this.langKey(state, 1.0),
        new KeySpec(KeyType.T9, 'GHI', { sub: '4', value: '4', longValue: '4', weight: 1.3 }),
        new KeySpec(KeyType.T9, 'JKL', { sub: '5', value: '5', longValue: '5', weight: 1.3 }),
        new KeySpec(KeyType.T9, 'MNO', { sub: '6', value: '6', longValue: '6', weight: 1.3 }),
        new KeySpec(KeyType.SYMBOL, this.host.localize(KbStr.SYMBOL), { weight: 1.1 })
      ],
      [
        // 删「切26」布局键(已收进候选栏齿轮工具页);123 移左,0 键放最右(对齐豆包/搜狗)
        new KeySpec(KeyType.NUM, '123', { weight: 1.0 }),
        new KeySpec(KeyType.T9, 'PQRS', { sub: '7', value: '7', longValue: '7', weight: 1.3 }),
        new KeySpec(KeyType.T9, 'TUV', { sub: '8', value: '8', longValue: '8', weight: 1.3 }),
        new KeySpec(KeyType.T9, 'WXYZ', { sub: '9', value: '9', longValue: '9', weight: 1.3 }),
        new KeySpec(KeyType.SYM_CHAR, '0', { value: '0', weight: 1.0 })
      ],
      [
        // 模式轮换键(替代「切26」:布局+语种统一循环,全布局常驻,业务闭环)
        this.modeCycleKey(state, 1.0),
        this.period(state, 1.0),
        new KeySpec(KeyType.SPACE, this.host.localize(KbStr.SPACE), { weight: 3.2 }),
        new KeySpec(KeyType.ENTER, this.host.enterKeyLabel(), { weight: 1.3 })
      ]
    ];
  }

  private numberRows(state: LayoutState): KeySpec[][] {
    const n = (d: string): KeySpec => new KeySpec(KeyType.SYM_CHAR, d, { value: d });
    return [
      [n('1'), n('2'), n('3'), new KeySpec(KeyType.DELETE, '', { weight: 1 })],
      [n('4'), n('5'), n('6'), new KeySpec(KeyType.SYM_CHAR, '@', { value: '@' })],
      [n('7'), n('8'), n('9'), new KeySpec(KeyType.ENTER, this.host.enterKeyLabel(), { weight: 1 })],
      [
        new KeySpec(KeyType.ALPHA, state.chineseMode ? this.host.localize(KbStr.PINYIN) : this.host.localize(KbStr.ABC)),
        new KeySpec(KeyType.SYM_CHAR, '.', { value: '.' }),
        n('0'),
        this.comma(state, 1)
      ]
    ];
  }

  private readonly zhPunct1: string[] = ['，', '。', '？', '！', '：', '；', '、', '～', '…', '—'];
  private readonly zhPunct2: string[] = ['（', '）', '【', '】', '《', '》', '“', '”', '‘', '’'];
  private readonly enPunct1: string[] = ['@', '#', '$', '%', '&', '*', '-', '+', '(', ')'];
  private readonly enPunct2: string[] = ['_', '=', '/', '\\', '|', '~', '<', '>', '[', ']'];

  private symbolRows(state: LayoutState): KeySpec[][] {
    const chars = (list: string[]): KeySpec[] => list.map((it: string) => new KeySpec(KeyType.SYM_CHAR, it, { value: it }));
    const digits: KeySpec[] = [];
    const digitStr = '1234567890';
    for (let i = 0; i < digitStr.length; i++) {
      const d = digitStr.charAt(i);
      digits.push(new KeySpec(KeyType.SYM_CHAR, d, { value: d }));
    }
    let punctRow: string[];
    if (state.chineseMode) {
      punctRow = state.symbolPageIndex === 0 ? this.zhPunct1 : this.zhPunct2;
    } else {
      punctRow = state.symbolPageIndex === 0 ? this.enPunct1 : this.enPunct2;
    }
    const row3: KeySpec[] = [];
    row3.push(new KeySpec(KeyType.SYM_PAGE, state.symbolPageIndex === 0 ? '1/2' : '2/2', { weight: 1.5 }));
    chars(state.chineseMode ? ['·', '「', '」', '—', '%', '&'] : ['.', ',', '?', '!', "'", '"'])
      .forEach((k: KeySpec) => row3.push(k));
    row3.push(new KeySpec(KeyType.DELETE, '', { weight: 1.5 }));
    const row4: KeySpec[] = [
      new KeySpec(KeyType.ALPHA, state.chineseMode ? this.host.localize(KbStr.PINYIN) : this.host.localize(KbStr.ABC),
        { weight: 1.5 }),
      // 分类符号板入口(最近/数学/序号/货币/箭头等全量分类,对齐搜狗「更多符号」)
      new KeySpec(KeyType.SYM_BOARD, '√π', { weight: 1.0 }),
      new KeySpec(KeyType.EMOJI, '😊', { weight: 1.0 }),
      new KeySpec(KeyType.CLIP, '📋', { weight: 1.0 }),
      new KeySpec(KeyType.SPACE, this.host.localize(KbStr.SPACE), { weight: 2.7 }),
      this.comma(state, 1.0),
      new KeySpec(KeyType.ENTER, this.host.enterKeyLabel(), { weight: 1.6 })
    ];
    return [digits, chars(punctRow), row3, row4];
  }
}
