// 对齐 Android: keyboard/typing/SymbolData.kt(数据表全量搬运,一个字符不少)

/** 分类(最近除外——由 TypingPreferences.recentSymbols 动态提供)。 */
export class SymbolCategory {
  readonly id: string;
  readonly items: string[];

  constructor(id: string, items: string[]) {
    this.id = id;
    this.items = items;
  }
}

/**
 * 分类符号板数据(对齐搜狗/百度/Gboard 符号面板课题调研结论):
 * 最近/中文/英文/括号/数学/序号/货币/箭头。数据经 scratch-keyboard-verify/test_symbols.py 验证
 * (类内无重复、关键符号覆盖、LRU 行为),键盘模式与语音模式共用。
 */
export class SymbolData {

  /**
   * 9 宫格 1 键(@#)的固定高频符号候选(对齐豆包,顺序固定不做权重;
   * 经 scratch-keyboard-verify/test_key1_symbols.py 验证,与安卓/iOS 逐项一致)。
   * 括号/书名号成套:点前半且光标后无文字 → 成套插入光标居中;有文字只插前半;后半直接上屏。
   */
  static readonly key1Symbols: string[] = ['#', '@', '（', '）', '*', '-', '+', '。', '～', '、', '《', '》', '/'];

  static readonly categories: SymbolCategory[] = [
    new SymbolCategory('zh', [
      '，', '。', '？', '！', '、', '；', '：', '“', '”', '‘', '’',
      '（', '）', '【', '】', '《', '》', '〈', '〉', '「', '」', '『', '』',
      '…', '—', '～', '·', '﹏', '＿', '￥'
    ]),
    new SymbolCategory('en', [
      ',', '.', '?', '!', ';', ':', "'", '"', '(', ')', '[', ']',
      '{', '}', '<', '>', '@', '#', '$', '%', '^', '&', '*', '-',
      '_', '+', '=', '/', '\\', '|', '~', '`'
    ]),
    new SymbolCategory('bracket', [
      '（', '）', '(', ')', '［', '］', '[', ']', '｛', '｝', '{', '}',
      '〈', '〉', '《', '》', '「', '」', '『', '』', '【', '】', '〔', '〕',
      '«', '»', '‹', '›'
    ]),
    new SymbolCategory('math', [
      '+', '-', '×', '÷', '=', '≠', '≈', '<', '>', '≤', '≥', '±',
      '√', '∞', '%', '‰', '°', 'π', '∑', '∫', 'Δ', '∈', '∪', '∩',
      '∴', '∵', '⊥', '∥', '∠', '½', '¼', '¾', '²', '³'
    ]),
    new SymbolCategory('num', [
      '①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩',
      '⑴', '⑵', '⑶', '⑷', '⑸', '⑹', '⑺', '⑻', '⑼', '⑽',
      'Ⅰ', 'Ⅱ', 'Ⅲ', 'Ⅳ', 'Ⅴ', 'Ⅵ', 'Ⅶ', 'Ⅷ', 'Ⅸ', 'Ⅹ',
      '㈠', '㈡', '㈢', '㈣', '㈤'
    ]),
    new SymbolCategory('currency', [
      '￥', '¥', '$', '€', '£', '¢', '₩', '₽', '₹', '฿', '₫', '₴'
    ]),
    new SymbolCategory('arrow', [
      '←', '→', '↑', '↓', '↔', '↕', '↖', '↗', '↘', '↙', '⇐', '⇒',
      '★', '☆', '♥', '♡', '●', '○', '■', '□', '◆', '◇', '▲', '△',
      '※', '§', '№', '℃', '℉', '©', '®', '™'
    ])
  ];

  static readonly RECENT_ID: string = 'recent';

  /** 分类标签(5 语种列,繁体/粤语共用繁体列;自包含避免 MobileStrings 膨胀)。lang: zh/zh-Hant/yue/en/ru/ko。 */
  static label(id: string, lang: string): string {
    let i = 0;
    if (lang === 'en') {
      i = 1;
    } else if (lang === 'ru') {
      i = 2;
    } else if (lang === 'ko') {
      i = 3;
    } else if (lang === 'zh-Hant' || lang === 'yue') {
      i = 4;
    }
    if (id === SymbolData.RECENT_ID) return ['最近', 'Recent', 'Недавние', '최근', '最近'][i];
    if (id === 'zh') return ['中文', 'Chinese', 'Кит.', '중문', '中文'][i];
    if (id === 'en') return ['英文', 'English', 'Англ.', '영문', '英文'][i];
    if (id === 'bracket') return ['括号', 'Brackets', 'Скобки', '괄호', '括號'][i];
    if (id === 'math') return ['数学', 'Math', 'Матем.', '수학', '數學'][i];
    if (id === 'num') return ['序号', 'Numbering', 'Нумерация', '번호', '序號'][i];
    if (id === 'currency') return ['货币', 'Currency', 'Валюта', '통화', '貨幣'][i];
    if (id === 'arrow') return ['箭头', 'Arrows', 'Стрелки', '화살표', '箭頭'][i];
    return id;
  }
}
