# -*- coding: utf-8 -*-
"""问题1 中英↔九宫格模式切换 UX —— 状态机模型验证。

忠实镜像三端 KeyboardController 的模式切换(LANG / MODE_CYCLE / LAYOUT + nineGrid 持久化)。
先复现用户报的 bug 路径("中九→切英→切回中文停26键"),再验证"语言/布局解耦"修复。

结论(先说):bug 根因 = MODE_CYCLE 环把 [中九,中26,英,俄,韩] 串一起,中九→英 要经过中26,
经过时 persistNineGrid(false),之后 LANG 切回中文 → 中26。修复 = MODE_CYCLE 只循环语言
[中,英,俄,韩],中文永远用记住的 nineGrid;九宫格/26键 由独立布局键切换(正交)。
"""

fails = []
def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
    if not cond: fails.append(name)


class OldController:
    """当前线上行为(bug 版):MODE_CYCLE 环含中九/中26。"""
    def __init__(self, nine=True):
        self.lang = "ZH"; self.nine = nine; self.persisted = nine
    def display(self):
        if self.lang != "ZH": return f"{self.lang}26"
        return "中九" if self.nine else "中26"
    def lang_key(self):  # 中英 toggle,不动 nine
        ring = ["ZH", "EN"]
        self.lang = ring[(ring.index(self.lang) + 1) % 2] if self.lang in ring else "ZH"
    def mode_cycle(self):
        ring = [("ZH", True), ("ZH", False), ("EN", False), ("RU", False), ("KO", False)]
        cur = (self.lang, self.lang == "ZH" and self.nine)
        idx = ring.index(cur) if cur in ring else 0
        lang, nine = ring[(idx + 1) % len(ring)]
        self.lang = lang
        if lang == "ZH":
            self.nine = nine; self.persisted = nine   # ← bug:经过中26 persist False
    def layout_toggle(self):  # 九/26 显式切换(仅中文有意义)
        self.nine = not self.nine; self.persisted = self.nine


class NewController:
    """修复版:MODE_CYCLE 只循环语言;中文用记住的 nine;布局由独立键切换(正交)。"""
    def __init__(self, nine=True):
        self.lang = "ZH"; self.nine = nine; self.persisted = nine
    def display(self):
        if self.lang != "ZH": return f"{self.lang}26"
        return "中九" if self.nine else "中26"
    def lang_key(self):
        ring = ["ZH", "EN"]
        self.lang = ring[(ring.index(self.lang) + 1) % 2] if self.lang in ring else "ZH"
    def mode_cycle(self):
        ring = ["ZH", "EN", "RU", "KO"]           # ← 只循环语言
        self.lang = ring[(ring.index(self.lang) + 1) % len(ring)] if self.lang in ring else "ZH"
        # 不动 nine:切回中文自动用记住的布局
    def layout_toggle(self):
        self.nine = not self.nine; self.persisted = self.nine


def run():
    print("===== A. 复现 bug(OldController)=====")
    # 用户流程:中九 → MODE_CYCLE 朝英文循环 → 切回中文
    c = OldController(nine=True)
    check("A0 起始中文九宫格", c.display() == "中九", c.display())
    c.mode_cycle()  # 中九→中26(经过!persist False)
    check("A1 MODE_CYCLE 一次到中26(经过站)", c.display() == "中26", c.display())
    c.mode_cycle()  # 中26→英
    check("A2 再 MODE_CYCLE 到英文", c.display() == "EN26", c.display())
    c.lang_key()    # 英→中,用持久化 nine=False
    check("A3 ★bug:LANG 切回中文停在中26", c.display() == "中26",
          f"{c.display()}(持久化nine={c.persisted})")

    print("\n===== B. 修复版同样流程(NewController)=====")
    n = NewController(nine=True)
    check("B0 起始中文九宫格", n.display() == "中九", n.display())
    n.mode_cycle()  # 中→英(一步,不经过中26)
    check("B1 MODE_CYCLE 一步到英文(不经过中26)", n.display() == "EN26", n.display())
    n.lang_key()    # 英→中,用记住的 nine=True
    check("B2 ★修复:LANG 切回中文恢复九宫格", n.display() == "中九", n.display())

    print("\n===== C. 修复版:语言/布局正交,各自独立 =====")
    n = NewController(nine=True)
    # 纯语言循环:中→英→俄→韩→中,中文始终九宫格
    seq = []
    for _ in range(4):
        n.mode_cycle(); seq.append(n.display())
    check("C1 循环一圈回中文仍九宫格", n.display() == "中九", f"{seq}")
    # 中英反复切:九宫格保持
    n = NewController(nine=True)
    for _ in range(6): n.lang_key()
    check("C2 中英反复切6次仍九宫格", n.display() == "中九", n.display())
    # 显式切26键后,中英切换记住26键
    n = NewController(nine=True)
    n.layout_toggle()  # 中九→中26(用户显式选择)
    check("C3 显式切到中26", n.display() == "中26", n.display())
    n.lang_key(); n.lang_key()  # 中→英→中
    check("C4 显式选中26后,中英切换记住中26", n.display() == "中26", n.display())
    # 俄韩语言不受布局影响
    n = NewController(nine=True)
    n.mode_cycle(); n.mode_cycle()  # 中→英→俄
    check("C5 循环到俄语", n.display() == "RU26", n.display())

    print()
    if fails:
        print(f"共 {len(fails)} 失败: {fails}"); raise SystemExit(1)
    print("模式切换 UX 模型全部通过(bug 已复现,修复方案已验证)")


if __name__ == "__main__":
    run()
