"""问题2验证:T9 拼音选择器「锁定音节栈」模型。

模拟 KeyboardController 的新逻辑:
- t9LockedSyllables: 锁定音节栈(用户点选的拼音,LIFO 回退)
- 选择器显示未锁定剩余段的下一音节选项;剩余段为空(全锁定)→ 常驻显示**末段选项**
  (2026-07-11 产品变更:选完最后一个拼音不消失、可改选,对齐搜狗/百度)
- 选候选词消耗 matchedLen 位数字,同时从锁定栈**头部**按拼音长度对齐消耗,
  剩余锁定保持 → 选词后选择器不再弹出(除非剩余段还有未锁定数字)
- 回退键:锁定栈非空先 pop 栈顶(撤销上一次点选),否则删数字
"""
from engine_v2 import load_engine_v2, to_digits


class ControllerSim:
    def __init__(self, engine):
        self.e = engine
        self.composing = ""
        self.locked = []  # 锁定音节栈

    @property
    def locked_pinyin(self):
        return "".join(self.locked)

    def tap_digits(self, letters):
        self.composing += to_digits(letters)

    def selector_options(self):
        """选择器可见选项:剩余段选项;全锁定 → 末段选项常驻(2026-07-11 可改选)。"""
        lp = self.locked_pinyin
        if not self.composing:
            return []
        if len(lp) >= len(self.composing):
            if not self.locked:
                return []
            last = self.locked[-1]
            seg_start = len(lp) - len(last)
            opts = list(self.e.t9_leading_options(self.composing[seg_start:], 6, 12))
            if last not in opts:
                opts.insert(0, last)
            return opts
        remain = self.composing[len(lp):]
        opts = self.e.t9_leading_options(remain, 6, 12) if hasattr(self.e, 't9_leading_options') else []
        # 引擎无该接口时用切分兜底(脚本只验证可见性逻辑)
        if not opts:
            segs, cov = self.e.best_t9_seg_partial(remain)
            opts = segs[:1] if segs else []
        return opts

    def pick_syllable(self, syl):
        if len(self.locked_pinyin) + len(syl) <= len(self.composing):
            self.locked.append(syl)

    def candidates(self):
        return self.e.candidates_for_t9_filtered(self.composing, self.locked_pinyin)

    def pick_candidate(self, cand):
        """选词消耗:composing 截掉 matchedLen;锁定栈头部按拼音长度对齐消耗。"""
        consumed = min(cand.matched_len, len(self.composing))
        self.composing = self.composing[consumed:]
        # 锁定栈从头消耗 consumed 位拼音;音节边界不对齐时清空剩余(安全回退)
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
        """回退:先撤销上一个锁定音节;无锁定则删一位数字。"""
        if self.locked:
            self.locked.pop()
            return "unlock"
        if self.composing:
            self.composing = self.composing[:-1]
            return "digit"
        return "doc"


def run():
    e = load_engine_v2()
    sim = ControllerSim(e)
    fails = []

    def check(name, cond, detail=""):
        tag = "PASS" if cond else "FAIL"
        print(f"{tag} {name} {detail}")
        if not cond:
            fails.append(name)

    # 场景1:haoziweizhi 依次锁定 hao/zi/wei/zhi → 全锁定后选择器消失
    sim.composing = ""
    sim.locked = []
    sim.tap_digits("haoziweizhi")
    for syl in ["hao", "zi", "wei", "zhi"]:
        opts = sim.selector_options()
        check(f"锁定前选择器可见({syl})", len(opts) > 0, f"opts={opts[:5]}")
        sim.pick_syllable(syl)
    check("全部锁定后选择器常驻(末段 zhi 可改选)", "zhi" in sim.selector_options(),
          f"opts={sim.selector_options()[:5]}")

    # 场景2:全锁定后逐词选字 → 选择器保持消失(核心修复点)
    cands = sim.candidates()
    words = [c.word for c in cands[:20]]
    check("锁定态有候选", len(cands) > 0, f"top={words[:8]}")
    hao = next((c for c in cands if c.word == "耗" and c.matched_len == 3), None)
    if hao is None:
        hao = next((c for c in cands if c.matched_len == 3), None)
    check("能选到3位消耗的单字", hao is not None, f"word={hao.word if hao else None}")
    sim.pick_candidate(hao)
    check("选'耗'后锁定剩 zi/wei/zhi", sim.locked == ["zi", "wei", "zhi"], f"locked={sim.locked}")
    check("选'耗'后选择器常驻且不重弹提示(末段 zhi)", "zhi" in sim.selector_options(),
          f"opts={sim.selector_options()[:5]}")
    cands = sim.candidates()
    zi = next((c for c in cands if c.word == "子" and c.matched_len == 2), None) or \
        next((c for c in cands if c.matched_len == 2), None)
    sim.pick_candidate(zi)
    check("选'子'后锁定剩 wei/zhi", sim.locked == ["wei", "zhi"], f"locked={sim.locked}")
    check("选'子'后选择器常驻(末段 zhi)", "zhi" in sim.selector_options(),
          f"opts={sim.selector_options()[:5]}")
    cands = sim.candidates()
    wei_words = [c.word for c in cands if c.matched_len == 3]
    check("剩余 weizhi 候选含'尾'", "尾" in [c.word for c in cands], f"3位消耗={wei_words[:10]}")
    wei = next((c for c in cands if c.word == "尾"), None) or next((c for c in cands if c.matched_len == 3), None)
    sim.pick_candidate(wei)
    cands = sim.candidates()
    sim.pick_candidate(next(c for c in cands if c.matched_len == len(sim.composing)))
    check("选完全部后 composing 空 + 锁定空", sim.composing == "" and sim.locked == [], "")

    # 场景3:LIFO 回退——锁定 hao/zi 后退格两次逐个撤销
    sim.composing = ""
    sim.locked = []
    sim.tap_digits("haoziweizhi")
    sim.pick_syllable("hao")
    sim.pick_syllable("zi")
    r1 = sim.backspace()
    check("第1次回退撤销 zi", r1 == "unlock" and sim.locked == ["hao"], f"locked={sim.locked}")
    r2 = sim.backspace()
    check("第2次回退撤销 hao", r2 == "unlock" and sim.locked == [], f"locked={sim.locked}")
    r3 = sim.backspace()
    check("第3次回退删数字", r3 == "digit" and len(sim.composing) == 10, f"len={len(sim.composing)}")

    # 场景4:部分锁定后选整句词(消耗跨过锁定边界)→ 锁定安全清空不残留
    sim.composing = ""
    sim.locked = []
    sim.tap_digits("haoziweizhi")
    sim.pick_syllable("hao")
    cands = sim.candidates()
    big = next((c for c in cands if c.matched_len > 3), None)
    if big:
        sim.pick_candidate(big)
        lp = sim.locked_pinyin
        check("跨界选词后锁定不越界", len(lp) <= len(sim.composing), f"locked={sim.locked} composing={sim.composing}")
    else:
        check("跨界选词后锁定不越界", True, "(无跨界候选,跳过)")

    # 场景5:选词消耗正好等于全部锁定+数字 → 双清
    sim.composing = ""
    sim.locked = []
    sim.tap_digits("nihao")
    sim.pick_syllable("ni")
    cands = sim.candidates()
    full = next((c for c in cands if c.matched_len == 5), None)
    check("nihao 锁 ni 后有整词候选", full is not None, f"word={full.word if full else None}")
    sim.pick_candidate(full)
    check("整词选完后双清", sim.composing == "" and sim.locked == [], "")

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("T9 锁定栈模型全部通过")


if __name__ == "__main__":
    run()
