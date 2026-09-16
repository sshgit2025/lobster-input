"""问题1验证:分类符号板数据 + 最近使用 LRU(键盘/语音共用同一存储)。

分类设计对齐搜狗/百度/Gboard 符号面板:最近/中文/英文/括号/数学/序号/货币/箭头。
落地时此数据镜像到 Kotlin SymbolData.kt 与 Swift SymbolData.swift。
"""

CATEGORIES = [
    ("中文", ["，", "。", "？", "！", "、", "；", "：", "“", "”", "‘", "’",
              "（", "）", "【", "】", "《", "》", "〈", "〉", "「", "」", "『", "』",
              "…", "—", "～", "·", "﹏", "＿", "￥"]),
    ("英文", [",", ".", "?", "!", ";", ":", "'", "\"", "(", ")", "[", "]",
              "{", "}", "<", ">", "@", "#", "$", "%", "^", "&", "*", "-",
              "_", "+", "=", "/", "\\", "|", "~", "`"]),
    ("括号", ["（", "）", "(", ")", "［", "］", "[", "]", "｛", "｝", "{", "}",
              "〈", "〉", "《", "》", "「", "」", "『", "』", "【", "】", "〔", "〕",
              "«", "»", "‹", "›"]),
    ("数学", ["+", "-", "×", "÷", "=", "≠", "≈", "<", ">", "≤", "≥", "±",
              "√", "∞", "%", "‰", "°", "π", "∑", "∫", "Δ", "∈", "∪", "∩",
              "∴", "∵", "⊥", "∥", "∠", "½", "¼", "¾", "²", "³"]),
    ("序号", ["①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
              "⑴", "⑵", "⑶", "⑷", "⑸", "⑹", "⑺", "⑻", "⑼", "⑽",
              "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ", "Ⅸ", "Ⅹ",
              "㈠", "㈡", "㈢", "㈣", "㈤"]),
    ("货币", ["￥", "¥", "$", "€", "£", "¢", "₩", "₽", "₹", "฿", "₫", "₴"]),
    ("箭头", ["←", "→", "↑", "↓", "↔", "↕", "↖", "↗", "↘", "↙", "⇐", "⇒",
              "★", "☆", "♥", "♡", "●", "○", "■", "□", "◆", "◇", "▲", "△",
              "※", "§", "№", "℃", "℉", "©", "®", "™"]),
]

RECENT_MAX = 16


class RecentSymbols:
    """最近使用 LRU(镜像 TypingPreferences.recordRecentEmoji 的实现方式)。"""

    def __init__(self):
        self.items = []

    def record(self, s):
        if not s:
            return
        if s in self.items:
            self.items.remove(s)
        self.items.insert(0, s)
        while len(self.items) > RECENT_MAX:
            self.items.pop()


def run():
    fails = []

    def check(name, cond, detail=""):
        print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
        if not cond:
            fails.append(name)

    # 1) 数据完整性:类内不重复、无空串、单类不超过 40(面板可滚动但别失控)
    for name, items in CATEGORIES:
        check(f"分类[{name}] 无重复", len(items) == len(set(items)), f"n={len(items)}")
        check(f"分类[{name}] 无空串", all(items), "")
        check(f"分类[{name}] 数量合理", 8 <= len(items) <= 40, f"n={len(items)}")

    # 2) 常用场景覆盖:数学/序号/货币关键符号必须在
    all_syms = {s for _, items in CATEGORIES for s in items}
    for must in ["×", "÷", "≠", "√", "π", "①", "⑩", "Ⅰ", "€", "₩", "→", "℃", "№"]:
        check(f"关键符号 {must} 收录", must in all_syms, "")

    # 3) LRU 行为:去重置顶、超限截断
    r = RecentSymbols()
    for s in ["，", "。", "×", "，", "→"]:
        r.record(s)
    check("LRU 去重置顶", r.items[:3] == ["→", "，", "×"], f"{r.items[:4]}")
    for i in range(30):
        r.record(f"s{i}")
    check("LRU 超限截断", len(r.items) == RECENT_MAX, f"n={len(r.items)}")
    check("LRU 最新在前", r.items[0] == "s29", r.items[0])

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("符号分类 + LRU 模型全部通过")


if __name__ == "__main__":
    run()
