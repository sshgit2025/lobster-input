#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
基于成熟开源词库 rime-ice(雾凇拼音)生成键盘所用紧凑词库(全拼 + 首字母简拼)。
源: cn_dicts/8105.dict.yaml(单字) + cn_dicts/base.dict.yaml(基础词)
源格式: 词\t拼音(空格分隔音节)\t词频   (拼音人工标注, ü/üe 已写作 v/ve)

输出(两端复用):
  pinyin_dict.txt    全拼连写key \t 词1 词频等级1 ...   (候选按词频降序)
  initials_dict.txt  首字母简拼key \t 词1 词频等级1 ... (支持 cs→测试, nh→你好, 全拼/9宫格简拼)
  syllables.txt      合法拼音音节集合
"""
import math, os, re

# 工作目录:输入 rime_8105.yaml / rime_base.yaml 与输出文件都在当前目录(见 README 复现步骤)
HERE = os.getcwd()

def parse_rime(path):
    rows = []
    with open(path, encoding='utf-8') as f:
        started = False
        for line in f:
            if not started:
                if '\t' in line and not line.startswith('#'):
                    started = True
                else:
                    continue
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            parts = line.split('\t')
            if len(parts) < 2:
                continue
            word = parts[0]
            pys = parts[1].strip()
            freq = 0
            if len(parts) >= 3:
                m = re.match(r'^(\d+)', parts[2].strip())
                if m:
                    freq = int(m.group(1))
            rows.append((word, pys, freq))
    return rows

singles = parse_rime(f"{HERE}/rime_8105.yaml")
words = parse_rime(f"{HERE}/rime_base.yaml")

syllables = set()
for w, pys, fr in singles:
    for s in pys.split():
        if re.fullmatch(r'[a-z]+', s):
            syllables.add(s)
for w, pys, fr in words:
    for s in pys.split():
        if re.fullmatch(r'[a-z]+', s) and 1 <= len(s) <= 6:
            syllables.add(s)

def level(freq):
    return int(round(math.log2(freq + 1) * 10)) if freq > 0 else 0

# ---------- 全拼主表 ----------
table = {}
def add(tbl, key, word, freq):
    if not key or not word:
        return
    d = tbl.setdefault(key, {})
    if word not in d or d[word] < freq:
        d[word] = freq

for w, pys, fr in singles:
    if len(w) != 1:
        continue
    syl = pys.split()
    if len(syl) != 1:
        continue
    add(table, syl[0], w, max(fr, 1))

words_clean = []
for w, pys, fr in words:
    if not (2 <= len(w) <= 8 and fr >= 2):
        continue
    syl = pys.split()
    if not all(re.fullmatch(r'[a-z]+', s) for s in syl):
        continue
    words_clean.append((w, syl, fr))

words_clean.sort(key=lambda x: -x[2])
MAX_WORDS = 200000
for w, syl, fr in words_clean[:MAX_WORDS]:
    add(table, ''.join(syl), w, fr)

# ---------- 首字母简拼表 ----------
# 业界做法: 输入声母首字母即出词(全拼/简拼混合)。重码多, 故每 key 仅取高频 top N。
initials = {}
INIT_MIN_FREQ = 45
MAX_INIT_CAND = 20
for w, syl, fr in words_clean:
    if fr < INIT_MIN_FREQ:
        continue
    if not (2 <= len(syl) <= 5):
        continue
    init = ''.join(s[0] for s in syl)
    if len(init) < 2:
        continue
    add(initials, init, w, fr)

def dump(tbl, path, max_cand=None):
    lines = []
    for key in sorted(tbl.keys()):
        cands = sorted(tbl[key].items(), key=lambda x: -x[1])
        if max_cand:
            cands = cands[:max_cand]
        toks = []
        for word, fr in cands:
            toks.append(word)
            toks.append(str(level(fr)))
        lines.append(key + '\t' + ' '.join(toks))
    with open(path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    return len(lines)

# 全拼主表【绝不截断】:曾经 top-30/key 导致 yi 的第 31+ 位单字(咦/呓/翊…)整库丢失、
# 用户无论如何打不出(2026-07 事故)。全量保留仅 +0.02MB(超 30 候选的 key 全库仅 85 个),
# 可达性由 UI 滚动/展开面板(等效 RIME 翻页)+ 运行时 CAND_LIMIT 保证。
# 简拼表保持 top-N:简拼是重码"预测"通道,业界只出高频;全拼通道始终可打出任意字,不伤可达性。
n_full = dump(table, f"{HERE}/pinyin_dict.txt")
n_init = dump(initials, f"{HERE}/initials_dict.txt", MAX_INIT_CAND)
with open(f"{HERE}/syllables.txt", 'w', encoding='utf-8') as f:
    f.write('\n'.join(sorted(syllables)) + '\n')

print(f"全拼 key: {n_full}")
print(f"简拼 key: {n_init}")
print(f"合法音节: {len(syllables)}")
