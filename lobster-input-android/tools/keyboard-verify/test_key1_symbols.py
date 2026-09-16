# -*- coding: utf-8 -*-
"""任务3验证:九宫格 1 键 → "@#" 高频符号候选(对齐豆包)。

产品定义(用户指定,固定顺序、不做权重):
  # @ （ ） * - + 。 ～ 、 《 》 /
  - 用户给的混排列表统一映射为中文语境形态:() → （）、<> → 《》、顿号 → 、、~ → ～、
    句点 → 。(用户 2026-07-10 明确指定);# @ * - + / 无常用全角变体,保持半角(豆包同)。
  - 括号/书名号成套规则:点前半(（/《)时光标后无文字 → 成套插入且光标居中;
    光标后有文字 → 只插前半;点后半(）/》)一律只插后半。
  - 其余符号直接上屏。

交互模型(镜像三端 KeyboardController 新增 symCandidateMode):
  - 点 1 键(SYM_CANDS):丢弃组合态(与旧顿号键一致),候选栏 = 固定符号候选。
  - 点符号候选:按上述规则上屏,列表保持(可连点多个,豆包同);不写词典、不改 lastWord
    (联想链不断)。
  - 任何其它按键(2-9 字母、删除、空格、回车、切页)→ 退出符号候选态,恢复常规行为;
    空格上屏空格而非首个符号(composing 为空时 onSpace 本就直接上屏空格)。
"""

KEY1_SYMBOLS = ["#", "@", "（", "）", "*", "-", "+", "。", "～", "、", "《", "》", "/"]
PAIR = {"（": "）", "《": "》"}
CLOSERS = {"）", "》"}


class MiniHost:
    """模拟宿主输入框:text + 光标。"""

    def __init__(self, before="", after=""):
        self.before = before
        self.after = after

    def has_text_after_cursor(self):
        return len(self.after) > 0

    def commit(self, s):
        self.before += s

    def commit_pair(self, opening, closing):
        self.before += opening
        self.after = closing + self.after

    def text(self):
        return self.before + "|" + self.after  # | 表示光标


class MiniController:
    def __init__(self, host):
        self.host = host
        self.composing = ""
        self.sym_candidate_mode = False
        self.last_word = None

    def candidates(self):
        if self.composing:
            return ["<拼音候选>"]
        if self.sym_candidate_mode:
            return list(KEY1_SYMBOLS)
        return []

    # ---- 按键 ----
    def key1(self):
        self.composing = ""  # discardComposing(与旧顿号键一致)
        self.sym_candidate_mode = True

    def key_t9(self, d):
        self.sym_candidate_mode = False
        self.composing += d

    def key_delete(self):
        self.sym_candidate_mode = False
        if self.composing:
            self.composing = self.composing[:-1]
        elif self.host.before:
            self.host.before = self.host.before[:-1]

    def key_space(self):
        self.sym_candidate_mode = False
        if not self.composing:
            self.host.commit(" ")

    def key_page_switch(self):
        self.sym_candidate_mode = False

    # ---- 候选点选 ----
    def select_symbol_candidate(self, s):
        closing = PAIR.get(s)
        if closing is not None and not self.host.has_text_after_cursor():
            self.host.commit_pair(s, closing)
        else:
            self.host.commit(s)
        # 列表保持(可连点);不写词典、不动 lastWord


fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
    if not cond:
        fails.append(name)


def run():
    # 1. 符号列表:顺序固定、与产品定义逐位一致、无重复
    check("符号列表顺序与定义一致",
          KEY1_SYMBOLS == ["#", "@", "（", "）", "*", "-", "+", "。", "～", "、", "《", "》", "/"],
          f"{KEY1_SYMBOLS}")
    check("符号列表无重复", len(KEY1_SYMBOLS) == len(set(KEY1_SYMBOLS)), "")
    check("成对符号前后半都在列表", {"（", "）", "《", "》"} <= set(KEY1_SYMBOLS), "")

    # 2. 点 1 键出符号候选
    c = MiniController(MiniHost())
    c.key1()
    check("点1键候选=固定符号列表", c.candidates() == KEY1_SYMBOLS, "")

    # 3. 配对规则:光标后无文字 → 成套插入光标居中
    c = MiniController(MiniHost(before="你好"))
    c.key1(); c.select_symbol_candidate("（")
    check("（光标后无文字成套插入", c.host.text() == "你好（|）", c.host.text())
    # 光标后有文字 → 只插前半
    c = MiniController(MiniHost(before="你好", after="世界"))
    c.key1(); c.select_symbol_candidate("（")
    check("（光标后有文字只插前半", c.host.text() == "你好（|世界", c.host.text())
    # 点后半一律只插后半
    c = MiniController(MiniHost(before="你好（测试"))
    c.key1(); c.select_symbol_candidate("）")
    check("）直接上屏", c.host.text() == "你好（测试）|", c.host.text())
    # 书名号同规则
    c = MiniController(MiniHost())
    c.key1(); c.select_symbol_candidate("《")
    check("《成套插入", c.host.text() == "《|》", c.host.text())
    c.select_symbol_candidate("》")  # 光标后有 》 → 只插前半规则不适用于后半:直接上屏
    check("》直接上屏", c.host.text() == "《》|》", c.host.text())

    # 4. 非配对符号直接上屏,列表保持可连点
    c = MiniController(MiniHost())
    c.key1()
    for s in ["#", "@", "～"]:
        c.select_symbol_candidate(s)
        check(f"连点{s}后候选仍为符号列表", c.candidates() == KEY1_SYMBOLS, "")
    check("连点上屏序列", c.host.text() == "#@～|", c.host.text())

    # 5. 退出符号候选态
    c = MiniController(MiniHost())
    c.key1(); c.key_t9("2")
    check("输字母退出符号态(候选=拼音)", c.candidates() == ["<拼音候选>"], "")
    c = MiniController(MiniHost(before="x"))
    c.key1(); c.key_delete()
    check("删除退出符号态且删了字符", c.candidates() == [] and c.host.before == "", c.host.text())
    c = MiniController(MiniHost())
    c.key1(); c.key_space()
    check("空格上屏空格而非首符号", c.host.text() == " |" and c.candidates() == [], c.host.text())

    # 6. 组合态点 1 键:丢弃组合(与旧顿号键 discardComposing 一致)后进符号态
    c = MiniController(MiniHost())
    c.key_t9("2"); c.key_t9("4")
    c.key1()
    check("组合态点1键丢弃组合并出符号候选", c.composing == "" and c.candidates() == KEY1_SYMBOLS, "")

    # 6b. 候选栏收起契约(2026-07-11 修复):符号候选态与打字态一致收起两侧,
    #     候选占满整行(13 符号需要整行空间);emoji 联想态不收起。
    def bar_collapsed(composing_display, first_is_symbol, first_is_emoji=False):
        """镜像三端 CandidateBarView 的收起条件。"""
        return len(composing_display) > 0 or first_is_symbol
    check("打字态收起两侧", bar_collapsed("nihao", False), "")
    check("符号候选态收起两侧(修复点)", bar_collapsed("", True), "")
    check("emoji联想态不收起", not bar_collapsed("", False, first_is_emoji=True), "")
    check("空态不收起", not bar_collapsed("", False), "")

    # 7. 联想链不断:lastWord 不被符号点选清空
    c = MiniController(MiniHost())
    c.last_word = "你好"
    c.key1(); c.select_symbol_candidate("～")
    check("符号点选不清 lastWord", c.last_word == "你好", "")

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("任务3(1键高频符号候选)模型全部通过")


if __name__ == "__main__":
    run()
