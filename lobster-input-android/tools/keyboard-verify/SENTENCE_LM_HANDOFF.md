# 九宫格智能整句语言模型 —— 任务交接文档

> 最后更新:2026-07-21。本文档供**跨会话接续**:读完即可了解任务背景、目标、已完成、待办、阻塞点与关键细节。
> 相关记忆:`mobile-typing-keyboard`、`custom-dict-v2-mass-vocab`。

---

## 1. 任务背景与目标

用户反馈九宫格拼音输入法**默认整句/候选组合"弱智"**,分两类:

- **2a 打对拼音也出不通顺句**(核心痛点)。例:输入 `因为你搬过来了呀`(digits 946934642264865245392),
  旧引擎 #1 出 **"因为你包裹来了呀"**(错),正确的"搬过来"只在 #2。根因**不是算法 bug**:
  `o` 和 `n` 同在 6 键 → `ban(226)`=`bao(226)` 同码;整句 DP 只按词频打分、**冷启动无上下文语言模型**,
  高频词"包裹"吃掉同码"搬过来",且无模型否决"包裹来"这种不通组合。
- **2b 打错平翘舌/前后鼻音带不出正确句**(如 `ni ci fan le ma` 想要"你吃饭了吗")。

**目标**:让输入法"变聪明"——打对出通顺句、(理想)打错也能纠错并在错字上标注正确拼音、选词只上屏汉字。
用户要求:**不误纠优先**;智能候选限 1-3 个精准词,其余仍按字面拼音;**方案须脚本全量回归全绿才允许落地业务代码**。

---

## 2. 调研结论(成熟方案)

| 方案 | 结论 |
|---|---|
| 神经小模型(PERT/GPT) | ❌ 学术 SOTA 但太重,iOS 键盘扩展内存上限严格,不内置 |
| **n-gram 语言模型**(词/字 bigram) | ✅ 业界移动端标准(RIME essay + octagram 八股文/万象;搜狗智能纠错同理) |

**最终采用:词级 bigram(主)+ 字级 bigram OOV veto(兜底)**。

### 关键教训(都用脚本证伪过,勿重走弯路)
1. 字bigram**全量**打分 → 长度偏置产生垃圾汤 ❌
2. **奖励**常见搭配 → 语料偏置("人民是"→"人民事"、"堪称完美"→"堪称赞美")❌
3. **字级有根本天花板**:正确转移在字级反而更罕见(`称→完` 比 `称→赞` 罕见,`民→是` 比 `民→事` 罕见,
   因"是/完"是语法性句子延续、非词内搭配)→ **字级永远修不了"堪称完美/人民是",必须词级** ❌
4. **正确公式 = 词级 bigram 条件对数概率 + 中心化 clamp**:见过的词转移(堪称→完美 124 / 搬→过来 323 /
   人民→是 172)给中心化 delta;字级仅作 OOV veto 兜底(否决"裹→来"类从未出现的字搭配,只罚不奖)✅

---

## 3. ✅ 已完成并上线:2a 语言模型(三端落地 + 编译通过)

### 3.1 语言模型数据
- **char_bigram.txt**(4.4MB):字级 bigram,`c1\tc2 w2 c3 w3 ...`,w=量化条件对数概率(负值)。仅作 OOV veto 兜底。
- **word_bigram.txt**(2.16MB):词级 bigram,`w1\tw2 b2 ...`,b=中心化条件对数概率。主信号。
- 语料:**OpenSubtitles 中文字幕 16M 行(口语,匹配聊天场景)+ Leipzig 新闻 1M + 维基 30万**。
  字幕是关键(新闻语料会引入"民事/河北"等 jargon 偏置)。
- 已放入三端资产:
  - 安卓 `app/src/main/assets/{char,word}_bigram.txt`
  - iOS `LobsterKeyboard/Resources/{char,word}_bigram.txt`
  - 鸿蒙 `entry/src/main/resources/rawfile/dict/{char,word}_bigram.txt`

### 3.2 打分算法(三端逐一对齐,参数勿单独改)
`boundaryScore(pw, w)`:只作用于**跨词边界**(词内已被词频编码):
- `wordDelta(pw,w)`:词 bigram 命中 → `clamp((b - WREF)*WBETA, -WLO, WHI)`,未命中返回 null。
- 未命中 → `charVeto(pw末字, w首字)`:字 bigram 命中且高于 REF 返 0、低于则按罕见度罚(clamp 到 -LM_LO);
  完全未见 → -LM_LO。**只罚不奖**。
- 参数:`WREF=-700 WBETA=0.13 WHI=55 WLO=40 LM_REF=-520 LM_BETA=0.16 LM_LO=70`

### 3.3 集成点(每端在 sentenceT9 的 relax 里,跨词边界 `g += boundaryScore(pw, w)`)
- 安卓 `PinyinEngine.kt` sentenceT9 relax + `SentenceLanguageModel.kt`(HashMap 加载,READY 后异步挂载)
- iOS `PinyinEngine.swift` sentenceT9 relax + `SentenceLanguageModel.swift`(mmap + 字节二分,内存友好)
- 鸿蒙 `PinyinEngine.ets` sentenceT9 relax + `SentenceLanguageModel.ets`(readRawTextFile → Map 解析)
- 挂载前 boundaryScore 返回 0 → 退化为原词频整句(不阻塞冷启动,无回归)。

### 3.4 验证结果(全部脚本量化)
- 关键 case 8/8 全对(搬过来 / 堪称完美 / 完美完美 / 喝杯咖啡…)
- 口语 held-out benchmark(800 例真实字幕句):基线 30.5% → **LM 36.2%**(+46 净,68 修复/22 回退)
- **全量历史回归:基线 V3 13/13、LM 模式 13/13 全绿**(权威门槛)
- 热态 ~4ms/次

### 3.5 三端编译状态
- 安卓 `:app:compilePreviewDebugKotlin` BUILD SUCCESSFUL ✅
- iOS `xcodebuild LobsterKeyboard` BUILD SUCCEEDED ✅
- 鸿蒙 `hvigorw assembleHap` BUILD SUCCESSFUL ✅

---

## 4. ⏸ 暂缓:2b 模糊音纠错(机制已验证,质量未达标)

**决策(用户拍板)**:2b **暂不上线**。原因是它在合理投入下达不到"不误纠优先"的质量。

### 已做的验证(勿丢弃,续做的起点)
- 机制成立:模糊约简数字键索引(chi→去h→ci→24;bang→去g→ban→226)+ 独立模糊解析 pass +
  句相干性门槛注入(**不碰主 DP**,符合"字面永远在、只对垃圾字面句触发"的 spec)。
- 参照实现:`tools/keyboard-verify/engine_lm.py` 里 `build_fuzzy_index / fuzzy_correction / _sentence_dp`
  (默认不建索引 → 不触发,不影响 2a)。验证脚本 `validate_fuzzy.py`、`lock_fuzzy_params.py`。

### ❗ 阻塞点(续做前必读)
1. **recall 低**:真实单错打错句 recall 仅 ~1/8。多数典型 typo(nicifanlema→你吃饭了吗、sangban→上班)
   出 None——因为字面存在"少分段的长词垃圾解析"(品牌词如"澳柯玛"制造看似合理的字面句),
   SENT_PEN 偏置让长词赢,模糊纠正句补不回来。
2. **precision 未到 100%**:字面正确的 154 句中仍有 ~2 例误纠(1.3%,如"多起纵火案"→"顿是纵火案")。
3. **根因**:字/词 bigram 上下文不够强;boost 是钝器(调大→"吃饭"漂成"吃饭冷");
   相干性门槛无法可靠区分"用户打错" vs "打对但有更通顺的模糊变体"。
4. **正解方向(未做)**:需要更强 LM(trigram / KenLM / 训练模型)+ 更精细的"仅当字面含 OOV/罕见词才触发纠错"
   门控。这是**独立的大项目**,不是调参能收敛的。

---

## 5. 关键文件与复现

### 验证脚本(`lobster-input-android/tools/keyboard-verify/`)
- **参照引擎**:`engine_lm.py`(EngineLM = EngineV3 + 词/字 bigram;默认加载 assets 资产)
  依赖 `char_lm.py`、`engine_v3.py`、`engine_v2.py`、`engine.py`
- **LM 数据构建**:`build_char_bigram.py`(字级)、`build_word_bigram.py`(词级,需 jieba)
- **回归门槛**:`run_regression_v3.py`(基线 13 电池)、`run_regression_lm.py`(LM 模式,权威)
- **效果基准**:`bench_lm.py`(held-out benchmark)、`gen_benchmark.py`、`bench_sub.tsv`
- **2b 相关**:`validate_fuzzy.py`、`lock_fuzzy_params.py`、`proto_fuzzy.py`

### 语料与 LM 重建(换机需重下语料)
```bash
# 语料(Leipzig + OpenSubtitles)
curl -sL "https://downloads.wortschatz-leipzig.de/corpora/zho_news_2007-2009_1M.tar.gz" -o /tmp/n.tar.gz
curl -sL "https://downloads.wortschatz-leipzig.de/corpora/zho_wikipedia_2018_300K.tar.gz" -o /tmp/w.tar.gz
curl -sL "https://object.pouta.csc.fi/OPUS-OpenSubtitles/v2018/mono/zh_cn.txt.gz" -o /tmp/os.gz
# 字幕前 16M 行做训练(sub_train.txt),末 30 万留 benchmark(sub_test.txt)
pip3 install jieba   # 词bigram 需要
python3 build_char_bigram.py sub_train.txt news wiki --out char_bigram.txt --topk 256 --min-count 3
python3 build_word_bigram.py sub_train.txt news wiki --out word_bigram.txt --max-lines 6000000 --topk 32 --min-count 5
```
> 注意:改 LM 数据或参数后,**必须同步三端 SentenceLanguageModel + 重跑 run_regression_lm.py 全绿**再落地。

---

## 6. 发布状态(见文末,随本次一起提交)
- 安卓:**已发 UAT `vc112 / 0.0.3`**(`assembleUatDebug` → `r2_publish.py --env uat`,R2 `uat/android/` +
  迁移桥镜像 `android/preview/update.json`;签名指纹 `00ef3d…8c4` 匹配,回读线上一致)。
- 鸿蒙:编译通过(如需签名包走 RELEASE.md)。
- iOS:编译通过。

## 7. 其它待办(本轮完成 / 剩余)
- **问题1(中英↔九宫格模式切换 UX)—— ✅ 本轮已修复上线**。
  根因:MODE_CYCLE 环把 `[中九,中26,英,俄,韩]` 串一起,中九→英要**经过中26**并 `persistNineGrid(false)`,
  之后 LANG 切回中文就停在中26(反人类)。修复=**语言/布局解耦**(对齐搜狗/Gboard):MODE_CYCLE 只循环
  语言 `[中,英,俄,韩]`,`cycleMode` 绝不动 nineGrid(切回中文用记住的布局);九宫格↔26键由工具页(⚙齿轮)
  布局磁贴独立切换(中26 一键可达)。三端 `KeyboardController.{kt,swift,ets}` 的 modeRing/cycleMode/nextModeLabel
  同步改。状态机验证 `test_mode_switch.py`(复现 bug 路径 + 验证修复,已入回归电池,基线/LM 双模式 14/14 全绿)。
- **2b 模糊音纠错 / 2c 纠错标注 UX —— 暂缓**(见 §4,质量未达"不误纠优先",需更强 LM,独立项目)。
