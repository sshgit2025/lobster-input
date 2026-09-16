#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""custom_dict v2(61万内置自定义词)专属验证电池。

A. 数据完整性:生成文件与主词库零重复、格式合法、biang showcase 保留
B. 引擎去重健壮性:人为注入与主词库重复的词 → merged 按词去重只保留一条(不重复展示)
C. 新词可达性:精选热词 + 各层随机抽样,26键/T9 打全必可达(保底机制)
D. 主词库排序零回归(九宫格正向核心):高频主词(lv>=160)26键/T9 top-1 与无自定义词库时完全一致
E. 性能:渐进击键 26键/T9 单步耗时(py参照,Kotlin/Swift/ArkTS 快约10x)
"""
import os
import random
import time

import engine_v3
from engine_v3 import load_engine_v3, CustomTable, EngineV3
from engine_v2 import load_engine_v2
from engine import to_digits, load_engine

HERE = os.path.dirname(os.path.abspath(__file__))
CUSTOM_PATH = engine_v3.DEFAULT_CUSTOM

fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")
    if not ok:
        fails.append(name)


e3 = load_engine_v3()
e2 = load_engine_v2()  # 对照:无海量自定义词库(legacy 1词 custom)

# ===== A. 数据完整性 =====
main_words = set()
for idx in range(len(e3.dict.full.keys)):
    for w, _ in e3.dict.full.words_at(idx):
        main_words.add(w)
custom_entries = []  # (key, word, lv)
dup = []
for idx in range(len(e3.custom.table.keys)):
    key = e3.custom.table.keys[idx]
    for w, lv in e3.custom.table.words_at(idx):
        custom_entries.append((key, w, lv))
        if w in main_words:
            dup.append(w)
check("A1 与主词库零重复", not dup, f"重复数={len(dup)} 例={dup[:5]}")
check("A2 词条规模", len(custom_entries) >= 600_000, f"n={len(custom_entries)}")
def valid_backtrack(key, sylls, max_len):
    """回溯切分校验(贪心最长匹配会误判 zuoleyinianduo:zuo|le|yin|ianduo 死路,
    实际 zuo|le|yi|nian|duo 合法——各端 CustomDictionary 加载器不得用贪心校验丢词)。"""
    n = len(key)
    stack = [0]
    seen = set()
    while stack:
        pos = stack.pop()
        if pos == n:
            return True
        if pos in seen:
            continue
        seen.add(pos)
        for L in range(min(max_len, n - pos), 0, -1):
            if key[pos:pos + L] in sylls:
                stack.append(pos + L)
    return False

bad_syll = [k for k, w, _ in random.Random(7).sample(custom_entries, 3000)
            if not valid_backtrack(k, e3.dict.syllables, e3.dict.max_syllable_len)]
check("A3 拼音键全部合法音节(抽样3000,回溯切分)", not bad_syll, f"{bad_syll[:3]}")
check("A4 biang showcase 保留", ("biangbiangmian", "\U00030EDE\U00030EDE面", 500) in custom_entries)
inner_dup = len(custom_entries) - len({w for _, w, _ in custom_entries})
check("A5 自定义词库内部按词无重复", inner_dup == 0, f"重词条数={inner_dup}")

# ===== B. 引擎去重健壮性(用户要求顺带验证:假如有重复词会怎样) =====
# 人为构造一个与主词库重复的词注入自定义表 → 候选中该词只出现一次(merged 按词去重取高分)
tmp = os.path.join(HERE, "_tmp_dup_custom.txt")
with open(tmp, "w", encoding="utf-8") as f:
    f.write("nihao\t你好 150\n")  # 你好 必在主词库
e_dup = load_engine_v3(custom_path=tmp)
c26 = [c.word for c in e_dup.candidates("nihao", 50)]
ct9 = [c.word for c in e_dup.candidates_for_t9(to_digits("nihao"), 50)]
check("B1 重复词26键只展示一次", c26.count("你好") == 1, f"count={c26.count('你好')}")
check("B2 重复词T9只展示一次", ct9.count("你好") == 1, f"count={ct9.count('你好')}")
check("B3 重复词仍居首(高分保留)", c26[0] == "你好" and ct9[0] == "你好")
os.remove(tmp)

# ===== C. 新词可达性 =====
HOT_CASES = [("neijuan", "内卷"), ("bailan", "摆烂"), ("tangping", "躺平"),
             ("aoligei", "奥利给"), ("juejuezi", "绝绝子"), ("xianyanbao", "显眼包"),
             ("yuanshen", "原神"), ("shehuixingsiwang", "社会性死亡"),
             ("dagongren", "打工人"), ("jiarenmen", "家人们"), ("yaoyaolingxian", "遥遥领先")]
miss26, misst9 = [], []
for py, w in HOT_CASES:
    if w not in [c.word for c in e3.candidates(py, 10)][:5]:
        miss26.append((py, w))
    if w not in [c.word for c in e3.candidates_for_t9(to_digits(py))][:10]:
        misst9.append((py, w))
check("C1 精选热词26键top5可达", not miss26, f"{miss26}")
check("C2 精选热词T9 top10可达", not misst9, f"{misst9}")

# 全库随机抽样:打全拼音/数字码必可达(保底机制)
rng = random.Random(42)
sample = rng.sample(custom_entries, 400)
un26, unt9 = [], []
for key, w, lv in sample:
    if w not in {c.word for c in e3.candidates(key, 100000)}:
        un26.append((key, w))
for key, w, lv in rng.sample(custom_entries, 150):
    if w not in {c.word for c in e3.candidates_for_t9(to_digits(key), 100000)}:
        unt9.append((key, w))
check("C3 随机400词26键打全必可达", not un26, f"{un26[:5]}")
check("C4 随机150词T9打全必可达", not unt9, f"{unt9[:5]}")
check("C5 biang 26键top1", e3.candidates("biangbiangmian", 5)[0].word == "\U00030EDE\U00030EDE面")
t9b = [c.word for c in e3.candidates_for_t9(to_digits("biangbiangmian"), 10)]
check("C6 biang T9 top3", "\U00030EDE\U00030EDE面" in t9b[:3], f"{t9b[:3]}")

# ===== D. 主词库排序零回归(九宫格正向核心) =====
hi_words = []  # (key, word) 主词库高频词
for idx in range(len(e3.dict.full.keys)):
    key = e3.dict.full.keys[idx]
    ws = e3.dict.full.words_at(idx)
    if ws and ws[0][1] >= 160 and 2 <= len(ws[0][0]) <= 4 and key.isalpha():
        hi_words.append((key, ws[0][0]))
rng2 = random.Random(9)
battery = rng2.sample(hi_words, 400)
# 回归判定:V2 top1 是被保护词 w 而 V3 top1 不是 → 回归;
# V3 top1 变为 w(V2 原本就错,如 行才→刚才)→ 正向翻转,记录不判罚。
flip26, flipt9, gain26, gaint9 = [], [], [], []
for key, w in battery:
    t2 = e2.candidates(key, 3)
    t3 = e3.candidates(key, 3)
    if t2 and t3 and t2[0].word != t3[0].word:
        if t2[0].word == w and t3[0].word != w:
            flip26.append((key, t2[0].word, t3[0].word))
        elif t3[0].word == w:
            gain26.append((key, t2[0].word, t3[0].word))
for key, w in battery[:200]:
    d = to_digits(key)
    e2.t9_cache.clear()
    e3.t9_cache.clear()
    t2 = e2.candidates_for_t9(d, 3)
    t3 = e3.candidates_for_t9(d, 3)
    if t2 and t3 and t2[0].word != t3[0].word:
        if t2[0].word == w and t3[0].word != w:
            flipt9.append((key, t2[0].word, t3[0].word))
        elif t3[0].word == w:
            gaint9.append((key, t2[0].word, t3[0].word))
check("D1 高频主词26键top1零回归(400)", not flip26, f"回归={flip26[:6]} 正向翻转={len(gain26)}")
check("D2 高频主词T9 top1零回归(200)", not flipt9, f"回归={flipt9[:6]} 正向翻转={len(gaint9)}例如{gaint9[:3]}")

# ===== E. 性能(渐进击键,py参照) =====
def bench(fn, seqs):
    t_max = t_sum = n = 0
    for seq in seqs:
        for i in range(1, len(seq) + 1):
            t0 = time.time()
            fn(seq[:i])
            dt = time.time() - t0
            t_max = max(t_max, dt)
            t_sum += dt
            n += 1
    return t_max * 1000, t_sum / n * 1000

seqs26 = ["woxiangchifan", "shehuixingsiwang", "zhegezhoumoqunar", "nihaoshijie"]
seqst9 = [to_digits(s) for s in seqs26]
e3.t9_cache.clear()
mx26, avg26 = bench(lambda s: e3.candidates(s), seqs26)
mxt9, avgt9 = bench(lambda s: e3.candidates_for_t9(s), seqst9)
check("E1 26键单步性能", mx26 < 80, f"max={mx26:.1f}ms avg={avg26:.1f}ms(阈80ms,py参照)")
check("E2 T9单步性能", mxt9 < 80, f"max={mxt9:.1f}ms avg={avgt9:.1f}ms(阈80ms,py参照)")
t0 = time.time()
ct = CustomTable()
ct.load(CUSTOM_PATH)
check("E3 自定义表加载(py参照)", time.time() - t0 < 30, f"{time.time()-t0:.1f}s(原生快约10x,且异步挂载不阻塞冷启动)")

print()
print("=" * 60)
print("全部通过" if not fails else f"失败 {len(fails)} 项: {fails}")
import sys
sys.exit(0 if not fails else 1)
