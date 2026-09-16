// 对齐 Android: keyboard/typing/SmartPunctuation.kt

/**
 * 智能标点:成对符号自动配对(输 "(" 自动补 ")" 并把光标放中间)。
 * 中英标点的全/半角自适应由布局层按 chineseMode 决定(见 KeyboardLayoutFactory),此处只管配对。
 */
export class SmartPunctuation {

  /** opening → closing。覆盖中英文括号、引号、书名号。 */
  private static buildPairs(): Map<string, string> {
    const m = new Map<string, string>();
    m.set('(', ')');
    m.set('（', '）');
    m.set('[', ']');
    m.set('【', '】');
    m.set('{', '}');
    m.set('「', '」');
    m.set('『', '』');
    m.set('<', '>');
    m.set('《', '》');
    m.set('“', '”');
    m.set('‘', '’');
    return m;
  }

  private static readonly pairs: Map<string, string> = SmartPunctuation.buildPairs();

  static closingFor(opening: string): string | undefined {
    return SmartPunctuation.pairs.get(opening);
  }

  static isPairOpening(s: string): boolean {
    return SmartPunctuation.pairs.has(s);
  }
}
