/**
 * 模糊音 + 容错纠错(引擎层无状态工具)。
 * 移植自 Android: keyboard/pinyin/PinyinFuzzy.kt(逐行对齐)。纯逻辑,不依赖任何 @ohos/@kit 模块。
 *
 * 设计对齐 RIME/搜狗:模糊音与纠错分两层、各自可控。
 *  - 模糊音:把一个合法音节派生出"等价音节集合"(平翘舌、前后鼻音、边鼻音…),按开关启用。
 *  - 纠错:对单个音节做编辑距离≤1(替换/插入/删除/邻键)还原成合法音节,仅在精确/模糊不足时兜底。
 *
 * 注意:模糊音派生只对"合法音节"做,声母/韵母规则覆盖 i/u 介音变体
 *  (an/ang 规则天然覆盖 ian/iang、uan/uang;故无需单列)。
 */

/** 模糊音开关集合(默认全关,由用户在设置页逐项开启)。对齐 Kotlin PinyinFuzzy.Settings。 */
export class PinyinFuzzySettings {
  zZh: boolean = false;   // z ↔ zh
  cCh: boolean = false;   // c ↔ ch
  sSh: boolean = false;   // s ↔ sh
  lN: boolean = false;    // l ↔ n
  fH: boolean = false;    // f ↔ h
  rL: boolean = false;    // r ↔ l
  anAng: boolean = false; // an ↔ ang (含 ian/iang、uan/uang)
  enEng: boolean = false; // en ↔ eng
  inIng: boolean = false; // in ↔ ing
  correction: boolean = false; // 容错纠错(编辑距离≤1)

  get anyInitial(): boolean {
    return this.zZh || this.cCh || this.sSh || this.lN || this.fH || this.rL;
  }

  get anyFinal(): boolean {
    return this.anAng || this.enEng || this.inIng;
  }

  get anyFuzzy(): boolean {
    return this.anyInitial || this.anyFinal;
  }
}

export class PinyinFuzzy {

  /** 邻键表(QWERTY),用于纠错的邻键替换。 */
  private static readonly neighbors: Map<string, string> = PinyinFuzzy.buildNeighbors();

  private static buildNeighbors(): Map<string, string> {
    const m = new Map<string, string>();
    m.set('q', 'wa'); m.set('w', 'qes'); m.set('e', 'wrd'); m.set('r', 'etf'); m.set('t', 'ryg');
    m.set('y', 'tuh'); m.set('u', 'yij'); m.set('i', 'uok'); m.set('o', 'ipl'); m.set('p', 'ol');
    m.set('a', 'qsz'); m.set('s', 'awdz x'); m.set('d', 'serfcx'); m.set('f', 'drtgvc');
    m.set('g', 'ftyhbv'); m.set('h', 'gyujnb'); m.set('j', 'huikmn'); m.set('k', 'jiolm');
    m.set('l', 'kop'); m.set('z', 'asx'); m.set('x', 'zsdc'); m.set('c', 'xdfv');
    m.set('v', 'cfgb'); m.set('b', 'vghn'); m.set('n', 'bhjm'); m.set('m', 'njk');
    return m;
  }

  /**
   * 把一个合法音节派生出模糊等价音节集合(含自身)。
   * 仅用于在候选查词时扩展;调用方需对模糊命中做降权。
   */
  static variants(syllable: string, s: PinyinFuzzySettings): Set<string> {
    if (!s.anyFuzzy || syllable.length === 0) {
      const single = new Set<string>();
      single.add(syllable);
      return single;
    }
    const set = new Set<string>();
    set.add(syllable);
    // ---- 声母 ----
    if (s.anyInitial) {
      const add = new Set<string>();
      const snapshot = Array.from(set);
      for (const v of snapshot) {
        // 双向:对每个开启的对,长前缀优先判定
        if (s.zZh) {
          if (v.startsWith('zh')) { add.add('z' + v.substring(2)); } else if (v.startsWith('z')) { add.add('zh' + v.substring(1)); }
        }
        if (s.cCh) {
          if (v.startsWith('ch')) { add.add('c' + v.substring(2)); } else if (v.startsWith('c')) { add.add('ch' + v.substring(1)); }
        }
        if (s.sSh) {
          if (v.startsWith('sh')) { add.add('s' + v.substring(2)); } else if (v.startsWith('s')) { add.add('sh' + v.substring(1)); }
        }
        if (s.lN) {
          if (v.startsWith('l')) { add.add('n' + v.substring(1)); } else if (v.startsWith('n')) { add.add('l' + v.substring(1)); }
        }
        if (s.fH) {
          if (v.startsWith('f')) { add.add('h' + v.substring(1)); } else if (v.startsWith('h')) { add.add('f' + v.substring(1)); }
        }
        if (s.rL) {
          if (v.startsWith('r')) { add.add('l' + v.substring(1)); } else if (v.startsWith('l')) { add.add('r' + v.substring(1)); }
        }
      }
      const addArr = Array.from(add);
      for (const a of addArr) { set.add(a); }
    }
    // ---- 韵母(前后鼻音) ----
    if (s.anyFinal) {
      const add = new Set<string>();
      const snapshot = Array.from(set);
      for (const v of snapshot) {
        if (s.anAng) {
          if (v.endsWith('ang')) { add.add(v.substring(0, v.length - 3) + 'an'); } else if (v.endsWith('an')) { add.add(v.substring(0, v.length - 2) + 'ang'); }
        }
        if (s.enEng) {
          if (v.endsWith('eng')) { add.add(v.substring(0, v.length - 3) + 'en'); } else if (v.endsWith('en')) { add.add(v.substring(0, v.length - 2) + 'eng'); }
        }
        if (s.inIng) {
          if (v.endsWith('ing')) { add.add(v.substring(0, v.length - 3) + 'in'); } else if (v.endsWith('in')) { add.add(v.substring(0, v.length - 2) + 'ing'); }
        }
      }
      const addArr = Array.from(add);
      for (const a of addArr) { set.add(a); }
    }
    return set;
  }

  /**
   * 对一个"非法音节"做编辑距离≤1 纠错,返回可能的合法音节(由 isSyllable 校验)。
   * 仅覆盖:邻键替换、漏字母(插入)、多字母(删除)。结果上限 8。
   */
  static corrections(token: string, isSyllable: (s: string) => boolean): string[] {
    if (token.length < 2 || token.length > 6) { return []; }
    const out = new Set<string>();
    const letters = 'abcdefghijklmnopqrstuvwxyz';
    // 删除一个字母
    for (let i = 0; i < token.length; i++) {
      const c = token.substring(0, i) + token.substring(i + 1);
      if (c.length >= 1 && isSyllable(c)) { out.add(c); }
    }
    // 替换为邻键
    for (let i = 0; i < token.length; i++) {
      const nb = PinyinFuzzy.neighbors.get(token.charAt(i)) ?? '';
      for (const n of nb) {
        if (n === ' ') { continue; }
        const c = token.substring(0, i) + n + token.substring(i + 1);
        if (isSyllable(c)) { out.add(c); }
      }
      if (out.size >= 8) { return Array.from(out); }
    }
    // 插入一个字母
    for (let i = 0; i <= token.length; i++) {
      for (const ch of letters) {
        const c = token.substring(0, i) + ch + token.substring(i);
        if (isSyllable(c)) { out.add(c); }
        if (out.size >= 8) { return Array.from(out); }
      }
    }
    return Array.from(out);
  }
}
