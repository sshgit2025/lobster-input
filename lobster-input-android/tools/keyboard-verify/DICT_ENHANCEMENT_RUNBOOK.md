# 内置词库增强迭代手册(Runbook)

> 每次想给键盘词库"加词/调排序"时,从上往下照做即可。省略任何一步都可能复现历史踩过的坑。
> 引擎层设计与打分规则见同目录 `CUSTOM_DICT_V2_DESIGN.md`;本文件只讲**迭代流程**。
> 权威工作目录:`lobster-input-android/tools/keyboard-verify/`(**工作区根下的
> `scratch-keyboard-verify/` 是废弃的旧副本,严禁使用**——它的 `custom_dict_generated.txt`
> 停留在 2026-07-08,曾造成基线回归误报红灯)。

## 0. 版本史(先读,避免重复造轮子)

| 版本 | 时间 | 内容 | 词条/体积 |
|---|---|---|---|
| v2 | 2026-07-09 | T1 base残余27.5万 + T2 ext全量33.7万 + T3 jieba缺词 + T4 热词106(`gen_custom_dict.py` 全量重建) | 61万/16.7MB |
| v2+T5 | 2026-07-10 | T5 专名66万(搜狗城市词库;**爬取产物当时留在会话临时目录已丢失**,教训:一切管线入库) | 127万/35.2MB |
| v3 | 2026-07-17 | T6 品牌12万 + T7 口语组块 + T4b 口语加权(`gen_custom_dict_v3.py` **增量合并**) | 139万/39.0MB |

## 1. 不可破坏的不变量(改词库前逐条默读)

1. **零重复**:新词与主词库(`pinyin_dict.txt`)按词粒度零重复;与现有自定义资产零重复。
2. **增量合并**:线上 `custom_dict.txt` 是**不可变基线**——只追加、等级只升不降,绝不重建
   (v2 全量重建依赖的 T1/T2/T5 源已部分丢失,重建=丢词)。用 `gen_custom_dict_v3.py`。
3. **level 量纲与阈值表**(cap 155,与主词库 log2 量纲一致):

   | 阈值 | 含义 |
   |---|---|
   | ≥160 | 主词库高频线,自定义词永不可及(cap155)= 九宫格 top1 零回归硬保护 |
   | 142 | 精选热词/口语加权层(T4/T4b,人工背书) |
   | 128 | **组块种子最低值**:26键整句段惩罚300,组块需 lv>122 才能两段压三段(T9 是380,阈值更低) |
   | 120 | 知名品牌种子(允许进补全预测) |
   | ≥110 | 补全预测门槛:低于它的词只在"打全"时可达,绝不进预测/联想 |
   | 85 | jieba 挖掘组块默认值 |
   | 60/55/40 | 爬取品牌默认/ext默认/T5专名默认(长尾,只保打全可达) |
4. **体积预算**:当前 42MB(39.0MB 已用)。超预算优先收紧 `--brand-max` 类参数,预算上调需
   评估:iOS 键盘扩展内存(mmap 缓解)、鸿蒙 Uint8Array 全量驻内存、加载耗时(异步挂载不阻塞)。
5. **引擎零改动优先**:排序类问题先做数据层归因(banxiu/请叫我 两案例都是语料年代问题,
   数据层修复)。确需改引擎:先在 `engine_v3.py` 镜像实现→电池验证→再按
   `CUSTOM_DICT_V2_DESIGN.md` §2 逐条移植三端。
6. **格式**:主词库同格式分组行 `拼音连写key\t词1 lv1 词2 lv2 ...`,key 升序、key 内 lv 降序;
   词 2-8 字全 CJK;拼音可切合法音节且可映射 T9 数字码。

## 2. 数据源与管线(全部已入库,勿再放临时目录)

| 脚本 | 用途 |
|---|---|
| `sogou_scel.py` | 搜狗 .scel 解析(拼音表@0x1540/词表@0x2628;保留人工音节边界,**勿贪心重切**) |
| `crawl_sogou_brands.py` | 搜狗细胞词库爬取:类目遍历+关键词搜索→`brand_words.tsv`(词\t音节\t来源) |
| `gen_custom_dict_v3.py` | **增量合并生成器**(当前主力):现有资产+新层→新词库文件;种子表也在此文件内 |
| `gen_custom_dict.py` | v2 全量重建生成器(仅考古/参考,勿再用于生成) |

爬取注意(历史实测):
- 搜狗搜索 URL 关键词必须 **GBK 编码**;搜索是**整串匹配**,组合词("运动品牌")命中为 0,
  用单词关键词 + 类目遍历(品牌相关:428时尚品牌/432汽车/395美容/397服饰/394家电/402饮食;
  P1 类目:426影视/429明星/436游戏/404动漫);本机 CA 缺失需 `ssl._create_unverified_context()`。
- 类目列表页无 detail 链接,直接解析 `download_cell.php?id=..&name=..`(name 为 UTF-8 urlencode)。
- 店铺/公司自建词库是垃圾大头:靠下载量阈值(dl≥100)+ 标题过滤 + `SPAM_RE`(旗舰店/有限公司…)。
- **勿从 tencent.dict.yaml 批量挖词**:它是字典序无词频平表,cap 只会装进字母序前缀垃圾(已试已弃)。
- 知名品牌爬不全(斯凯奇/名创优品都是种子兜底的),**每轮必须人工补种子**(`BRAND_SEEDS`)。
- 外部词库源(rime-ice/jieba/SUBTLEX)下载命令见 `gen_custom_dict.py` 头注释;pip 在本机网络
  策略下不可用(wordfreq/pypinyin 装不了),别指望装新库。

## 3. 生成步骤

```bash
cd lobster-input-android/tools/keyboard-verify
# 1) (如需新爬)爬取词源 → brand_words.tsv;数据目录放会话外的持久位置或立即用完
python3 crawl_sogou_brands.py --out-dir <数据目录>
# 2) 编辑 gen_custom_dict_v3.py:新增/修改种子表(BRAND_SEEDS/CHUNK_SEEDS/COLLOQUIAL_BOOST)
#    或新增层(仿 T6/T7 写法:consider() 自动做零重复+音节校验+数字码校验)
# 3) 生成(产物 custom_dict_v3_generated.txt,已 gitignore)
python3 gen_custom_dict_v3.py --brand-src <数据目录>/brand_words.tsv
# 4) 看输出统计:词条数/体积/各层计数/dup/invalid/spam;超 42MB 预算必须先收紧再继续
```

新增种子的拼音用 v 代 ü(lv/nve),多音字按品牌实际读音人工标注;组块种子读音由主词库
词级 key 拼接天然正确(`MainWordIndex.decompose`,其 DP 的 NEG 哨兵必须是 `(-1e9,-1e9)`,
曾因 `(-1,...)` 挡掉所有多段路径)。

## 4. 验证步骤(顺序执行,全绿才允许落地)

**第一步永远是:先跑当前基线,确认改动前就是全绿。** 基线红灯必须先归因
(上次红灯就是 scratch 旧副本词库文件造成的误报),绝不能带着红灯做改动。

```bash
cd lobster-input-android/tools/keyboard-verify
# 1) 基线(引擎读线上资产 assets/custom_dict.txt)
python3 run_regression_v3.py                       # 必须 N/N 全绿
# 2) 新词库全量回归(CUSTOM_DICT 环境变量指向新产物)
CUSTOM_DICT=$PWD/custom_dict_v3_generated.txt python3 run_regression_v3.py
# 3) v2 时代补充电池(不在 runner 清单,单独跑)
CUSTOM_DICT=$PWD/custom_dict_v3_generated.txt python3 test_custom_dict.py
# 4) 新增层必须写专属电池(仿 test_brands_chunks.py 的 A-G 结构,见下),加入
#    run_regression_v3.py 的 BATTERIES 清单,永久成为回归资产
```

专属电池的必备断言(照 `test_brands_chunks.py` 抄结构):
A 数据完整性(现有条目原样保留/只升不降/与主词库零重复/体积预算)
B 新词可达性(种子点名词 top3 + 随机抽样打全必可达,26键+T9 双通道)
C/D 本轮针对性案例(用户报障输入串的前后对比)
E **预测纪律**(lv<110 新词绝不出现在前缀预测/补全前排;允许预测的种子单独断言)
F 高频主词 top1 零回归(vs 线上资产 A/B,26键+T9)
G 性能(渐进击键 max 时延)与加载时长

### 回归电池清单(`run_regression_v3.py` BATTERIES,新增电池务必登记进去)

| 电池 | 覆盖 |
|---|---|
| test_v2.py | T9不完整拼音/自造词/补全限量/旧修复回归/性能 |
| test_full_coverage.py | 单字全量可达(yi打不出咦) |
| test_choice_memory.py | 用户选择记忆(RIME调频对齐) |
| test_seg_fix.py | 切分歧义(huana)+锁定边界+性能 |
| test_t9_lock.py | T9锁定音节栈交互 |
| test_t9_typo_tolerance.py | 九宫格错键容忍(Gboard对齐) |
| test_t9_prefix_lock.py | 单键/前缀锁定点选 |
| test_symbol_autoreturn.py | 符号页点选自动回跳(状态机模型) |
| test_key1_symbols.py | 九宫格1键高频符号候选 |
| test_proper_nouns.py | T5专名(报障词/抽样可达/预测零污染/零回归/性能) |
| test_voice_toolbar_layout.py | 语音工具栏布局预算模型 |
| test_t9_selector_persist.py | 候选拼音列常驻可改选 |
| test_brands_chunks.py | T6品牌/T7组块/T4b口语加权(v3) |
| (单独跑)test_custom_dict.py | v2数据完整性/去重健壮性/biang showcase |

## 5. 三端落地(纯数据更新时)

```bash
# 同一份产物分发三端(文件名均为 custom_dict.txt,引擎零改动)
cp custom_dict_v3_generated.txt ../../app/src/main/assets/custom_dict.txt
cp custom_dict_v3_generated.txt ../../../lobster-input-ios/LobsterKeyboard/Resources/custom_dict.txt
cp custom_dict_v3_generated.txt ../../../lobster-input-harmony/entry/src/main/resources/rawfile/dict/custom_dict.txt
```
iOS 工程用文件系统同步组,同名替换零工程改动;鸿蒙 rawfile 同理。
涉及引擎改动时:安卓为源头实现→iOS/鸿蒙逐条对齐(参照 `CUSTOM_DICT_V2_DESIGN.md` §2 与
各端 CustomDictionary 实现;鸿蒙算法层零 @kit、IO 走 DictionaryLoader 注入)。

## 6. 发版与提交(三仓分开操作)

1. **安卓**:双环境双 flavor,versionCode **全局单调递增跨环境不复用**(先查两环境文档的当前值)。
   - preview(内测 .cn):`docs/android-online-update-release-preview.md`;
     `./gradlew assemblePreviewDebug` → 反查 manifest/签名 → `python3 tools/release/r2_publish.py --env preview --notes "..."`
   - uat(公测 .com,老用户):`docs/android-online-update-release-uat.md`;
     `assembleUatDebug` → `r2_publish.py --env uat`(自动镜像迁移桥 `android/preview/update.json`)
   - 发完:线上 update.json 回读验证 + 同步文档"当前版本"行与 `r2_publish.py` 的 ENV_VERSIONS。
2. **鸿蒙**:`RELEASE.md`;提 `AppScope/app.json5` 版本 → `scripts/release.sh` 出签名 .app →
   人工上传 AGC。
3. **iOS**:`xcodebuild -project lobster-input-ios.xcodeproj -scheme lobster-input-ios -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` 零错误。
4. 三仓各自 commit+push(提交信息记录:各层词数/体积/电池结果/案例前后对比);
   39MB 生成产物已 gitignore,资产文件本身随仓库提交。
5. 提交前 `git status` 逐文件核对——工作区可能混有其它任务的未提交改动,确认取舍后再 `git add`。

## 7. 历史坑速查(每条都真实发生过)

| 坑 | 结论 |
|---|---|
| 验证管线放会话临时目录 | 会话清理即丢失(T5 爬取管线/词库源均丢过)→ 一切脚本入库本目录 |
| scratch-keyboard-verify 旧副本 | 词库文件停在 07-08,基线误报红灯 → 只用本目录 |
| 贪心音节校验 | 误杀 zuoleyinianduo 类合法键 → 校验用回溯,加载器不做音节校验 |
| 整句输出改"遍历全部末态" | 放出 V2 原本压制的垃圾整句(民梦/大破)→ 保持 top-2 末态 |
| 整句 DP 千倍跳转增益 | 单词条 showcase 设计,海量词会摧毁整句评分 → 同量纲 lv-SENT_PEN |
| tencent 批量挖组块 | 字典序无词频,cap 装进垃圾 → 只用 jieba 词频背书 + 人工种子 |
| 搜狗组合词搜索 | 整串匹配命中 0 → 单词关键词 + 类目遍历 |
| 组块 lv 85 翻不动 26 键整句 | 26键段惩罚300 vs T9 380,种子须 lv≥128 |
| decompose NEG 哨兵 (-1,...) | 挡掉一切多段路径 → 必须 (-1e9,-1e9) |
| 发版忘了全局 versionCode | uat/preview 绝不复用同号;uat 首发须压过历史旧 preview 最高号 |
