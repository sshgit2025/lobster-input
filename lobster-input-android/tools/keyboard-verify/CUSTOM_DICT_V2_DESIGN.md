# custom_dict v2:海量内置自定义词库 — 三端落地设计(已经 Python 参照实现全量验证)

> 词库**迭代流程**(数据源/生成/回归电池清单/发版步骤/历史坑)见同目录 `DICT_ENHANCEMENT_RUNBOOK.md`;本文件只讲引擎设计与打分规则。

2026-07-09。Python 参照实现:`engine_v3.py`;词库生成:`gen_custom_dict.py`;
专属电池:`test_custom_dict.py`(20/20);历史回归:`run_regression_v3.py`(6/6 电池)。

## 1. 词库数据

- 产物:`custom_dict_generated.txt`,**61.3 万词 / 58.7 万 key / 16.7MB**,
  格式与主词库 `pinyin_dict.txt` 完全一致:`拼音连写key\t词1 lv1 词2 lv2 ...`
  (key 升序、key 内 lv 降序)。**替换**三端 assets/Resources/rawfile 里的旧 `custom_dict.txt`
  (旧 3 列平铺格式废弃;biangbiangmian→𰻞𰻞面 500 已并入新文件)。
- 来源与词频等级(与主词库同量纲 `level=round(log2(freq+1)*10)`,cap 155):
  - T1 base 残余 27.5 万:rime-ice base 被当年 top200k 截断的词(freq 2~1755),真实词频直算
    ——用户感知"常用词缺失"的主因;
  - T2 ext 全量 33.7 万:rime-ice ext(网络热词/流行语/新词/专名),有 jieba 词频者线性标定
    (level≈94.8+6.65*log2(jf),由 8 万主词库交集最小二乘拟合),无则默认 55;
  - T3 jieba 高频缺词 7 个;T4 精选现代热词 106 个(29 新增 + 77 提档,HOT_LEVEL=142,
    清单在 gen_custom_dict.py `HOT_WORDS`)。
- 硬保证:与主词库**零重复**(词粒度,A1 断言);内部零重词(A5);全 CJK 2-8 字;
  拼音可完整切分合法音节且可映射 T9 数字码。
- level cap 155 < 160:自定义词纯词频**永不翻越**主词库高频词 top-1(九宫格正向硬保护,D1/D2 断言)。

## 2. 引擎改动(三端逐条对齐 engine_v3.py)

### 2.1 新增 CustomDictionary(替代 customWords 线性表)
- 存储:与主词库同构。**iOS 直接复用 ByteTable**(mmap);Android 建议移植 ByteTable 到 Kotlin
  (MappedByteBuffer/byte[]+偏移数组,避免 59 万 String 撑热堆);鸿蒙用 Uint8Array+偏移
  Int32Array(单 buffer 对 GC 友好)。退而求其次各端复用现成 SortedTable 也功能正确。
- T9 数字码索引:与主词库 buildT9Index 同法(key→数字码排序数组+行号引用)。
  59 万 key 排序在后台/分块做;鸿蒙若排序过慢可离线预生成排列文件(暂不需要)。
- API 对齐主词库:`exact / prefix / bestWord / t9ExactWords(exact_by_digits) /
  t9PrefixWords(prefix_by_digits)`;新增 `maxDigitLen`。
- 加载器**不得**用贪心 allValidSyllables 校验(会误杀 zuoleyinianduo 这类回溯才可切的合法键;
  数据在生成期已保证合法,运行时只需跳过格式坏行)。

### 2.2 加载时序(防冷启动回归)
主词库+用户词典就绪即置 READY(解除输入遮罩)→ **自定义表后台异步挂载**,挂载前查询按空表
返回,挂载完成后失效 t9_cache。py 参照加载 2.2s,原生预期 <1s。

### 2.3 查询整合(每处都有 engine_v3.py 对应行)
26 键 `candidates()`:
- custom exact 与主词库 exact 同层同权:`layerScore(LAYER_EXACT, lv, w)`;
- custom prefix 补全:同罚分 `(klen-n)*PEN_MISS`,**仅 lv≥110**(CUSTOM_COMPLETION_MIN_LV,
  低置信长尾词不做预测,防"我想@woxiangch 被弱补全挤出前排");
- `hasFullWord` 计入 custom exact/prefix(只有自定义词能整词覆盖时整句不得抢 LAYER_SENTENCE);
- 26 键整句 DP `sentence_candidate`:span bestWord 取 max(主词库, custom);
- 精确保底集 = 主词库 exact ∪ custom exact。

T9 `candidatesT9()`:
- 词层循环上限:`L≤MAX_T9_WORD_DIGITS(9) 或 L==n`,**主词库与自定义对称**——全消耗整词不限长
  (修:第六章@10位/事业单位@11位 打全终于直接可排,验证为正向翻转;biang@14位 不再丢);
- custom 全消耗(L==n)分层规则:同码存在主词库精确词 → `LAYER_EXACT+EXACT_FULL_BONUS`
  公平按 lv 竞争(防 61 万词劫持常用短码);同码无主词精确词 → `LAYER_SENTENCE+lv*LEVEL_W`
  (破防了/什么鬼 类新词不被整句垃圾压住;showcase 语义保留);用户选过(bonus>0)仍提
  LAYER_SENTENCE(选择记忆不变);
- custom 部分消耗(L<n):`LAYER_EXACT`(同主词库);
- T9 补全:custom `prefix_by_digits` 并入主词库补全统一 top-K 池(COMPLETION_TOP=12),
  同罚分,**仅 lv≥110**;
- 整句 `sentence_t9`:custom 并入 `top_t9_words` 词源(增益 lv-SENT_PEN,与主词库同量纲;
  **legacy 的 freq*LEVEL_W 千倍跳转增益废弃**——那是单词条 showcase 设计,海量词会摧毁整句
  评分体系);输出仍取 top-2 末态(位级对齐 V2,勿改成"遍历取前2合法"——会放出 V2 原本
  压制的垃圾整句,已验证撤销);
- `_t9_exact_set` 保底集并入 custom(打全必可达,C3/C4 断言);
- 锁定态:custom 候选同样过 `_locked_compatible` 边界过滤(带 pinyin key)。

### 2.4 删除
三处 `for cw in customWords` 线性扫描(26键/candidatesT9/sentenceT9)与 `loadCustomWords`
旧解析,全部由 CustomDictionary 调用取代。

## 3. 已验证结论(2026-07-09,py 参照)

- 历史电池 6/6:test_v2 / full_coverage / choice_memory / seg_fix / t9_lock / typo_tolerance
  (3 处测试数据随词库时代更新,见各文件内注释:绝绝子→魔卡泡泡、A0/A4 新基线、补全限量 45→60);
- 专属电池 20/20:零重复/去重健壮性(重复词只展示一次且高分保留)/热词 26 键 top5 与 T9 top10
  全可达/随机 550 词打全必可达/高频主词 top1 零回归(T9 另有 7 例正向翻转)/性能
  (26 键 max 1.6ms、T9 max 2.3ms,py 参照,阈 80ms);
- 场景脚本 fancy/repro/hangul/symbols 全过。

## 4. 落地清单(等三端外部改动推送后执行)

1. 三端替换词库资产 + 新增 CustomDictionary + 引擎整合(见 §2);
2. 验证脚本迁入 `lobster-input-android/tools/keyboard-verify/`(修 ASSETS 相对路径),
   词库源文件下载方式写入 gen_custom_dict.py 头注释;
3. iOS 一键编译验证;Android 按发布文档发测试版;鸿蒙按发布文档打测试包;
4. 三端各自 git 提交推送(仓库分开操作)。
