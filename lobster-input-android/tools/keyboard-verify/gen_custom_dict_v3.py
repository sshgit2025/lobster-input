#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""custom_dict v3:在已落地词库资产上做**增量合并**(2026-07-17)。

背景:v2 生成器(gen_custom_dict.py)是全量重建,依赖 T1/T2/T5 的外部源;T5 的 poi_words.tsv
产物与爬取管线曾留在会话 scratchpad 已丢失。v3 改为把**当前线上资产当作不可变基线**,只做追加
与"只升不降"的等级提升——已验证过的 127 万词一个不动,天然零回归。

新增三层(均为数据层,引擎零改动):
  T6 品牌层     搜狗细胞词库爬取(crawl_sogou_brands.py:品牌类目遍历+关键词搜索,含调研 P1
                缺口:影视426/明星429/游戏436/动漫404)+ BRAND_SEEDS 知名品牌种子(斯凯奇/
                名创优品类漏网,人工拼音,lv120 进补全预测)。爬取词默认 lv60,jieba 标定可升。
  T7 组块层     高频口语组块(修「请叫我人才 被 请教我人才 压制」):整句 DP 会经组块跳转,
                一段增益胜过多段惩罚(harness 已验证翻转)。源=tencent 词表(3-6字)经
                「全部可切成 lv>=130 主词库词」的严格分解过滤 + CHUNK_SEEDS 人工种子;
                拼音由分解出的主词库词 key 拼接(词级 key 天然多音字正确)。lv85(<110 不进预测)。
  T4b 口语加权  现代口语实物词精选表(修「banxiu 半袖排 14 位」:rime 语料年代旧,斑竹/包宿类
                旧词压制现代口语词;jieba/SUBTLEX 均无此类词,只能人工精选)。lv142,
                对已存在的自定义词**只升不降**,主词库词绝不动。

规则(继承 v2):零重复(词粒度,vs 主词库+现有资产)、2-8 字全 CJK、拼音可切合法音节
(scel/分解来源自带音节边界,不贪心重切)、可映射 T9 数字码、cap155。

用法:
  python3 gen_custom_dict_v3.py --brand-src <brand_words.tsv> [--out PATH]
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
# 店铺/公司自建词库垃圾模式(爬取词表里大量「XX旗舰店/XX有限公司」类)
SPAM_RE = re.compile(r'旗舰店|专卖店|专营店|有限公司|股份|官网|官方店|店铺|工作室|经销|批发|厂家')

LETTER2DIGIT = {}
for digit, letters in {"2": "abc", "3": "def", "4": "ghi", "5": "jkl",
                       "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz"}.items():
    for ch in letters:
        LETTER2DIGIT[ch] = digit

# ===== 知名品牌种子(人工拼音;运动/服装/奢侈/美妆/餐饮/汽车/数码/家电/商超;
# 与主词库重复的自动跳过,零重复原则不变)=====
BRAND_LEVEL = 120  # >110:知名品牌进补全预测(打 sikai 可联想 斯凯奇)
BRAND_SEEDS = {
    "斯凯奇": "si kai qi", "名创优品": "ming chuang you pin", "始祖鸟": "shi zu niao",
    "昂跑": "ang pao", "萨洛蒙": "sa luo meng", "亚瑟士": "ya se shi", "鬼冢虎": "gui zhong hu",
    "安德玛": "an de ma", "斐乐": "fei le", "彪马": "biao ma", "锐步": "rui bu",
    "匡威": "kuang wei", "万斯": "wan si", "回力": "hui li", "飞跃": "fei yue",
    "凯乐石": "kai le shi", "探路者": "tan lu zhe", "骆驼": "luo tuo", "北面": "bei mian",
    "哥伦比亚": "ge lun bi ya", "猛犸象": "meng ma xiang", "攀山鼠": "pan shan shu",
    "迪桑特": "di sang te", "可隆": "ke long", "拉夫劳伦": "la fu lao lun",
    "优衣库": "you yi ku", "无印良品": "wu yin liang pin", "热风": "re feng",
    "太平鸟": "tai ping niao", "波司登": "bo si deng", "鸭鸭": "ya ya",
    "雪中飞": "xue zhong fei", "海澜之家": "hai lan zhi jia", "森马": "sen ma",
    "以纯": "yi chun", "真维斯": "zhen wei si", "班尼路": "ban ni lu",
    "美特斯邦威": "mei te si bang wei", "江南布衣": "jiang nan bu yi",
    "之禾": "zhi he", "鄂尔多斯": "e er duo si", "恒源祥": "heng yuan xiang",
    "红豆": "hong dou", "七匹狼": "qi pi lang", "劲霸": "jin ba", "利郎": "li lang",
    "九牧王": "jiu mu wang", "报喜鸟": "bao xi niao", "雅戈尔": "ya ge er",
    "巴宝莉": "ba bao li", "博柏利": "bo bo li", "缪缪": "miu miu", "芬迪": "fen di",
    "赛琳": "sai lin", "罗意威": "luo yi wei", "葆蝶家": "bao die jia",
    "麦丝玛拉": "mai si ma la", "蔻驰": "kou chi", "凯特丝蓓": "kai te si bei",
    "迈克高仕": "mai ke gao shi", "汤丽柏琦": "tang li bo qi",
    "圣罗兰": "sheng luo lan", "纪梵希": "ji fan xi", "宝格丽": "bao ge li",
    "卡地亚": "ka di ya", "梵克雅宝": "fan ke ya bao", "尚美巴黎": "shang mei ba li",
    "伯爵": "bo jue", "积家": "ji jia", "江诗丹顿": "jiang shi dan dun",
    "百达翡丽": "bai da fei li", "爱彼": "ai bi", "朗格": "lang ge",
    "万国表": "wan guo biao", "沛纳海": "pei na hai", "真力时": "zhen li shi",
    "宝珀": "bao po", "宝玑": "bao ji", "芝柏": "zhi bo", "汉米尔顿": "han mi er dun",
    "美度": "mei du", "天梭": "tian suo", "浪琴": "lang qin", "雪铁纳": "xue tie na",
    "西铁城": "xi tie cheng", "精工": "jing gong", "卡西欧": "ka xi ou",
    "适乐肤": "shi le fu", "珂润": "ke run", "芙丽芳丝": "fu li fang si",
    "黛珂": "dai ke", "奥尔滨": "ao er bin", "苏秘": "su mi", "呼吸": "hu xi",
    "后": "hou", "雪花秀": "xue hua xiu", "悦诗风吟": "yue shi feng yin",
    "伊蒂之屋": "yi di zhi wu", "珀莱雅": "po lai ya", "薇诺娜": "wei nuo na",
    "润百颜": "run bai yan", "夸迪": "kua di", "米蓓尔": "mi bei er",
    "优时颜": "you shi yan", "逐本": "zhu ben", "溪木源": "xi mu yuan",
    "至本": "zhi ben", "谷雨": "gu yu", "华熙生物": "hua xi sheng wu",
    "完美日记": "wan mei ri ji", "花西子": "hua xi zi", "橘朵": "ju duo",
    "酵色": "jiao se", "毛戈平": "mao ge ping", "彩棠": "cai tang",
    "瑞幸咖啡": "rui xing ka fei", "库迪": "ku di", "曼纳": "man na",
    "霸王茶姬": "ba wang cha ji", "茶颜悦色": "cha yan yue se", "沪上阿姨": "hu shang a yi",
    "古茗": "gu ming", "茶百道": "cha bai dao", "甜啦啦": "tian la la",
    "益禾堂": "yi he tang", "书亦烧仙草": "shu yi shao xian cao",
    "华莱士": "hua lai shi", "塔斯汀": "ta si ting", "老乡鸡": "lao xiang ji",
    "乡村基": "xiang cun ji", "萨莉亚": "sa li ya", "必胜客": "bi sheng ke",
    "汉堡王": "han bao wang", "赛百味": "sai bai wei", "达美乐": "da mei le",
    "海底捞": "hai di lao", "呷哺呷哺": "xia bu xia bu", "凑凑": "cou cou",
    "太二酸菜鱼": "tai er suan cai yu", "外婆家": "wai po jia", "绿茶餐厅": "lv cha can ting",
    "袁记云饺": "yuan ji yun jiao", "紫燕百味鸡": "zi yan bai wei ji",
    "绝味鸭脖": "jue wei ya bo", "周黑鸭": "zhou hei ya", "煌上煌": "huang shang huang",
    "良品铺子": "liang pin pu zi", "三只松鼠": "san zhi song shu", "百草味": "bai cao wei",
    "来伊份": "lai yi fen", "卫龙": "wei long", "洽洽": "qia qia",
    "元气森林": "yuan qi sen lin", "农夫山泉": "nong fu shan quan", "怡宝": "yi bao",
    "东方树叶": "dong fang shu ye", "三得利": "san de li", "维他柠檬茶": "wei ta ning meng cha",
    "蔚来": "wei lai", "小鹏": "xiao peng", "理想汽车": "li xiang qi che",
    "零跑": "ling pao", "哪吒汽车": "ne zha qi che", "极氪": "ji ke",
    "问界": "wen jie", "智界": "zhi jie", "享界": "xiang jie", "尊界": "zun jie",
    "深蓝汽车": "shen lan qi che", "阿维塔": "a wei ta", "岚图": "lan tu",
    "极狐": "ji hu", "智己": "zhi ji", "飞凡": "fei fan", "埃安": "ai an",
    "小米汽车": "xiao mi qi che", "特斯拉": "te si la", "保时捷": "bao shi jie",
    "兰博基尼": "lan bo ji ni", "法拉利": "fa la li", "迈凯伦": "mai kai lun",
    "宾利": "bin li", "劳斯莱斯": "lao si lai si", "阿斯顿马丁": "a si dun ma ding",
    "玛莎拉蒂": "ma sha la di", "捷豹": "jie bao", "路虎": "lu hu",
    "雷克萨斯": "lei ke sa si", "英菲尼迪": "ying fei ni di", "讴歌": "ou ge",
    "斯巴鲁": "si ba lu", "铃木": "ling mu", "五菱": "wu ling", "宏光": "hong guang",
    "大疆": "da jiang", "影石": "ying shi", "石头科技": "shi tou ke ji",
    "科沃斯": "ke wo si", "追觅": "zhui mi", "云鲸": "yun jing", "徕芬": "lai fen",
    "倍思": "bei si", "安克": "an ke", "绿联": "lv lian", "品胜": "pin sheng",
    "罗马仕": "luo ma shi", "闪极": "shan ji", "韶音": "shao yin",
    "漫步者": "man bu zhe", "万魔": "wan mo", "飞傲": "fei ao", "水月雨": "shui yue yu",
    "拜雅": "bai ya", "森海塞尔": "sen hai sai er", "铁三角": "tie san jiao",
    "尊宝": "zun bao", "天龙": "tian long", "马兰士": "ma lan shi",
    "红米": "hong mi", "真我": "zhen wo", "一加": "yi jia", "艾利和": "ai li he",
    "山灵": "shan ling", "乐图": "le tu", "凯音": "kai yin",
    "戴森": "dai sen", "松下": "song xia", "夏普": "xia pu", "东芝": "dong zhi",
    "日立": "ri li", "博世": "bo shi", "西门子": "xi men zi", "美诺": "mei nuo",
    "利勃海尔": "li bo hai er", "卡萨帝": "ka sa di", "容声": "rong sheng",
    "华凌": "hua ling", "小天鹅": "xiao tian e", "统帅": "tong shuai",
    "苏泊尔": "su po er", "九阳": "jiu yang", "小熊电器": "xiao xiong dian qi",
    "摩飞": "mo fei", "北鼎": "bei ding", "宜家": "yi jia", "居然之家": "ju ran zhi jia",
    "红星美凯龙": "hong xing mei kai long", "顾家家居": "gu jia jia ju",
    "芝华仕": "zhi hua shi", "慕思": "mu si", "喜临门": "xi lin men",
    "九牧": "jiu mu", "箭牌": "jian pai", "恒洁": "heng jie", "科勒": "ke le",
    "摩恩": "mo en", "汉斯格雅": "han si ge ya", "东鹏": "dong peng",
    "马可波罗": "ma ke bo luo", "诺贝尔瓷砖": "nuo bei er ci zhuan",
    "山姆会员店": "shan mu hui yuan dian", "开市客": "kai shi ke", "奥乐齐": "ao le qi",
    "盒马": "he ma", "叮咚买菜": "ding dong mai cai", "朴朴": "pu pu",
    "钱大妈": "qian da ma", "永辉超市": "yong hui chao shi", "大润发": "da run fa",
    "物美": "wu mei", "华润万家": "hua run wan jia", "罗森": "luo sen",
    "全家便利店": "quan jia bian li dian", "便利蜂": "bian li feng",
    "泡泡玛特": "pao pao ma te", "乐高": "le gao", "万代": "wan dai",
    "孩之宝": "hai zhi bao", "美泰": "mei tai", "奥飞": "ao fei",
    "晨光文具": "chen guang wen ju", "得力": "de li", "百乐": "bai le",
    "斑马": "ban ma", "三菱铅笔": "san ling qian bi", "施德楼": "shi de lou",
    "凌美": "ling mei", "英雄钢笔": "ying xiong gang bi",
}

# ===== 现代口语实物词精选(banxiu 案例类:rime 语料年代旧压制的日常词;人工拼音)=====
COLLOQUIAL_LEVEL = 142
COLLOQUIAL_BOOST = {
    "半袖": "ban xiu", "卫衣": "wei yi", "秋裤": "qiu ku", "秋衣": "qiu yi",
    "坎肩": "kan jian", "打底裤": "da di ku", "打底衫": "da di shan",
    "冲锋衣": "chong feng yi", "羽绒服": "yu rong fu", "卫裤": "wei ku",
    "阔腿裤": "kuo tui ku", "工装裤": "gong zhuang ku", "牛仔裤": "niu zai ku",
    "瑜伽裤": "yu jia ku", "鲨鱼裤": "sha yu ku", "肌底衣": "ji di yi",
    "防晒衣": "fang shai yi", "防晒霜": "fang shai shuang", "隔离霜": "ge li shuang",
    "美瞳": "mei tong", "腮红": "sai hong", "眼影": "yan ying", "口红": "kou hong",
    "粉底液": "fen di ye", "遮瑕": "zhe xia", "散粉": "san fen", "定妆": "ding zhuang",
    "卸妆水": "xie zhuang shui", "洗面奶": "xi mian nai", "爽肤水": "shuang fu shui",
    "精华液": "jing hua ye", "面霜": "mian shuang", "身体乳": "shen ti ru",
    "护手霜": "hu shou shuang", "润唇膏": "run chun gao", "发膜": "fa mo",
    "护发素": "hu fa su", "沐浴露": "mu yu lu", "洗发水": "xi fa shui",
    "帆布鞋": "fan bu xie", "老爹鞋": "lao die xie", "洞洞鞋": "dong dong xie",
    "勃肯鞋": "bo ken xie", "乐福鞋": "le fu xie", "马丁靴": "ma ding xue",
    "雪地靴": "xue di xue", "溯溪鞋": "su xi xie", "板鞋": "ban xie",
    "拖鞋": "tuo xie", "凉拖": "liang tuo", "棉拖": "mian tuo",
    "卫生巾": "wei sheng jin", "纸尿裤": "zhi niao ku", "湿巾": "shi jin",
    "抽纸": "chou zhi", "卷纸": "juan zhi", "厨房纸": "chu fang zhi",
    "保鲜膜": "bao xian mo", "保鲜袋": "bao xian dai", "垃圾袋": "la ji dai",
    "洗洁精": "xi jie jing", "洗衣液": "xi yi ye", "柔顺剂": "rou shun ji",
    "消毒液": "xiao du ye", "免洗洗手液": "mian xi xi shou ye",
    "充电宝": "chong dian bao", "数据线": "shu ju xian", "充电头": "chong dian tou",
    "插线板": "cha xian ban", "路由器": "lu you qi", "摄像头": "she xiang tou",
    "行车记录仪": "xing che ji lu yi", "破壁机": "po bi ji", "空气炸锅": "kong qi zha guo",
    "电饭煲": "dian fan bao", "养生壶": "yang sheng hu", "电热水壶": "dian re shui hu",
    "加湿器": "jia shi qi", "除湿机": "chu shi ji", "净化器": "jing hua qi",
    "洗地机": "xi di ji", "扫地机器人": "sao di ji qi ren", "吸尘器": "xi chen qi",
    "筋膜枪": "jin mo qiang", "跳绳": "tiao sheng", "瑜伽垫": "yu jia dian",
    "泡沫轴": "pao mo zhou", "护膝": "hu xi", "护腰": "hu yao",
    "保温杯": "bao wen bei", "焖烧杯": "men shao bei", "吸管杯": "xi guan bei",
    "料理包": "liao li bao", "预制菜": "yu zhi cai", "自热锅": "zi re guo",
    "螺蛳粉": "luo si fen", "酸辣粉": "suan la fen", "肥汁米线": "fei zhi mi xian",
    "轻食": "qing shi", "代餐": "dai can", "控糖": "kong tang", "断糖": "duan tang",
    "生椰拿铁": "sheng ye na tie", "厚乳": "hou ru", "冰美式": "bing mei shi",
    "热美式": "re mei shi", "燕麦奶": "yan mai nai", "杨枝甘露": "yang zhi gan lu",
}

# ===== 口语组块种子(请叫我 案例类:整句 DP 组块跳转;人工拼音)=====
CHUNK_LEVEL = 85        # jieba 挖掘组块:<110 不进补全预测,只服务整句/打全
# 种子组块 128:26 键整句段惩罚 300(T9 是 380),需 lv>122 才能让「请叫我+人才」两段路径
# 压过「请教+我+人才」三段;人工精选高置信,与品牌种子(120)同原则允许进补全预测。
CHUNK_SEED_LEVEL = 128
CHUNK_SEEDS = {
    "请叫我": "qing jiao wo", "别忘了": "bie wang le", "我跟你说": "wo gen ni shuo",
    "你猜怎么着": "ni cai zen me zhao", "说实话": "shuo shi hua", "讲真的": "jiang zhen de",
    "怎么说呢": "zen me shuo ne", "这么说吧": "zhe me shuo ba", "不瞒你说": "bu man ni shuo",
    "你还别说": "ni hai bie shuo", "咋说呢": "za shuo ne", "要我说": "yao wo shuo",
    "依我看": "yi wo kan", "说白了": "shuo bai le", "换句话说": "huan ju hua shuo",
    "总的来说": "zong de lai shuo", "严格来说": "yan ge lai shuo",
    "从某种意义上": "cong mou zhong yi yi shang", "不出意外的话": "bu chu yi wai de hua",
    "万万没想到": "wan wan mei xiang dao", "谁能想到": "shui neng xiang dao",
    "你敢信": "ni gan xin", "离了大谱": "li le da pu", "什么情况": "shen me qing kuang",
    "咋回事啊": "za hui shi a", "搞什么呢": "gao shen me ne", "干嘛呢": "gan ma ne",
    "在吗": "zai ma", "在不在": "zai bu zai", "忙不忙": "mang bu mang",
    "方便吗": "fang bian ma", "有空吗": "you kong ma", "打扰了": "da rao le",
    "麻烦你了": "ma fan ni le", "辛苦了": "xin ku le", "多谢了": "duo xie le",
    "改天约": "gai tian yue", "回聊": "hui liao", "先这样": "xian zhe yang",
    "就这样吧": "jiu zhe yang ba", "回头说": "hui tou shuo", "等我一下": "deng wo yi xia",
    "马上到": "ma shang dao", "在路上": "zai lu shang", "快到了": "kuai dao le",
    "到哪了": "dao na le", "出发了": "chu fa le", "刚到家": "gang dao jia",
    "吃了吗": "chi le ma", "吃点啥": "chi dian sha", "整点啥": "zheng dian sha",
    "随便吃点": "sui bian chi dian", "点外卖": "dian wai mai", "拼个单": "pin ge dan",
    "帮我带": "bang wo dai", "捎带手": "shao dai shou", "顺路吗": "shun lu ma",
    "没毛病": "mei mao bing", "有一说一": "you yi shuo yi", "确实是": "que shi shi",
    "那必须的": "na bi xu de", "必须安排": "bi xu an pai", "安排上": "an pai shang",
    "整起来": "zheng qi lai", "搞起来": "gao qi lai", "冲就完了": "chong jiu wan le",
    "问题不大": "wen ti bu da", "小意思": "xiao yi si", "洒洒水": "sa sa shui",
    "看情况吧": "kan qing kuang ba", "再说吧": "zai shuo ba", "缓一缓": "huan yi huan",
    "先缓缓": "xian huan huan", "顶不住了": "ding bu zhu le", "扛不住了": "kang bu zhu le",
    "累趴了": "lei pa le", "困死了": "kun si le", "饿死了": "e si le",
    "笑死我了": "xiao si wo le", "无语了": "wu yu le", "服了": "fu le",
    "醉了": "zui le", "裂开了": "lie kai le", "汗流浃背了": "han liu jia bei le",
}


def level(freq):
    return int(round(math.log2(freq + 1) * 10)) if freq > 0 else 0


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


def load_existing(path):
    """现有资产:word -> (pinyin_key, lv)。同词多 key 时保留全部(word 映射首个,集合判重)。"""
    entries = []  # (key, word, lv) 保序
    words = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            key, _, vals = line.partition("\t")
            toks = vals.split(" ")
            for i in range(0, len(toks) - 1, 2):
                w, lv = toks[i], toks[i + 1]
                try:
                    entries.append((key, w, int(lv)))
                    words.add(w)
                except ValueError:
                    continue
    return entries, words


def load_syllables():
    with open(os.path.join(ASSETS, "syllables.txt"), encoding="utf-8") as f:
        return {s.strip() for s in f if s.strip()}


def load_jieba(src):
    freq = {}
    p = os.path.join(src, "jieba_dict.txt")
    if not os.path.exists(p):
        return freq
    with open(p, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                w, fr = parts[0], int(parts[1])
                if fr > freq.get(w, 0):
                    freq[w] = fr
    return freq


def calibrate(word_level, jieba_freq):
    xs, ys = [], []
    for w, lv in word_level.items():
        jf = jieba_freq.get(w)
        if jf and jf >= 5 and lv > 0:
            xs.append(math.log2(jf + 1))
            ys.append(lv)
    n = len(xs)
    if n < 100:
        return None
    sx, sy = sum(xs), sum(ys)
    sxx = sum(x * x for x in xs)
    sxy = sum(x * y for x, y in zip(xs, ys))
    b = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    a = (sy - b * sx) / n
    return a, b


class MainWordIndex:
    """主词库 key->words 反查 + 词到 key(组块拼音分解用:词级 key 多音字天然正确)。"""

    def __init__(self):
        self.word_keys = defaultdict(list)  # word -> [key]
        self.word_lv = {}
        with open(os.path.join(ASSETS, "pinyin_dict.txt"), encoding="utf-8") as f:
            for line in f:
                line = line.rstrip("\n")
                key, _, vals = line.partition("\t")
                toks = vals.split(" ")
                for i in range(0, len(toks) - 1, 2):
                    w = toks[i]
                    try:
                        lv = int(toks[i + 1])
                    except ValueError:
                        continue
                    self.word_keys[w].append(key)
                    if lv > self.word_lv.get(w, -1):
                        self.word_lv[w] = lv

    def decompose(self, word, part_min_lv, max_parts=4):
        """把词切成 2..max_parts 个主词库词(每词 lv>=part_min_lv),返回拼接 key;失败 None。
        DP 取「段数最少、段内平均 lv 最高」。"""
        n = len(word)
        NEG = (-10**9, -10**9)  # 哨兵必须小于一切真实状态(负段数最大 -1;曾用 -1 哨兵挡掉所有多段路径)
        best = [NEG] * (n + 1)  # (负段数, lv和)
        back = [None] * (n + 1)
        best[0] = (0, 0)
        for i in range(1, n + 1):
            for j in range(max(0, i - 6), i):
                if best[j] == NEG:
                    continue
                seg = word[j:i]
                lv = self.word_lv.get(seg, -1)
                if lv < part_min_lv:
                    continue
                cand = (best[j][0] - 1, best[j][1] + lv)
                if cand > best[i]:
                    best[i] = cand
                    back[i] = j
        if best[n] == NEG or -best[n][0] < 2 or -best[n][0] > max_parts:
            return None
        keys = []
        i = n
        while i > 0:
            j = back[i]
            seg = word[j:i]
            keys.append(self.word_keys[seg][0])
            i = j
        return "".join(reversed(keys))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--brand-src", default="", help="crawl_sogou_brands.py 产物 brand_words.tsv")
    ap.add_argument("--existing", default=os.path.join(ASSETS, "custom_dict.txt"))
    ap.add_argument("--out", default=os.path.join(HERE, "custom_dict_v3_generated.txt"))
    ap.add_argument("--brand-default-level", type=int, default=60)
    ap.add_argument("--brand-max", type=int, default=120_000)
    ap.add_argument("--chunk-max", type=int, default=60_000)
    ap.add_argument("--chunk-part-min-lv", type=int, default=130)
    ap.add_argument("--level-cap", type=int, default=155)
    ap.add_argument("--max-size-mb", type=float, default=42.0)
    args = ap.parse_args()
    src = DEFAULT_SRC

    main_words, word_level = load_main_dict()
    entries, existing_words = load_existing(args.existing)
    sylls = load_syllables()
    jieba_freq = load_jieba(src)
    fit = calibrate(word_level, jieba_freq)
    print(f"主词库 {len(main_words)} 词;现有资产 {len(entries)} 条/{len(existing_words)} 词;"
          f"jieba标定 {'ok' if fit else '不可用'}")

    def jieba_level(w):
        jf = jieba_freq.get(w)
        if not jf or not fit:
            return None
        a, b = fit
        return max(16, min(args.level_cap, int(round(a + b * math.log2(jf + 1)))))

    def valid_pinyin(word, syl_list):
        if not (2 <= len(word) <= 8) or not CJK_RE.match(word):
            return None
        if not syl_list or not all(s in sylls for s in syl_list):
            return None
        pinyin = "".join(syl_list)
        for c in pinyin:
            if c not in LETTER2DIGIT:
                return None
        return pinyin

    stats = defaultdict(int)
    new_entries = []  # (key, word, lv, tier)
    chosen_words = set()

    def consider(word, syl_list, lv, tier):
        if word in main_words or word in existing_words or word in chosen_words:
            stats[f"{tier}_dup"] += 1
            return False
        py = valid_pinyin(word, syl_list)
        if not py:
            stats[f"{tier}_invalid"] += 1
            return False
        chosen_words.add(word)
        new_entries.append((py, word, min(lv, args.level_cap), tier))
        stats[tier] += 1
        return True

    # ---- T6 品牌:爬取词表(已按来源下载量降序)----
    if args.brand_src and os.path.exists(args.brand_src):
        with open(args.brand_src, encoding="utf-8") as f:
            for line in f:
                if stats["T6_brand"] >= args.brand_max:
                    stats["T6_brand_over_budget"] += 1
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                w, pys = parts[0], parts[1].split(" ")
                if SPAM_RE.search(w):
                    stats["T6_brand_spam"] += 1
                    continue
                lv = jieba_level(w) or args.brand_default_level
                consider(w, pys, lv, "T6_brand")

    # ---- T6b 知名品牌种子 ----
    for w, pys in BRAND_SEEDS.items():
        consider(w, pys.split(" "), BRAND_LEVEL, "T6b_seed")

    # ---- T7 组块:jieba 高频(有真实词频背书)3-5 字组块,经主词库分解过滤。
    # 曾试 tencent 词表批量挖掘——tencent 是字典序无词频平表,cap 只会装进字母序前缀,
    # 且"起顺科技"类公司名与口语组块结构不可分,已弃(质量优先,规模让位)。 ----
    midx = MainWordIndex()

    def greedy_sylls(key):
        out = []
        i = 0
        while i < len(key):
            m = 0
            for L in range(min(6, len(key) - i), 0, -1):
                if key[i:i + L] in sylls:
                    m = L
                    break
            if m == 0:
                return None
            out.append(key[i:i + m])
            i += m
        return out

    for w, jf in sorted(jieba_freq.items(), key=lambda kv: -kv[1]):
        if jf < 300:
            break
        if not (3 <= len(w) <= 5) or not CJK_RE.match(w):
            continue
        if w in main_words or w in existing_words or w in chosen_words:
            continue
        if SPAM_RE.search(w):
            continue
        key = midx.decompose(w, args.chunk_part_min_lv)
        if key is None:
            stats["T7_chunk_reject"] += 1
            continue
        syl_list = greedy_sylls(key)
        if syl_list is None:
            stats["T7_chunk_invalid"] += 1
            continue
        consider(w, syl_list, CHUNK_LEVEL, "T7_chunk")

    # ---- T7b 组块种子(lv128:26键整句可翻转,精选高置信允许预测) ----
    for w, pys in CHUNK_SEEDS.items():
        consider(w, pys.split(" "), CHUNK_SEED_LEVEL, "T7b_seed")

    # ---- T4b 口语加权:新增或对现有词提档(只升不降) ----
    boost_map = {}
    for w, pys in COLLOQUIAL_BOOST.items():
        if w in main_words:
            stats["T4b_in_main"] += 1
            continue
        if w in existing_words or w in chosen_words:
            boost_map[w] = COLLOQUIAL_LEVEL
            stats["T4b_boost"] += 1
        else:
            consider(w, pys.split(" "), COLLOQUIAL_LEVEL, "T4b_new")

    # ---- 汇总输出(现有条目原样保留,boost 词提档) ----
    grouped = defaultdict(list)
    for key, w, lv in entries:
        grouped[key].append((w, max(lv, boost_map.get(w, 0))))
    for key, w, lv, _tier in new_entries:
        lv = max(lv, boost_map.get(w, 0))
        grouped[key].append((w, lv))
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

    size_mb = os.path.getsize(args.out) / 1048576
    total = sum(len(v) for v in grouped.values())
    print(f"输出 {args.out}: 词条={total} key={len(grouped)} 大小={size_mb:.1f}MB (预算{args.max_size_mb}MB)")
    for k in sorted(stats):
        print(f"  {k}: {stats[k]}")
    if size_mb > args.max_size_mb:
        print("!! 超出体积预算,请提高过滤阈值或收紧 --brand-max/--chunk-max")


if __name__ == "__main__":
    main()
