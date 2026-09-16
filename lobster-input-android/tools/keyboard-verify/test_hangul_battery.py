"""Hangul 두벌식组字自动机全面电池(对照标准 2-set 规则/Gboard·iOS 系统键盘行为)。

覆盖:基本组字、复合中声、复合终声、终声借调、双辅音(shift)、逐 jamo 退格、
纯元音开头、辅音连击、flush 定稿。每个 case = (按键序列, 期望最终文本)。
最终文本 = 所有 committed 拼接 + 最后 current()/flush()。
"""
from hangul_composer import HangulComposer

cases = [
    # --- 基本音节 ---
    ("ㅎㅏㄴ", "한"),
    ("ㄱㅏ", "가"),
    ("ㅇㅏㄴㄴㅕㅇ", "안녕"),                     # 终声借调:안ㄴ+ㅕ→안녕
    ("ㅎㅏㄴㄱㅜㄱㅇㅓ", "한국어"),
    # --- 终声借调(닭이→달기? 不,닭+이=닭이 分字) ---
    ("ㄷㅏㄺㅇㅣ", "닭이"),                       # ㄺ 复合终声,ㅇ 后接 ㅣ → 拆 ㅇ 走
    ("ㄷㅏㄹㄱㅣ", "달기"),                       # 无 shift 连击:ㄹ+ㄱ 合终声,ㅣ 来借调 ㄱ
    ("ㄱㅏㅂㅅㅣ", "갑시"),                       # ㅄ 复合终声借调 ㅅ
    # --- 复合中声 ---
    ("ㄱㅗㅏ", "과"),
    ("ㄱㅗㅐ", "괘"),
    ("ㄱㅗㅣ", "괴"),
    ("ㄱㅜㅓ", "궈"),
    ("ㄱㅜㅔ", "궤"),
    ("ㄱㅜㅣ", "귀"),
    ("ㄱㅡㅣ", "긔"),
    ("ㅇㅜㅣ", "위"),
    ("ㅇㅢ", "의"),                              # 直接复合元音键(如有)
    # --- 复合中声不可再组 ---
    ("ㄱㅘㅏ", "과ㅏ"),                           # ㅘ+ㅏ 不合并 → 定稿과,ㅏ 单独
    # --- 复合终声全表 ---
    ("ㅁㅗㄱㅅ", "몫"),
    ("ㅇㅏㄴㅈ", "앉"),
    ("ㅁㅏㄴㅎ", "많"),
    ("ㄷㅏㄹㄱ", "닭"),
    ("ㅅㅏㄹㅁ", "삶"),
    ("ㅂㅏㄹㅂ", "밟"),
    ("ㄱㅗㄹㅅ", "곬"),
    ("ㅎㅏㄹㅌ", "핥"),
    ("ㅇㅡㄹㅍ", "읊"),
    ("ㅇㅏㄹㅎ", "앓"),
    ("ㄱㅏㅂㅅ", "값"),
    # --- 双辅音(shift 直入)与 ㅆ 终声 ---
    ("ㄲㅏ", "까"),
    ("ㅆㅏ", "싸"),
    ("ㅇㅣㅆㄷㅏ", "있다"),                       # ㅆ 可作终声
    ("ㄸㅏ", "따"),
    ("ㅃㅏ", "빠"),
    ("ㅉㅏ", "짜"),
    # --- ㄸㅃㅉ 不能作终声:定稿当前新起 ---
    ("ㄱㅏㄸㅏ", "가따"),
    ("ㅇㅗㅃㅏ", "오빠"),
    # --- 辅音连击(无元音):逐个定稿 ---
    ("ㄱㄱㅏ", "ㄱ가"),
    ("ㅅㄱ", "ㅅㄱ"),
    # --- 纯元音开头/元音后接辅音再元音 ---
    ("ㅏ", "ㅏ"),
    ("ㅏㅏ", "ㅏㅏ"),                             # ㅏ+ㅏ 不合并
    ("ㅏㄱ", "ㅏㄱ"),                             # 【关键】孤元音后辅音:ㄱ 绝不能丢
    ("ㅏㄱㅏ", "ㅏ가"),                           # 孤元音,后辅音+元音成新字
    ("ㅗㅏㄱ", "와ㄱ? 或 ㅘㄱ"),                  # 特殊:见下方专项断言
    # --- 空格/标点打断(flush) ---
    ("ㅎㅏㄴ ㄱㅜㄱ", "한 국"),
]


def run(seq):
    h = HangulComposer()
    out = []
    for ch in seq:
        if ch == " ":
            out.append(h.flush())
            out.append(" ")
            continue
        out.append(h.feed(ch))
    out.append(h.flush())
    return "".join(out)


fails = []
for seq, want in cases:
    if want.startswith("와"):  # 专项:ㅗ+ㅏ 组合成 ㅘ 后接辅音 → 왁?不,无 cho 时是孤 ㅘ+ㄱ
        got = run(seq)
        ok = got in ("ㅘㄱ",)
        print(f"{'PASS' if ok else 'FAIL'} {seq!r} -> {got!r} (期望 ㅘㄱ:孤复合元音+辅音,辅音不丢)")
        if not ok:
            fails.append(seq)
        continue
    got = run(seq)
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'} {seq!r} -> {got!r} want={want!r}")
    if not ok:
        fails.append(seq)

# --- 退格逐 jamo 拆解 ---
def bs_case(seq, n_bs, want_current):
    h = HangulComposer()
    committed = ""
    for ch in seq:
        committed += h.feed(ch)
    for _ in range(n_bs):
        h.backspace()
    got = committed + h.current()
    ok = got == want_current
    print(f"{'PASS' if ok else 'FAIL'} BS {seq!r} x{n_bs} -> {got!r} want={want_current!r}")
    if not ok:
        fails.append(f"BS{seq}")

bs_case("ㅎㅏㄴ", 1, "하")     # 한 退1 → 하
bs_case("ㅎㅏㄴ", 2, "ㅎ")     # 退2 → ㅎ
bs_case("ㅎㅏㄴ", 3, "")       # 退3 → 空
bs_case("ㄷㅏㄺ", 1, "달")     # 复合终声拆一半
bs_case("ㄱㅘ", 1, "고")       # 复合中声拆一半
bs_case("ㅇㅣㅆ", 1, "이")     # ㅆ 终声整删(双辅音是原子 jamo,不拆成 ㅅㅅ)

print()
print("=" * 60)
print("全部通过" if not fails else f"失败 {len(fails)} 项: {fails}")
raise SystemExit(0 if not fails else 1)
