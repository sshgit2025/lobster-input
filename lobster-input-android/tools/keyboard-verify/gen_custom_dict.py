#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成产品内置自定义扩展词库 custom_dict.txt v2(纯追加式,与主词库零重复)。

词汇来源(同词取先入者):
  T1 base残余   rime-ice base.dict.yaml 中被主词库构建 top200k 截断的词(freq 2~1755,
                真实词频+人工拼音)——用户感知"常用词缺失"的主要来源
  T2 ext扩展    rime-ice ext.dict.yaml 全量(网络热词/流行语/新词/专名;词频扁平100,
                有 jieba 词频者经线性标定映射,无则默认 level)
  T3 jieba缺词  jieba 高频(>=1000)但主词库/T1/T2 均未覆盖的词(拼音从 base/ext/tencent 反查)
  T5 专有名词   搜狗官方"城市信息"细胞词库(行政区划/道路交通/单位机构/风景名胜 + 31省
                城市词库,人工标注拼音;2026-07 任务:林萃西里/华创生活广场类地名店名打不出)。
                源:pinyin.sogou.com 分类 181/182/183/184 + 各省子分类按下载量前3页,
                爬取/解析/合并脚本在会话 scratchpad dict-src-poi/(crawl_sogou.py + merge_poi.py),
                产物 poi_words.tsv(词\t音节空格分隔\t来源id)由 --poi-src 传入。
                level 默认 40(长尾专名):打全必可达(全消耗保底),又低于补全预测门槛
                lv>=110(绝不污染联想/补全),且远低于 155 cap(不碰主词库排序)。

规则:
  - 词不得与主词库(pinyin_dict.txt)任何 key 下已有词重复(生成期零重复,硬性要求)
  - 词长 2-8、全 CJK;拼音可完整切分为合法音节(syllables.txt)且可映射 T9 数字码
  - 词频等级与主词库同量纲(level = round(log2(freq+1)*10));T1 用原生 rime 词频直算,
    T2/T3 的 jieba 词频经主词库交集最小二乘标定(level ≈ a + b*log2(jf+1)),上限截断
  - 保留既有词条 biangbiangmian→𰻞𰻞面(500,置顶示例)

输出(与主词库 pinyin_dict.txt 同格式,供 CustomDictionary 字节表直查):
  custom_dict_generated.txt   每行: 拼音连写key\t词1 lv1 词2 lv2 ...(key 升序;key 内按 lv 降序)

用法:
  python3 gen_custom_dict.py [--out PATH] [--flat-out PATH]
环境变量:
  DICT_SRC  词库源目录(含 base/ext/tencent.dict.yaml 与 jieba_dict.txt;默认见 DEFAULT_SRC)
词库源复现:
  curl -LO https://raw.githubusercontent.com/iDvel/rime-ice/main/cn_dicts/{base,ext,tencent}.dict.yaml
  curl -L -o jieba_dict.txt https://cdn.jsdelivr.net/gh/fxsjy/jieba@master/jieba/dict.txt
"""
import argparse
import math
import os
import re
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "..", "..", "app", "src", "main", "assets")
DEFAULT_SRC = os.environ.get(
    "DICT_SRC",
    "/private/tmp/claude-501/-Users-sunshaohua-workspace-swiftProjects-lobster-input/"
    "4cf6599b-19ab-472f-b647-875cb7780311/scratchpad/dict-src",
)

CJK_RE = re.compile(r'^[〇㐀-䶿一-鿿豈-﫿\U00020000-\U0003FFFF]+$')

# 精选现代热词/口语加权层(2020-2026 网络流行语/梗/口语,人工校对拼音,ü→v):
# jieba 词频表(2013 年代语料)不含这些新词,默认 level 55 会被同数字码的主词库旧词压住
# (如 neijuan=6345826 与 内乱/美娟 同码)。此清单把词提到 HOT_LEVEL,与中高频主词同档。
# 仅对"主词库没有"的词生效(与主词库重复的自动跳过,零重复原则不变)。
HOT_LEVEL = 142
HOT_WORDS = {
    "内卷": "neijuan", "摆烂": "bailan", "躺平": "tangping", "社死": "shesi",
    "内耗": "neihao", "精神内耗": "jingshenneihao", "搭子": "dazi", "饭搭子": "fandazi",
    "显眼包": "xianyanbao", "泼天富贵": "potianfugui", "尊嘟假嘟": "zundujiadu",
    "绝绝子": "juejuezi", "奥利给": "aoligei", "夺笋": "duosun", "干饭": "ganfan",
    "干饭人": "ganfanren", "打工人": "dagongren", "工具人": "gongjuren",
    "氛围感": "fenweigan", "松弛感": "songchigan", "边界感": "bianjiegan",
    "钝感力": "dunganli", "情绪价值": "qingxujiazhi", "双向奔赴": "shuangxiangbenfu",
    "整活": "zhenghuo", "下头": "xiatou", "开摆": "kaibai", "内娱": "neiyu",
    "吃瓜": "chigua", "吃瓜群众": "chiguaqunzhong", "官宣": "guanxuan", "塌房": "tafang",
    "磕到了": "kedaole", "嗑糖": "ketang", "卷王": "juanwang", "脆皮": "cuipi",
    "红温": "hongwen", "硬控": "yingkong", "班味": "banwei", "偷感": "tougan",
    "老登": "laodeng", "小孩哥": "xiaohaige", "小孩姐": "xiaohaijie",
    "特种兵旅游": "tezhongbinglvyou", "多巴胺穿搭": "duobaanchuanda",
    "美拉德": "meilade", "搞抽象": "gaochouxiang", "发疯文学": "fafengwenxue",
    "废话文学": "feihuawenxue", "电子榨菜": "dianzizhacai", "电子木鱼": "dianzimuyu",
    "赛博": "saibo", "赛博朋克": "saibopengke", "元宇宙": "yuanyuzhou",
    "数字游民": "shuziyoumin", "直播带货": "zhibodaihuo", "云监工": "yunjiangong",
    "种草": "zhongcao", "拔草": "bacao", "避雷": "bilei", "踩雷": "cailei",
    "劝退": "quantui", "咱就是说": "zanjiushishuo", "一整个": "yizhengge",
    "无语子": "wuyuzi", "麻了": "male", "蚌埠住了": "bengbuzhule",
    "绷不住了": "bengbuzhule", "泪目": "leimu", "心巴": "xinba", "老铁": "laotie",
    "家人们": "jiarenmen", "集美": "jimei", "宝子": "baozi", "冲鸭": "chongya",
    "奈斯": "naisi", "芜湖": "wuhu", "拉胯": "lakua", "拉垮": "lakua",
    "顶流": "dingliu", "断层第一": "duancengdiyi", "遥遥领先": "yaoyaolingxian",
    "格局打开": "gejudakai", "破圈": "poquan", "出圈": "chuquan", "圈粉": "quanfen",
    "脱粉": "tuofen", "素人": "suren", "平替": "pingti", "白月光": "baiyueguang",
    "朱砂痣": "zhushazhi", "意难平": "yinanping", "拿来吧你": "nalaibani",
    "永远的神": "yongyuandeshen", "无敌了": "wudile", "六边形战士": "liubianxingzhanshi",
    "天选之人": "tianxuanzhiren", "欧皇": "ouhuang", "非酋": "feiqiu",
    "血亏": "xuekui", "血赚": "xuezhuan", "大冤种": "dayuanzhong", "冤种": "yuanzhong",
    "纯爱战士": "chunaizhanshi", "社恐": "shekong", "社牛": "sheniu",
    "发癫": "fadian", "嘴替": "zuiti", "课代表": "kedaibiao", "划重点": "huazhongdian",
    "敲黑板": "qiaoheiban", "萌新": "mengxin", "老六": "laoliu", "挂机": "guaji",
    "开黑": "kaihei", "上分": "shangfen", "氪金": "kejin", "白嫖": "baipiao",
    "佛系": "foxi", "躺赢": "tangying", "躺枪": "tangqiang", "背锅": "beiguo",
    "甩锅": "shuaiguo", "实锤": "shichui", "下饭": "xiafan", "网抑云": "wangyiyun",
    "云玩家": "yunwanjia", "嘴强王者": "zuiqiangwangzhe", "菜就多练": "caijiuduolian",
    "菜狗": "caigou", "烂尾娃": "lanweiwa", "鸡娃": "jiwa", "牛马": "niuma",
    "洗脑循环": "xinaoxunhuan", "口水歌": "koushuige", "整不会了": "zhengbuhuile",
    "整挺好": "zhengtinghao", "支棱起来": "zhilengqilai", "冲冲冲": "chongchongchong",
    "硬刚": "yinggang", "心态崩了": "xintaibengle", "心态爆炸": "xintaibaozha",
    "天塌了": "tiantale", "听劝": "tingquan", "主打一个": "zhudayige",
    "那咋了": "nazale", "泰裤辣": "taikula", "挖呀挖": "wayawa", "上强度": "shangqiangdu",
    "草台班子": "caotaibanzi", "讨好型人格": "taohaoxingrenge", "情绪稳定": "qingxuwending",
    "求放过": "qiufangguo", "电子搭子": "dianzidazi", "卷起来": "juanqilai",
    "咋回事": "zahuishi", "啥情况": "shaqingkuang", "干啥呢": "ganshane",
    "咋说": "zashuo", "得嘞": "delei", "好嘞": "haolei", "得劲": "dejin",
    "贼好": "zeihao", "贼拉": "zeila", "麻溜": "maliu", "麻溜的": "maliude",
}

LETTER2DIGIT = {}
for digit, letters in {"2": "abc", "3": "def", "4": "ghi", "5": "jkl",
                       "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz"}.items():
    for ch in letters:
        LETTER2DIGIT[ch] = digit


def level(freq):
    return int(round(math.log2(freq + 1) * 10)) if freq > 0 else 0


def parse_rime(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        started = False
        for line in f:
            if not started:
                if "\t" in line and not line.startswith("#"):
                    started = True
                else:
                    continue
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            word = parts[0]
            pys = parts[1].strip()
            freq = 0
            if len(parts) >= 3:
                m = re.match(r"^(\d+)", parts[2].strip())
                if m:
                    freq = int(m.group(1))
            rows.append((word, pys, freq))
    return rows


def load_main_dict():
    words = set()
    word_level = {}
    with open(os.path.join(ASSETS, "pinyin_dict.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            _, _, vals = line.partition("\t")
            toks = vals.split(" ")
            for i in range(0, len(toks) - 1, 2):
                w, lv = toks[i], toks[i + 1]
                words.add(w)
                try:
                    lvi = int(lv)
                except ValueError:
                    continue
                if lvi > word_level.get(w, -1):
                    word_level[w] = lvi
    return words, word_level


def load_syllables():
    with open(os.path.join(ASSETS, "syllables.txt"), encoding="utf-8") as f:
        return {s.strip() for s in f if s.strip()}


def load_jieba(src):
    freq = {}
    with open(os.path.join(src, "jieba_dict.txt"), encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                w, fr = parts[0], int(parts[1])
                if fr > freq.get(w, 0):
                    freq[w] = fr
    return freq


def _split_flat_pinyin(flat, sylls):
    """把连写拼音按最长匹配切成音节(热词清单用;人工拼音保证可切)。"""
    out = []
    i = 0
    max_len = max(len(s) for s in sylls)
    while i < len(flat):
        m = 0
        for L in range(min(max_len, len(flat) - i), 0, -1):
            if flat[i:i + L] in sylls:
                m = L
                break
        if m == 0:
            return []
        out.append(flat[i:i + m])
        i += m
    return out


def calibrate(word_level, jieba_freq):
    xs, ys = [], []
    for w, lv in word_level.items():
        jf = jieba_freq.get(w)
        if jf and jf >= 5 and lv > 0:
            xs.append(math.log2(jf + 1))
            ys.append(lv)
    n = len(xs)
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys))
    b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    a = (sy - b * sx) / n
    return a, b, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(HERE, "custom_dict_generated.txt"))
    ap.add_argument("--flat-out", default="", help="可选:同时输出旧版三列平铺格式(调试对照)")
    ap.add_argument("--t1-min-freq", type=int, default=2)
    ap.add_argument("--jieba-missing-min", type=int, default=1000)
    # <160:自定义词纯词频永不翻越主词库高频词(lv>=160)top-1,九宫格正向硬保护
    ap.add_argument("--level-cap", type=int, default=155)
    ap.add_argument("--level-floor", type=int, default=16)
    ap.add_argument("--ext-default-level", type=int, default=55)
    ap.add_argument("--poi-src", default=os.environ.get("POI_SRC", ""),
                    help="T5 专有名词源 poi_words.tsv(词\\t音节空格分隔\\t来源,按优先级排好序);空则跳过 T5")
    ap.add_argument("--poi-level", type=int, default=40)
    # 移动端体积/内存预算:源文件按优先级排序(主题分类→城市信息精选→大全→其余),
    # 达到预算即停——iOS 键盘扩展内存上限严格、鸿蒙字节表全量驻内存,词库文件须控制在 ~35MB 内
    ap.add_argument("--poi-max-words", type=int, default=660_000)
    args = ap.parse_args()
    src = DEFAULT_SRC

    main_words, word_level = load_main_dict()
    sylls = load_syllables()
    jieba_freq = load_jieba(src)
    a, b, npair = calibrate(word_level, jieba_freq)
    print(f"主词库词数={len(main_words)}  jieba标定对={npair}  level≈{a:.1f}+{b:.2f}*log2(jf)")

    def jieba_level(w):
        jf = jieba_freq.get(w)
        if not jf:
            return None
        lv = int(round(a + b * math.log2(jf + 1)))
        return max(args.level_floor, min(args.level_cap, lv))

    def valid_pinyin(word, pys):
        if not (2 <= len(word) <= 8) or not CJK_RE.match(word):
            return None
        syl = pys.split()
        if not syl or not all(s in sylls for s in syl):
            return None
        pinyin = "".join(syl)
        for c in pinyin:
            if c not in LETTER2DIGIT:
                return None
        return pinyin

    chosen = {}  # word -> (pinyin, level, tier)
    stats = defaultdict(int)

    def consider(word, pys, lv, tier):
        if word in main_words or word in chosen:
            stats[f"{tier}_dup"] += 1
            return
        pinyin = valid_pinyin(word, pys)
        if not pinyin:
            stats[f"{tier}_invalid"] += 1
            return
        chosen[word] = (pinyin, max(args.level_floor, min(args.level_cap, lv)), tier)
        stats[tier] += 1

    base_rows = parse_rime(os.path.join(src, "base.dict.yaml"))

    # T1: base 残余(真实词频直算 level,与主词库同量纲同语料)
    for w, pys, fr in base_rows:
        if len(w) >= 2 and fr >= args.t1_min_freq:
            consider(w, pys, level(fr), "T1_base")

    # T2: ext 扩展(jieba 标定,无则默认 level)
    for w, pys, fr in parse_rime(os.path.join(src, "ext.dict.yaml")):
        lv = jieba_level(w)
        if lv is None:
            lv = args.ext_default_level
        consider(w, pys, lv, "T2_ext")

    # T3: jieba 高频缺词(拼音从 base/ext/tencent 反查;查不到拼音只能放弃)
    missing = {w for w, jf in jieba_freq.items()
               if jf >= args.jieba_missing_min and 2 <= len(w) <= 8
               and CJK_RE.match(w) and w not in main_words and w not in chosen}
    if missing:
        pinyin_of = {}
        for rows in (base_rows, parse_rime(os.path.join(src, "tencent.dict.yaml"))):
            for w, pys, _ in rows:
                if w in missing and w not in pinyin_of:
                    pinyin_of[w] = pys
        for w in sorted(missing):
            if w in pinyin_of:
                consider(w, pinyin_of[w], jieba_level(w), "T3_jieba")
            else:
                stats["T3_jieba_nopinyin"] += 1

    # T4: 精选热词加权(已入选的提档;未入选且不与主词库重复的按人工拼音补录)
    for w, py_flat in HOT_WORDS.items():
        pys = " ".join(_split_flat_pinyin(py_flat, sylls))
        if w in chosen:
            py, lv, tier = chosen[w]
            if lv < HOT_LEVEL:
                chosen[w] = (py, HOT_LEVEL, tier + "+hot")
                stats["T4_hot_boost"] += 1
        elif w not in main_words:
            consider(w, pys, HOT_LEVEL, "T4_hot")
        else:
            stats["T4_hot_in_main"] += 1

    # T5: 专有名词(搜狗城市信息细胞词库:地名/道路/单位机构/风景名胜/小区)。
    # scel 自带人工音节边界(空格分隔),不做贪心重切;lue/nue 等 ü 形归一到词库 v 形。
    # 有 jieba 词频者按标定 level(著名地标),长尾专名统一 --poi-level(40)。
    if args.poi_src and os.path.exists(args.poi_src):
        U_NORM = {"lue": "lve", "nue": "nve"}
        with open(args.poi_src, encoding="utf-8") as f:
            for line in f:
                if stats["T5_poi"] >= args.poi_max_words:
                    stats["T5_poi_over_budget"] += 1
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                w = parts[0].strip()
                syl = [U_NORM.get(s, s) for s in parts[1].split()]
                if not syl or any(s not in sylls for s in syl):
                    stats["T5_poi_badpinyin"] += 1
                    continue
                lv = jieba_level(w)
                if lv is None:
                    lv = args.poi_level
                consider(w, " ".join(syl), lv, "T5_poi")
    elif args.poi_src:
        print(f"警告: --poi-src 不存在: {args.poi_src}")

    # SEED: 用户报障必收专名(打不出即事故级,人工拼音,随报障追加)
    SEED_POI = {
        "林萃西里": "lin cui xi li",
        "华创生活广场": "hua chuang sheng huo guang chang",
    }
    for w, pys in SEED_POI.items():
        if w not in chosen and w not in main_words:
            consider(w, pys, args.poi_level, "T5_seed")

    # ---- 输出:主词库同格式(key 升序,key 内 level 降序) ----
    grouped = defaultdict(list)
    grouped["biangbiangmian"].append(("\U00030EDE\U00030EDE面", 500))
    for w, (py, lv, _) in chosen.items():
        grouped[py].append((w, lv))
    lines = []
    for key in sorted(grouped.keys()):
        cands = sorted(grouped[key], key=lambda x: (-x[1], x[0]))
        toks = []
        for w, lv in cands:
            toks.append(w)
            toks.append(str(lv))
        lines.append(key + "\t" + " ".join(toks))
    with open(args.out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    if args.flat_out:
        with open(args.flat_out, "w", encoding="utf-8") as f:
            f.write("# 平铺对照格式: 拼音\\t词\\tlevel\n")
            for w, (py, lv, tier) in sorted(chosen.items(), key=lambda x: x[1][0]):
                f.write(f"{py}\t{w}\t{lv}\n")

    size = os.path.getsize(args.out)
    print(f"输出 {args.out}: 词={len(chosen) + 1} key={len(grouped)} 大小={size / 1048576:.1f}MB")
    for k in sorted(stats):
        print(f"  {k}: {stats[k]}")
    lv_dist = defaultdict(int)
    for _, (py, lv, _) in chosen.items():
        lv_dist[lv // 20 * 20] += 1
    print("level分布:", dict(sorted(lv_dist.items())))


if __name__ == "__main__":
    main()
