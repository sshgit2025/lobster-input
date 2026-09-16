# -*- coding: utf-8 -*-
"""任务2验证:符号页点选符号后自动跳回上一输入模式(状态机模型)。

业界调研结论(2026-07):
- 搜狗/百度/讯飞/豆包(中文输入法主流):从键盘进入符号页,单击一个符号上屏后
  **立即跳回进入前的输入布局**(九宫格回九宫格、26键回26键);符号面板另有"锁定"
  图钉可钉住连续输入(可选增强,非默认)。
- iOS 原生英文键盘 ?123 页不回跳,但中文用户habit以搜狗系为准;Gboard 中文版符号面板同样回跳。
- 数字键例外:符号页首行 1-0 常用于连续输数字(年份/金额),回跳会造成反复弹跳,
  主流实现数字不触发回跳(搜狗九宫格符号页干脆不放数字)。

新方案(镜像三端 KeyboardController):
1. SYM_CHAR 上屏后:若当前在 symbolPage 且字符非 ASCII 数字 → symbolPage=false、
   symbolPageIndex=0、rebuild → 自然回到进入前布局(inputLang/nineGrid 状态从未被改动)。
2. 分类符号板(symBoardPage)selectSymbol 上屏后同样回跳。
3. 翻页(SYM_PAGE)/删除/空格/回车不回跳;数字页(numberPage)行为不变(粘性保留)。
"""

ZH, EN, RU, KO = "zh", "en", "ru", "ko"


class MiniController:
    """三端 KeyboardController 的状态机镜像(仅任务2相关状态)。"""

    def __init__(self, lang=ZH, nine_grid=True):
        self.lang = lang
        self.nine_grid = nine_grid
        self.symbol_page = False
        self.number_page = False
        self.sym_board_page = False
        self.symbol_page_index = 0
        self.sticky_number_page = False
        self.committed = []

    # ---- 布局描述(镜像 layoutState():持久态从不被符号页修改)----
    def layout(self):
        if self.sym_board_page:
            return "symboard"
        if self.symbol_page:
            return f"symbol{self.symbol_page_index + 1}"
        if self.number_page:
            return "number"
        if self.lang == ZH and self.nine_grid:
            return "zh-9grid"
        if self.lang == ZH:
            return "zh-26"
        return f"{self.lang}-26"

    # ---- 按键(镜像 handleKey)----
    def key_symbol(self):
        self.symbol_page = True
        self.number_page = False
        self.sym_board_page = False
        self.symbol_page_index = 0

    def key_num(self):
        self.number_page = True
        self.sticky_number_page = True
        self.symbol_page = False
        self.sym_board_page = False

    def key_sym_board(self):
        self.sym_board_page = True
        self.symbol_page = False
        self.number_page = False

    def key_sym_page(self):
        self.symbol_page_index = 1 if self.symbol_page_index == 0 else 0

    def key_alpha(self):
        self.symbol_page = False
        self.number_page = False
        self.sticky_number_page = False
        self.sym_board_page = False

    def key_sym_char(self, ch, pair=None):
        """符号上屏。【新】symbolPage 内非数字符号 → 自动回跳。"""
        self.committed.append(ch + (pair or ""))
        if self.symbol_page and not (len(ch) == 1 and ch.isdigit()):
            self.symbol_page = False
            self.symbol_page_index = 0

    def key_delete(self):
        if self.committed:
            self.committed.pop()

    def key_space(self):
        self.committed.append(" ")

    def select_symbol(self, s):
        """分类符号板点选。【新】上屏后回跳。"""
        self.committed.append(s)
        if self.sym_board_page:
            self.sym_board_page = False


fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
    if not cond:
        fails.append(name)


def run():
    # 1. 各输入模式 → 符号页 → 点一个符号 → 回到原模式
    for lang, nine, home in [(ZH, True, "zh-9grid"), (ZH, False, "zh-26"),
                             (EN, False, "en-26"), (RU, False, "ru-26"), (KO, False, "ko-26")]:
        c = MiniController(lang, nine)
        check(f"{home} 初始布局", c.layout() == home, c.layout())
        c.key_symbol()
        check(f"{home} 进符号页", c.layout() == "symbol1", c.layout())
        c.key_sym_char("，")
        check(f"{home} 点符号后回跳", c.layout() == home, c.layout())
        check(f"{home} 符号已上屏", c.committed == ["，"], f"{c.committed}")

    # 2. 符号页第二页点符号:同样回跳且页码复位
    c = MiniController(ZH, True)
    c.key_symbol(); c.key_sym_page()
    check("翻页不回跳", c.layout() == "symbol2", c.layout())
    c.key_sym_char("《", pair="》")
    check("第二页点配对符号后回跳", c.layout() == "zh-9grid", c.layout())
    c.key_symbol()
    check("再次进入符号页从第1页开始", c.layout() == "symbol1", c.layout())

    # 3. 数字不回跳:符号页首行连续输 2026 不弹跳
    c = MiniController(ZH, True)
    c.key_symbol()
    for ch in "2026":
        c.key_sym_char(ch)
        check(f"输数字{ch}后仍在符号页", c.layout() == "symbol1", c.layout())
    c.key_sym_char("！")
    check("数字后点符号才回跳", c.layout() == "zh-9grid", c.layout())
    check("上屏序列完整", "".join(c.committed) == "2026！", "".join(c.committed))

    # 4. 删除/空格不回跳
    c = MiniController(ZH, False)
    c.key_symbol(); c.key_delete(); check("删除不回跳", c.layout() == "symbol1", c.layout())
    c.key_space(); check("空格不回跳", c.layout() == "symbol1", c.layout())

    # 5. 分类符号板:点选后回跳到进入前布局
    c = MiniController(ZH, True)
    c.key_symbol(); c.key_sym_board()
    check("进分类符号板", c.layout() == "symboard", c.layout())
    c.select_symbol("①")
    check("符号板点选后回跳", c.layout() == "zh-9grid", c.layout())

    # 6. 数字页(拨号盘)不受影响:粘性保留、输入不回跳
    c = MiniController(ZH, True)
    c.key_num()
    for ch in "13800":
        c.key_sym_char(ch)
    check("数字页连续输入不回跳", c.layout() == "number", c.layout())
    c.key_sym_char(".")
    check("数字页点符号也不回跳(仅 symbolPage 回跳)", c.layout() == "number", c.layout())
    check("数字页粘性保留", c.sticky_number_page, "")

    # 7. 手动返回键(ALPHA)仍可用
    c = MiniController(ZH, True)
    c.key_symbol(); c.key_alpha()
    check("手动拼音键返回", c.layout() == "zh-9grid", c.layout())

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("任务2(符号页自动回跳)模型全部通过")


if __name__ == "__main__":
    run()
