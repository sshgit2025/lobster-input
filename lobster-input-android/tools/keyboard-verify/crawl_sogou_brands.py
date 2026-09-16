#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""T6 品牌层:搜狗细胞词库爬取(按关键词全类目搜索)→ scel 解析 → 合并 brand_words.tsv。

用法:
  python3 crawl_sogou_brands.py --out-dir <数据目录>   # 数据目录放 scel 缓存与产物,不进 git
产物:
  <out-dir>/brand_words.tsv   词\t音节(空格分隔)\t来源词库id  按来源优先级排好序(下载量降序)

注意:
  - 搜狗搜索 URL 关键词须 GBK 编码;本机 CA 缺失须 ssl 不校验(同 T5 爬取)。
  - 详情页有词条数/下载次数;过滤:下载次数>=DL_MIN 或标题含「品牌/大全」——搜索结果里
    大量单店铺小词库(几十词)长尾噪音,靠下载量做质量门槛。
  - scel 音节边界为人工标注,输出保留空格分隔,下游勿贪心重切。
"""
import argparse
import os
import re
import ssl
import time
import urllib.parse
import urllib.request

from sogou_scel import parse_scel

CTX = ssl._create_unverified_context()
UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/126.0"}

# 抓取入口设计(2026-07-17 业界调研结论,来源见 CUSTOM_DICT_V2_DESIGN.md T6 节):
# 1) 搜狗搜索是**整串匹配**——组合词("运动品牌")命中为 0,必须用单词/已验证短语;
# 2) 品牌词库无独立一级类目,分散在:娱乐>时尚品牌428/汽车432、生活>美容护肤395/服饰397/
#    家用电器394/饮食402;顺带补齐调研 P1 缺口:电影电视426/明星429/电子游戏436/动漫404。
# 3) 单店铺自建小词库是长尾噪音,靠下载量阈值 + 标题词过滤。
CATES = [428, 432, 395, 397, 394, 402, 426, 429, 436, 404]  # 类目遍历(下载量排序页)
MAX_CATE_PAGES = 5
KEYWORDS = [  # 站内搜索聚合(整串匹配,须为真实可命中词)
    "品牌", "品牌大全", "知名品牌", "商标", "奢侈品", "名牌",
    "手机", "数码", "家电", "球鞋", "潮牌", "零食", "饮料", "母婴", "珠宝", "名表",
    "化妆品", "护肤", "香水", "服装", "汽车", "车型", "轮胎", "白酒", "啤酒", "咖啡",
    "奶茶", "快餐", "超市", "家具", "卫浴", "玩具", "文具", "宠物", "保健品",
]
MAX_PAGES_PER_KW = 3
DL_MIN = 100
TITLE_PASS = ("品牌", "大全", "名牌", "商标")


def get(url, binary=False, retry=3):
    for i in range(retry):
        try:
            req = urllib.request.Request(url, headers=UA)
            d = urllib.request.urlopen(req, context=CTX, timeout=30).read()
            return d if binary else d.decode("utf-8", "ignore")
        except Exception:
            if i == retry - 1:
                raise
            time.sleep(1.5 * (i + 1))


def search_ids(kw):
    """搜索一个关键词,返回 [(id, title)](去重保序)。"""
    out = []
    seen = set()
    q = urllib.parse.quote(kw.encode("gbk"))
    for page in range(1, MAX_PAGES_PER_KW + 1):
        try:
            h = get(f"https://pinyin.sogou.com/dict/search/search_list/{q}/normal/{page}")
        except Exception:
            break
        blocks = re.findall(r'detail/index/(\d+)"[^>]*>([^<]+)<', h)
        if not blocks:
            break
        for did, title in blocks:
            if did not in seen:
                seen.add(did)
                out.append((did, title.strip()))
    return out


def cate_ids(cate):
    """类目页遍历(按默认排序逐页),返回 [(id, title)]。
    类目列表页不放 detail 链接,直接给 download_cell.php?id=..&name=..(name 为 UTF-8 urlencode)。"""
    out = []
    seen = set()
    for page in range(1, MAX_CATE_PAGES + 1):
        try:
            h = get(f"https://pinyin.sogou.com/dict/cate/index/{cate}/default/{page}")
        except Exception:
            break
        blocks = re.findall(r'download_cell\.php\?id=(\d+)&name=([^"&]+)', h)
        if not blocks:
            break
        for did, name in blocks:
            if did not in seen:
                seen.add(did)
                out.append((did, urllib.parse.unquote(name).strip()))
    return out


def detail_meta(did):
    """详情页:返回 (下载次数, 词条数, 标题) ,失败返回 (0,0,'')。"""
    try:
        h = get(f"https://pinyin.sogou.com/dict/detail/index/{did}")
    except Exception:
        return 0, 0, ""
    dl = re.search(r"下\s*载\s*次\s*数[::]?\s*</[^>]+>\s*<[^>]+>\s*(\d+)", h) or re.search(r"下载次数[^0-9]{0,40}(\d+)", h)
    wc = re.search(r"词\s*条\s*数[::]?[^0-9]{0,40}(\d+)", h)
    ti = re.search(r"<title>([^<_]+)", h)
    return (int(dl.group(1)) if dl else 0,
            int(wc.group(1)) if wc else 0,
            ti.group(1).strip() if ti else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--dl-min", type=int, default=DL_MIN)
    args = ap.parse_args()
    os.makedirs(os.path.join(args.out_dir, "scel"), exist_ok=True)

    # 1) 类目遍历 + 搜索收集候选词库(类目词库天然可信,免下载量过滤)
    cands = {}
    cate_set = set()
    for c in CATES:
        for did, title in cate_ids(c):
            cands.setdefault(did, title)
            cate_set.add(did)
        print(f"  类目 {c}: 累计 {len(cands)}")
        time.sleep(0.3)
    for kw in KEYWORDS:
        for did, title in search_ids(kw):
            cands.setdefault(did, title)
        time.sleep(0.3)
    print(f"候选词库 {len(cands)} 个(类目 {len(cate_set)})")

    # 2) 详情过滤 + 下载(类目来源直通;搜索来源按下载量/标题过滤)
    picked = []
    for i, (did, title) in enumerate(sorted(cands.items(), key=lambda kv: int(kv[0]))):
        dl, wc, _ = detail_meta(did)
        title_ok = any(t in title for t in TITLE_PASS)
        if did not in cate_set and dl < args.dl_min and not title_ok:
            continue
        picked.append((dl, did, title, wc))
        if i % 50 == 0:
            print(f"  详情进度 {i}/{len(cands)} 已选 {len(picked)}")
        time.sleep(0.2)
    picked.sort(reverse=True)  # 下载量降序 = 合并优先级
    print(f"过滤后 {len(picked)} 个词库(dl_min={args.dl_min} 或标题含品牌/大全)")

    # 3) 下载 scel(带本地缓存)+ 解析合并
    out_path = os.path.join(args.out_dir, "brand_words.tsv")
    seen_words = set()
    n_rows = 0
    with open(out_path, "w", encoding="utf-8") as out:
        for dl, did, title, wc in picked:
            scel_path = os.path.join(args.out_dir, "scel", f"{did}.scel")
            if not os.path.exists(scel_path):
                try:
                    q = urllib.parse.quote(title.encode("gbk", "ignore"))
                    data = get(f"https://pinyin.sogou.com/d/dict/download_cell.php?id={did}&name={q}", binary=True)
                    with open(scel_path, "wb") as f:
                        f.write(data)
                    time.sleep(0.4)
                except Exception as e:
                    print(f"  下载失败 {did} {title}: {e}")
                    continue
            try:
                with open(scel_path, "rb") as f:
                    data = f.read()
                for word, sylls in parse_scel(data):
                    if word in seen_words:
                        continue
                    seen_words.add(word)
                    out.write(f"{word}\t{' '.join(sylls)}\t{did}\n")
                    n_rows += 1
            except Exception as e:
                print(f"  解析失败 {did} {title}: {e}")
    print(f"输出 {out_path}: {n_rows} 词(来源 {len(picked)} 词库,下载量降序优先去重)")


if __name__ == "__main__":
    main()
