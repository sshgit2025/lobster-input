# -*- coding: utf-8 -*-
"""字bigram LM 整句智能 —— 方案验证(对照 V3 无LM vs LM)。

大量真实长句:验证 LM 把语义正确的整句顶到 #1;并守护"不能全变聪明"(限度)。
用法: CHAR_LM=/tmp/char_bigram_proto.txt python3 validate_lm_sentence.py
"""
import os
from engine import to_digits
from engine_v3 import load_engine_v3
from engine_lm import load_engine_lm
from char_lm import CharBigramLM

LM_PATH = os.environ.get("CHAR_LM", "/tmp/char_bigram_proto.txt")

# (期望整句, 拼音)  —— 打对拼音应默认出的正确句子
CASES = [
    ("因为你搬过来了呀", "yinweinibanguolaileya"),
    ("我们一起去吃饭吧", "womenyiqiquchifanba"),
    ("今天天气怎么样", "jintiantianqizenmeyang"),
    ("你在干什么呢", "nizaiganshenmene"),
    ("明天我要去上班", "mingtianwoyaoqushangban"),
    ("我马上就到了", "womashangjiudaole"),
    ("你吃饭了吗", "nichifanlema"),
    ("周末一起出去玩", "zhoumoyiqichuquwan"),
    ("我今天很开心", "wojintianhenkaixin"),
    ("你到哪里了", "nidaonalile"),
    ("我在家里等你", "wozaijialidengni"),
    ("这个电影真好看", "zhegedianyingzhenhaokan"),
    ("谢谢你的帮助", "xiexinidebangzhu"),
    ("明天会下雨吗", "mingtianhuixiayuma"),
    ("我想喝杯咖啡", "woxianghebeikafei"),
    ("你最近怎么样", "nizuijinzenmeyang"),
    ("我们出去走走吧", "womenchuquzouzouba"),
    ("晚上想吃什么", "wanshangxiangchishenme"),
    ("快点起床上学", "kuaidianqichuangshangxue"),
    ("记得早点回家", "jidezaodianhuijia"),
]


def run():
    e0 = load_engine_v3()          # 基线:无 LM
    lm = CharBigramLM().load(LM_PATH)
    e1 = load_engine_lm()          # LM 版
    e1.set_lm(lm)

    win = 0
    same_ok = 0
    regress = []
    fixed = []
    for zh, py in CASES:
        d = to_digits(py)
        top0 = [c.word for c in e0.candidates_for_t9(d, 3)]
        top1 = [c.word for c in e1.candidates_for_t9(d, 3)]
        b0 = top0[0] if top0 else ""
        b1 = top1[0] if top1 else ""
        ok0 = (b0 == zh)
        ok1 = (b1 == zh)
        tag = "  "
        if ok1 and not ok0:
            tag = "✅修复"; fixed.append(zh); win += 1
        elif ok1 and ok0:
            tag = "  持平"; same_ok += 1
        elif not ok1 and ok0:
            tag = "❌回退"; regress.append((zh, b1))
        else:
            tag = "△都错"
        print(f"{tag} 目标={zh}")
        print(f"      基线#1={b0!r}  LM#1={b1!r}")

    print(f"\n== 修复 {len(fixed)} / 持平正确 {same_ok} / 回退 {len(regress)} / 共 {len(CASES)} ==")
    if regress:
        print("回退项:", regress)
    ok_rate1 = sum(1 for zh, py in CASES if (e1.candidates_for_t9(to_digits(py), 1)[0].word == zh)) / len(CASES)
    ok_rate0 = sum(1 for zh, py in CASES if (e0.candidates_for_t9(to_digits(py), 1)[0].word == zh)) / len(CASES)
    print(f"== 首选正确率:基线 {ok_rate0:.0%} → LM {ok_rate1:.0%} ==")


if __name__ == "__main__":
    run()
