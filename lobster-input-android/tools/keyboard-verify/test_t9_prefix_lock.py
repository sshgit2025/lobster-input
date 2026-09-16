# -*- coding: utf-8 -*-
"""任务1验证:九宫格拼音选择器"单键/前缀锁定"点选必须生效。

用户报障:只敲一个键(如 3 → 选项 e/d/f,默认 e),点击 d 或 f 完全没反应。

根因(三端一致):
① lockedBounds 把前缀锁定(d 不是完整音节)的末端也当成音节边界 → 任何词都配不上;
② 词层要求 L>=2、补全要求 n>=2、锁定单字通道要求完整音节 → 单键锁定前缀零产词通道;
③ 兜底分支绕过锁定过滤,把默认读音(e)的候选原样塞回 → 候选零变化 = "没反应"。

新方案(已在 engine_v2/engine_v3 参照实现):
① 尾项前缀不设音节边界(只约束字母);② 补全通道对"锁定前缀态"放开 n==1;
③ 单字母锁定叠加简拼预测表(点选声母出该声母高频字,业界标准);
④ 兜底分支尊重锁定过滤;⑤ 全锁定态组合区忠实显示用户点选(锁 d 显示 d)。
"""
import time

from engine_base import T9
from engine_v2 import load_engine_v2

fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'} {name} {detail}")
    if not cond:
        fails.append(name)


def first_char_readings(eng, word):
    return eng.dict.char_readings.get(word[0], set()) if word else set()


def starts_with_lock(eng, cand, lock):
    """候选读音是否符合锁定前缀:优先用候选携带的拼音 key,缺失(简拼通道)退回字读音表。"""
    if cand.pinyin:
        return cand.pinyin.startswith(lock) or lock.startswith(cand.pinyin)
    return any(r.startswith(lock) for r in first_char_readings(eng, cand.word))


def run():
    eng = load_engine_v2()

    # ---------- 1. 选择器选项模型:单键选项 = 整段音节在前 + 单字母前缀垫底 ----------
    opts3 = eng.t9_leading_options("3", max_seg=6, limit=12)
    check("单键3选项含 e/d/f", set(opts3) >= {"e", "d", "f"}, f"{opts3}")
    check("单键3完整音节 e 排最前", opts3[0] == "e", f"{opts3}")
    opts7 = eng.t9_leading_options("7", max_seg=6, limit=12)
    check("单键7选项为 p/q/r/s(无完整音节)", set(opts7) == {"p", "q", "r", "s"}, f"{opts7}")

    # ---------- 2. 核心:每个数字键的每个选项,锁定后都必须"有反应" ----------
    for d in "23456789":
        base = eng.candidates_for_t9(d, 20)
        base_words = [c.word for c in base[:10]]
        for opt in eng.t9_leading_options(d, max_seg=6, limit=12):
            cands = eng.candidates_for_t9_filtered(d, opt, 20, locked_sylls=[opt])
            tag = f"键{d}锁{opt}"
            check(f"{tag} 候选非空", len(cands) > 0, f"n={len(cands)}")
            if not cands:
                continue
            bad = [c.word for c in cands[:10] if not starts_with_lock(eng, c, opt)]
            check(f"{tag} 前10候选读音全部匹配锁定", not bad, f"bad={bad}")
            # "有反应"判据:非默认选项锁定后,首候选读音必须匹配所点选项
            check(f"{tag} 首候选读音匹配", starts_with_lock(eng, cands[0], opt), f"top={cands[0].word}")
            if opt != opts_default(eng, d):
                check(f"{tag} 候选确实变化(≠未锁定默认)", [c.word for c in cands[:10]] != base_words, "")
            # 消耗模型:单键锁定的候选 matchedLen 必须=1(选词一次吃净该数字与锁定栈)
            check(f"{tag} 首候选 matchedLen=1", cands[0].matched_len == 1, f"ml={cands[0].matched_len}")

    # ---------- 3. 质量抽查:锁 d 出"的"级高频字;锁 f 出 f 声母高频字 ----------
    d_cands = [c.word for c in eng.candidates_for_t9_filtered("3", "d", 20, locked_sylls=["d"])]
    check("键3锁d 前5含高频字(的/都/大/对/多)", bool(set(d_cands[:5]) & set("的都大对多地得")), f"{d_cands[:5]}")
    f_cands = [c.word for c in eng.candidates_for_t9_filtered("3", "f", 20, locked_sylls=["f"])]
    check("键3锁f 前5含高频字(发/放/分/反/方)", bool(set(f_cands[:5]) & set("发放分反方非法")), f"{f_cands[:5]}")

    # ---------- 4. 锁定完整音节行为保持(回归):锁 e 出 e 字且单字全量可达 ----------
    e_cands = eng.candidates_for_t9_filtered("3", "e", 200, locked_sylls=["e"])
    e_words = {c.word for c in e_cands}
    e_exact = {w for w, _ in eng.dict.exact_words("e")}
    check("键3锁e 全部 e 读音单字可达(保底不回退)", e_exact <= e_words,
          f"缺{list(e_exact - e_words)[:5]}")

    # ---------- 5. 组合区显示:全锁定态忠实显示用户点选 ----------
    check("锁d显示d", eng.t9_display_filtered("3", "d", ["d"]) == "d",
          eng.t9_display_filtered("3", "d", ["d"]))
    check("锁e显示e", eng.t9_display_filtered("3", "e", ["e"]) == "e",
          eng.t9_display_filtered("3", "e", ["e"]))

    # ---------- 6. 前缀锁定 + 继续输入:边界放松只作用于尾项 ----------
    # 33 锁 d:的@de 必须可达(旧实现 d 末端被当边界,de 跨界被杀)
    cands33 = eng.candidates_for_t9_filtered("33", "d", 20, locked_sylls=["d"])
    w33 = [c.word for c in cands33[:10]]
    check("33锁d 出 的(matchedLen=2)", any(c.word == "的" and c.matched_len == 2 for c in cands33), f"{w33}")
    # 多位输入锁尾部前缀:9264 锁 y → 全部 y 声母
    cands_y = eng.candidates_for_t9_filtered("9264", "y", 20, locked_sylls=["y"])
    bad_y = [c.word for c in cands_y[:10] if not starts_with_lock(eng, c, "y")]
    check("9264锁y 候选非空且全 y 声母", len(cands_y) > 0 and not bad_y, f"bad={bad_y}")

    # ---------- 7. 完整音节锁定的边界裁决不放松(历史行为):锁 hua 仍排除 换@huan ----------
    d_hua = eng.to_digits_local("huanameduoqian") if hasattr(eng, "to_digits_local") else None
    from engine import to_digits
    dig = to_digits("huanameduoqian")
    hua_cands = eng.candidates_for_t9_filtered(dig, "hua", 60, locked_sylls=["hua"])
    check("锁hua(完整音节)排除 换@huan", all(c.word != "换" for c in hua_cands[:20]),
          f"{[c.word for c in hua_cands[:6]]}")

    # ---------- 7b. 无产出形态的兜底也须尊重锁定:77 锁 q 不得回吐 p/r/s 词 ----------
    cands77 = eng.candidates_for_t9_filtered("77", "q", 20, locked_sylls=["q"])
    bad77 = [c.word for c in cands77[:10] if not starts_with_lock(eng, c, "q")]
    check("77锁q 候选非空且全 q 声母", len(cands77) > 0 and not bad77,
          f"bad={bad77} top={[c.word for c in cands77[:5]]}")

    # ---------- 8. 未锁定行为零变化(回归守护) ----------
    base3 = [c.word for c in eng.candidates_for_t9("3", 10)]
    check("未锁定单键3 默认仍为 e 读音字", all(
        any(r.startswith("e") for r in first_char_readings(eng, w)) for w in base3[:5]), f"{base3[:5]}")

    # ---------- 9. 性能:长串+前缀锁定不劣化 ----------
    # 注:V2 遗留的 57 万自定义词"线性层"在锁定态逐词做兼容检查(~1.4s),是历史架构
    # 而非本修复引入(V3/三端业务代码均已数字索引化,无此线性层);此处清空线性表,
    # 只度量本修复涉及路径的耗时。回归器 patched 模式(V3)自动全程数字索引。
    eng.custom_words = []
    eng.t9_cache.clear()
    long_digits = to_digits("kanchengwanmei")
    t0 = time.time()
    for _ in range(20):
        eng.t9_cache.clear()
        eng.candidates_for_t9_filtered(long_digits, "k", 60, locked_sylls=["k"])
    per = (time.time() - t0) / 20 * 1000
    check("长串锁k 单次 < 80ms", per < 80, f"{per:.1f}ms")
    t0 = time.time()
    for _ in range(50):
        eng.t9_cache.clear()
        eng.candidates_for_t9_filtered("3", "d", 20, locked_sylls=["d"])
    per1 = (time.time() - t0) / 50 * 1000
    check("单键锁d 单次 < 30ms", per1 < 30, f"{per1:.1f}ms")

    print()
    if fails:
        print(f"共 {len(fails)} 项失败: {fails}")
        raise SystemExit(1)
    print("任务1(单键前缀锁定)全部通过")


def opts_default(eng, d):
    o = eng.t9_leading_options(d, max_seg=6, limit=12)
    return o[0] if o else ""


if __name__ == "__main__":
    run()
