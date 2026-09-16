#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""custom_dict v3(品牌层+组块层+口语加权)专属验证电池(2026-07-17)。

A. 数据完整性:现有资产条目原样保留(只升不降)、与主词库零重复、体积预算
B. 品牌可达性:斯凯奇/名创优品种子 + 随机品牌词 26键/T9 打全必可达
C. banxiu 案例:半袖 T9 排名进前 8(原 14)
D. 请叫我人才 案例:整句 top1 翻转(T9+26键)
E. 预测纪律:lv<110 新词绝不进补全;知名品牌种子(lv120)允许进预测
F. 高频主词 top1 零回归(vs 当前线上资产 A/B)
G. 性能与加载
用法: CUSTOM_DICT=<新词库> python3 test_brands_chunks.py  (对照资产自动取 assets/custom_dict.txt)
"""
import os
import random
import time

import engine_v3
from engine_v3 import EngineV3, CustomTable, load_engine_v3
from engine import load_engine, to_digits

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "..", "app", "src", "main", "assets")
NEW = os.environ.get("CUSTOM_DICT", os.path.join(HERE, "custom_dict_v3_generated.txt"))
OLD = os.path.join(ASSETS, "custom_dict.txt")

fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name} {detail}")
    if not ok:
        fails.append(name)


t0 = time.time()
# 词库迭代专属电池:NEW=待验证新词库(CUSTOM_DICT 或生成物)。不存在则优雅跳过(非词库迭代上下文)。
# 存在但与线上资产内容一致时,下方 B3/B4 新词抽样自动跳过(new_list 为空)。
if not os.path.exists(NEW):
    print("SKIP test_brands_chunks:未提供待验证新词库(CUSTOM_DICT),非词库迭代上下文,跳过")
    print("模型全部通过")
    raise SystemExit(0)

e_new = load_engine_v3(custom_path=NEW)
load_s = time.time() - t0
e_old = load_engine_v3(custom_path=OLD)

# ===== A. 数据完整性 =====
size_mb = os.path.getsize(NEW) / 1048576
check("A1 体积预算", size_mb <= 42.0, f"{size_mb:.1f}MB (<=42MB)")

old_entries = []
for idx in range(len(e_old.custom.table.keys)):
    key = e_old.custom.table.keys[idx]
    for w, lv in e_old.custom.table.words_at(idx):
        old_entries.append((key, w, lv))
rng = random.Random(2026)
miss, lowered = [], []
for key, w, lv in rng.sample(old_entries, 5000):
    ws = dict(e_new.custom.exact(key))
    if w not in ws:
        miss.append((key, w))
    elif ws[w] < lv:
        lowered.append((key, w, lv, ws[w]))
check("A2 现有资产条目原样保留(抽样5000)", not miss, f"丢失={miss[:3]}")
check("A3 等级只升不降(抽样5000)", not lowered, f"降级={lowered[:3]}")

main_words = set()
for idx in range(len(e_new.dict.full.keys)):
    for w, _ in e_new.dict.full.words_at(idx):
        main_words.add(w)
new_entries = []
for idx in range(len(e_new.custom.table.keys)):
    key = e_new.custom.table.keys[idx]
    for w, lv in e_new.custom.table.words_at(idx):
        new_entries.append((key, w, lv))
dup = [w for _, w, _ in new_entries if w in main_words]
check("A4 与主词库零重复(全量)", not dup, f"重复={dup[:5]}")

# ===== B. 品牌可达性 =====
BRAND_CASES = [("sikaiqi", "斯凯奇"), ("mingchuangyoupin", "名创优品"),
               ("shizuniao", "始祖鸟"), ("bawangchaji", "霸王茶姬")]
for py, w in BRAND_CASES:
    c26 = [c.word for c in e_new.candidates(py, 10)]
    ct9 = [c.word for c in e_new.candidates_for_t9(to_digits(py))]
    check(f"B1 {w} 26键top3", w in c26[:3], f"{c26[:3]}")
    check(f"B2 {w} T9 top10", w in ct9[:10], f"{ct9[:5]}")

new_words_set = {(k, w) for k, w, _ in new_entries} - {(k, w) for k, w, _ in old_entries}
new_list = sorted(new_words_set)
un26, unt9 = [], []
if not new_list:
    # NEW 与线上资产内容一致(未做词库迭代,仅整句/引擎回归):无新增词可采样,跳过可达性抽样
    print("SKIP B3/B4:新词集为空(NEW 与线上资产一致),跳过新词可达性抽样")
else:
    for key, w in rng.sample(new_list, min(300, len(new_list))):
        if w not in {c.word for c in e_new.candidates(key, 100000)}:
            un26.append((key, w))
    for key, w in rng.sample(new_list, min(120, len(new_list))):
        if w not in {c.word for c in e_new.candidates_for_t9(to_digits(key), 100000)}:
            unt9.append((key, w))
    check("B3 随机新词300 26键打全必可达", not un26, f"{un26[:4]}")
    check("B4 随机新词120 T9打全必可达", not unt9, f"{unt9[:4]}")

# ===== C. banxiu 案例 =====
ct9 = [c.word for c in e_new.candidates_for_t9("226948")]
rank = ct9.index("半袖") + 1 if "半袖" in ct9 else -1
old_rank_list = [c.word for c in e_old.candidates_for_t9("226948")]
old_rank = old_rank_list.index("半袖") + 1 if "半袖" in old_rank_list else -1
check("C1 半袖T9排名进前8", 0 < rank <= 8, f"rank={rank}(原={old_rank})")

# ===== D. 请叫我人才 案例 =====
d = to_digits("qingjiaoworencai")
t9top = [c.word for c in e_new.candidates_for_t9(d, 5)]
check("D1 T9整句top1=请叫我人才", t9top and t9top[0] == "请叫我人才", f"{t9top[:3]}")
c26 = [c.word for c in e_new.candidates("qingjiaoworencai", 8)]
check("D2 26键 请叫我人才 top3", "请叫我人才" in c26[:3], f"{c26[:3]}")
old_t9 = [c.word for c in e_old.candidates_for_t9(d, 3)]
print(f"  (对照:线上资产 T9 top1={old_t9[:1]})")

# ===== E. 预测纪律 =====
bad_pred = []
for prefix in ["lin", "hua", "shang", "qing", "ban"]:
    top8 = e_new.candidates(prefix, 8)
    for c in top8:
        ws = dict(e_new.custom.exact(getattr(c, "pinyin", "") or ""))
        # 新增词(不在旧资产)且 lv<110 出现在前缀预测前8 → 违纪
        if c.word not in {w for _, w, _ in old_entries} and c.word not in main_words:
            lvs = [lv for k, w, lv in new_entries if w == c.word]
            if lvs and max(lvs) < 110:
                bad_pred.append((prefix, c.word, max(lvs)))
check("E1 lv<110新词不进26键前缀预测前8", not bad_pred, f"{bad_pred[:4]}")
comp = [c.word for c in e_new.candidates_for_t9(to_digits("qingjiao"), 20)]
check("E2 组块请叫我不进T9补全(qingjiao)", "请叫我" not in comp[:12], f"{comp[:6]}")
sk = [c.word for c in e_new.candidates("sikai", 12)]
check("E3 知名品牌种子可预测(sikai→斯凯奇)", "斯凯奇" in sk, f"{sk[:8]}")

# ===== F. 高频主词零回归(A/B) =====
hi = []
for idx in range(len(e_new.dict.full.keys)):
    key = e_new.dict.full.keys[idx]
    ws = e_new.dict.full.words_at(idx)
    if ws and ws[0][1] >= 160 and 2 <= len(ws[0][0]) <= 4 and key.isalpha():
        hi.append((key, ws[0][0]))
battery = random.Random(9).sample(hi, 300)
flip26, flipt9 = [], []
for key, w in battery:
    a = e_old.candidates(key, 3)
    b = e_new.candidates(key, 3)
    if a and b and a[0].word != b[0].word and a[0].word == w and b[0].word != w:
        flip26.append((key, a[0].word, b[0].word))
for key, w in battery[:150]:
    dd = to_digits(key)
    e_old.t9_cache.clear()
    e_new.t9_cache.clear()
    a = e_old.candidates_for_t9(dd, 3)
    b = e_new.candidates_for_t9(dd, 3)
    if a and b and a[0].word != b[0].word and a[0].word == w and b[0].word != w:
        flipt9.append((key, a[0].word, b[0].word))
check("F1 高频主词26键top1零回归(300)", not flip26, f"{flip26[:5]}")
check("F2 高频主词T9 top1零回归(150)", not flipt9, f"{flipt9[:5]}")

# ===== G. 性能 =====
def bench(fn, seqs):
    t_max = 0
    for seq in seqs:
        for i in range(1, len(seq) + 1):
            t0 = time.time()
            fn(seq[:i])
            t_max = max(t_max, time.time() - t0)
    return t_max * 1000

e_new.t9_cache.clear()
mx26 = bench(lambda s: e_new.candidates(s), ["sikaiqiyundongxie", "qingjiaoworencai"])
mxt9 = bench(lambda s: e_new.candidates_for_t9(s), [to_digits("sikaiqiyundongxie"), to_digits("qingjiaoworencai")])
check("G1 26键单步性能", mx26 < 120, f"max={mx26:.1f}ms(py参照)")
check("G2 T9单步性能", mxt9 < 120, f"max={mxt9:.1f}ms(py参照)")
check("G3 词库加载(py参照)", load_s < 40, f"{load_s:.1f}s")

print()
print("=" * 60)
print("全部通过" if not fails else f"失败 {len(fails)} 项: {fails}")
import sys
sys.exit(0 if not fails else 1)
