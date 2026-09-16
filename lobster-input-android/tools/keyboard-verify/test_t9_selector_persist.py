# -*- coding: utf-8 -*-
"""任务(2026-07-11):候选拼音列常驻可改选。

用户反馈:选完最后一个(或唯一一个)候选拼音后选择器消失,无法改选。
业界(搜狗/百度/讯飞 九宫格):左侧拼音列在组合期间**全程常驻**,当前生效拼音高亮,
点其它项即改选并重新筛选候选词;展开候选面板时拼音列保留在左侧,候选网格右移留缝。

新控制器契约(三端同步):
  t9PinyinOptions:
    - composing 空 → [](隐藏,不变:未输入/选词消耗完)
    - remain 非空 → 剩余段选项(不变)
    - remain 空(全锁定)→ **末段选项**(该段数字的 t9LeadingOptions,含当前锁定项保底)
  t9ActiveOption:
    - remain 空 → 末段锁定音节(高亮用户点选)
    - 其余不变(#1 候选首音节)
  selectT9Pinyin:
    - 放得下 → push(不变)
    - 全锁定态 → **改选末段**:pop 末段,新项放得下则 push,否则恢复原样(防御)
  回退键 LIFO / 选词从栈头对齐消耗:完全不变(test_t9_lock 同步校验)
  展开面板:选择器保留,面板内容缩进 = 选择器列宽 + 6dp 缝隙(UI 预算见 U 组)
"""
from engine_v2 import load_engine_v2, to_digits

fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
    if not cond:
        fails.append(name)


class ControllerSimV2:
    """镜像新版 KeyboardController(常驻+改选)。"""

    def __init__(self, engine):
        self.e = engine
        self.composing = ""
        self.locked = []

    @property
    def locked_pinyin(self):
        return "".join(self.locked)

    def tap(self, letters):
        self.composing += to_digits(letters)

    def tap_digits(self, digits):
        self.composing += digits

    def selector_options(self):
        if not self.composing:
            return []
        lp = self.locked_pinyin
        if len(lp) >= len(self.composing):
            if not self.locked:
                return []
            last = self.locked[-1]
            seg_start = len(lp) - len(last)
            opts = list(self.e.t9_leading_options(self.composing[seg_start:], 6, 12))
            if last not in opts:
                opts.insert(0, last)
            return opts
        return list(self.e.t9_leading_options(self.composing[len(lp):], 6, 12))

    def active_option(self):
        lp = self.locked_pinyin
        if self.composing and self.locked and len(lp) >= len(self.composing):
            return self.locked[-1]
        return None  # remain 态高亮跟随 #1 候选(既有逻辑,此模型不重复验证)

    def pick_syllable(self, syl):
        if len(self.locked_pinyin) + len(syl) <= len(self.composing):
            self.locked.append(syl)
            return "push"
        if self.locked and len(self.locked_pinyin) >= len(self.composing):
            last = self.locked.pop()
            if len(self.locked_pinyin) + len(syl) <= len(self.composing):
                self.locked.append(syl)
                return "replace"
            self.locked.append(last)
            return "reject"
        return "ignore"

    def candidates(self):
        return self.e.candidates_for_t9_filtered(self.composing, self.locked_pinyin,
                                                 locked_sylls=self.locked)

    def display(self):
        return self.e.t9_display_filtered(self.composing, self.locked_pinyin, self.locked)

    def pick_candidate(self, cand):
        consumed = min(cand.matched_len, len(self.composing))
        self.composing = self.composing[consumed:]
        left = consumed
        new_locked = []
        broken = False
        for s in self.locked:
            if left == 0:
                new_locked.append(s)
            elif left >= len(s):
                left -= len(s)
            else:
                broken = True
                left = 0
        self.locked = [] if broken else new_locked

    def backspace(self):
        if self.locked:
            self.locked.pop()
            return "unlock"
        if self.composing:
            self.composing = self.composing[:-1]
            return "digit"
        return "doc"


def first_readings(eng, word):
    return eng.dict.char_readings.get(word[0], set()) if word else set()


def run():
    e = load_engine_v2()

    # ===== A. 单音节:选完唯一一个拼音后选择器不消失、高亮可见 =====
    s = ControllerSimV2(e)
    s.tap("hao")
    check("A1 锁定前选择器可见", len(s.selector_options()) > 0, f"{s.selector_options()[:5]}")
    s.pick_syllable("hao")
    opts = s.selector_options()
    check("A2 锁定 hao 后选择器仍可见(核心)", len(opts) > 0, f"{opts[:6]}")
    check("A3 active=hao(高亮用户点选)", s.active_option() == "hao", s.active_option())
    check("A4 选项含可改选项(gao 等)", any(o != "hao" for o in opts), f"{opts[:6]}")
    w1 = [c.word for c in s.candidates()[:5]]
    check("A5 候选为 hao 读音", any(w in "好号毫豪耗" for w in w1), f"{w1}")

    # ===== B. 改选:点其它拼音替换末段,候选/显示同步切换 =====
    r = s.pick_syllable("gao")
    check("B1 全锁定态点选=改选(replace)", r == "replace", r)
    check("B2 锁定栈变为 [gao]", s.locked == ["gao"], f"{s.locked}")
    w2 = [c.word for c in s.candidates()[:5]]
    check("B3 候选切到 gao 读音", any(w in "高搞告稿膏" for w in w2), f"{w2}")
    check("B4 显示切到 gao", s.display() == "gao", s.display())
    check("B5 active=gao", s.active_option() == "gao", s.active_option())
    r2 = s.pick_syllable("hao")
    w3 = [c.word for c in s.candidates()[:5]]
    check("B6 可改选回 hao", r2 == "replace" and any(w in "好号毫豪耗" for w in w3), f"{w3}")

    # ===== C. 单键前缀(联动单键锁定修复):锁 d 后选择器常驻,可改选 f =====
    s = ControllerSimV2(e)
    s.tap_digits("3")
    s.pick_syllable("d")
    opts = s.selector_options()
    check("C1 单键锁 d 后选择器可见", len(opts) > 0 and set(opts) >= {"e", "d", "f"}, f"{opts}")
    check("C2 active=d", s.active_option() == "d", s.active_option())
    s.pick_syllable("f")
    wf = [c.word for c in s.candidates()[:5]]
    check("C3 改选 f 生效", s.locked == ["f"] and all(
        any(rd.startswith("f") for rd in first_readings(e, w)) for w in wf[:3]), f"{wf}")

    # ===== D. 多段:全锁定后显示末段选项;改选更短音节自动回到增量流程 =====
    s = ControllerSimV2(e)
    s.tap("haoziweizhi")
    for syl in ["hao", "zi", "wei", "zhi"]:
        s.pick_syllable(syl)
    opts = s.selector_options()
    check("D1 全锁定后选择器常驻(末段选项)", len(opts) > 0 and "zhi" in opts, f"{opts[:6]}")
    check("D2 active=zhi", s.active_option() == "zhi", s.active_option())
    r = s.pick_syllable("zi")  # zhi(3位) → zi(2位):末位数字回到待定
    check("D3 改选短音节后回增量流程", r == "replace" and s.locked == ["hao", "zi", "wei", "zi"],
          f"{s.locked}")
    opts = s.selector_options()
    check("D4 选择器切到剩余段选项", len(opts) > 0, f"{opts[:6]}")
    check("D5 候选仍非空", len(s.candidates()) > 0, "")

    # ===== E. 选词流:逐词消耗期间选择器常驻;消耗完隐藏 =====
    s = ControllerSimV2(e)
    s.tap("haoziweizhi")
    for syl in ["hao", "zi", "wei", "zhi"]:
        s.pick_syllable(syl)
    cands = s.candidates()
    hao = next((c for c in cands if c.matched_len == 3), None)
    check("E1 有3位消耗候选", hao is not None, "")
    if hao:
        s.pick_candidate(hao)
        check("E2 选词后锁定从头对齐消耗", s.locked == ["zi", "wei", "zhi"], f"{s.locked}")
        opts = s.selector_options()
        check("E3 选词后选择器常驻(末段 zhi,新行为)", len(opts) > 0 and s.active_option() == "zhi",
              f"opts={opts[:4]} active={s.active_option()}")
        # 消耗到空
        guard = 0
        while s.composing and guard < 8:
            nxt = s.candidates()
            if not nxt:
                break
            s.pick_candidate(nxt[0])
            guard += 1
        check("E4 消耗完 composing 空 → 选择器隐藏", s.composing == "" and s.selector_options() == [],
              f"composing={s.composing!r}")

    # ===== F. 回退 LIFO 与改选共存 =====
    s = ControllerSimV2(e)
    s.tap("hao")
    s.pick_syllable("hao")
    s.pick_syllable("gao")  # 改选
    check("F1 改选后回退撤销的是当前项", s.backspace() == "unlock" and s.locked == [], f"{s.locked}")
    check("F2 回退后选择器回到未锁定态选项", len(s.selector_options()) > 0, "")
    check("F3 再回退删数字", s.backspace() == "digit" and len(s.composing) == 2, "")

    # ===== G. 防御:改选放不下时恢复原样(不破坏锁定栈) =====
    s = ControllerSimV2(e)
    s.tap_digits("42")  # ha 两位
    s.pick_syllable("ha")
    r = s.pick_syllable("hao")  # 3 位放不下 2 位数字
    check("G1 放不下的改选被拒绝且栈不变", r == "reject" and s.locked == ["ha"], f"{s.locked}")

    # ===== U. 展开面板避让预算(UI 模型):选择器列保留,内容缩进留缝 =====
    for screen in (320, 360, 412):
        key_area = screen - 8 * 2                # 键区左右 padding(约)
        selector_w = key_area * 1.0 / 6.0        # 9宫格首列权重 1.0/总 6.0
        panel_content = screen - 16 - selector_w - 6  # 面板自身 padding 16 + 缝隙 6
        check(f"U {screen}dp 屏展开面板内容宽≥200dp(实际{panel_content:.0f})", panel_content >= 200,
              f"selector={selector_w:.0f}dp")

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("候选拼音常驻改选模型全部通过")


if __name__ == "__main__":
    run()
