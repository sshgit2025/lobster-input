# 积分扣费经济性与配置重构评估报告

> 版本：2026-07-12 ｜ 范围：lobster-input-backend + lobster-input-payment
> 目的：核算每个积分扣费节点的经济合理性与利润率，评估积分扣费配置是否需要重构
> 说明：本报告为**纯分析产出，未修改任何业务代码或配置**。

---

## 0. 执行摘要（TL;DR）

- **积分扣费已经是集中式动态配置**：所有节点扣费统一由 `system_config.credit_pricing_rules`（`PlanRepository.DEFAULT_CREDIT_PRICING_RULES`）驱动，一张规则表 + 通配符打分匹配器（`CreditCalculator._match_credits`）。**不是散落硬编码**，这一点比预期好，结构基本合理。
- **利润率结论**：
  - **LLM 类节点（改写/转写纠偏/意图/quick-action/openclaw，40 或 20 积分/千 token）与联网搜索（250–300 积分/次）——毛利率极高（>90%，甚至 >99%），属"畸高"**，不是风险，反而有下调空间或作为溢价项保留。
  - **ASR 语音识别（100 积分/分钟）是唯一的倒挂风险节点**。在**高价套餐（尤其 pro 年付）**下，1 积分售价被摊薄到 ≈¥0.0016，100 积分/分钟 ≈ ¥0.16/分钟；若实时大模型 ASR（火山引擎 seed-asr 实时版）真实成本落在 ¥0.16–0.48/分钟区间，则**存在打平到亏损的可能**。这是最需要落实上游真实单价去确认的点。
- **两个结构性隐患（建议修）**：
  1. **计费 token 用的是本地字符估算 `_estimate_tokens`，只数 transcript+result 文本，忽略 system prompt / few-shot / 剪贴板 / 图片**，导致计费 token 数比真实上游 token 数低 10–50 倍。对毛利无害（费率本身高倍加成兜底），但**积分与真实成本脱钩**，且图片/长上下文场景严重欠计费。系统其实已经在 `UsageEvent` 里拿到了 provider 返回的真实 token，却没用于计费。
  2. **同一节点在不同套餐下真实毛利率差 5 倍**（因为积分售价随套餐/周期变动 5 倍，而扣费积分数与套餐无关）。ASR 这种薄毛利节点在便宜套餐上可能倒挂——需要给高价/年付套餐设"每积分最低售价地板"或按套餐校准。
- **是否建议重构**：**不建议大改，建议小幅增强**。现有 rules 表模型已经足够直观可扩展。必要增强只有两项：①给规则加"上游成本基准"字段以支撑毛利视图与自动校准；②计费改用 provider 真实 token（已有数据）而非字符估算，并对图片/视觉输入加计费。其余为 nice-to-have。

---

## 1. 积分扣费节点全景（读代码结论）

所有扣费最终都走 `CreditAccountService.charge()`（`app/services/billing/credit_account_service.py`），扣减顺序：套餐积分 → bonus 奖励积分 → 付费加油包积分（`deduct` 内 plan→bonus→paid_topup）。计费金额由 `CreditCalculator`（`app/services/billing/credit_calculator.py`）依据 `credit_pricing_rules` 换算。

### 1.1 扣费规则表（当前默认，`DEFAULT_CREDIT_PRICING_RULES`）

| node_id | category | provider_id / platform | model | 计量单位 | 积分 | 上游 |
|---|---|---|---|---|---|---|
| `asr_transcribe` | asr | asr_dashscope / dashscope | qwen3-asr-flash | minute | **100** | 阿里云百炼 Qwen3-ASR-Flash |
| `asr_transcribe` | asr | asr_volcengine / volcengine | * | minute | **100** | 火山引擎 语音识别 |
| `asr_transcribe` | asr | asr_openai / openai | * | minute | **100** | OpenAI Whisper（兜底）|
| `asr_transcribe` | asr | asr_groq / groq | * | minute | **100** | Groq Whisper（兜底）|
| `asr_realtime_transcribe` | asr_realtime | asr_qwen_realtime / dashscope_realtime | qwen3-asr-flash-realtime | minute | **100** | 阿里云 实时 ASR |
| `asr_realtime_transcribe` | asr_realtime | asr_volcengine_realtime / volcengine_realtime | volc.seedasr.sauc.duration | minute | **100** | 火山引擎 seed-asr 实时大模型 |
| `llm_transcribe` | llm_chat | llm_aliyun / aliyun | * | 1k_tokens | **40** | 阿里云百炼 Qwen（转写纠偏 LLM）|
| `llm_rewrite` | llm_chat | llm_aliyun / aliyun | * | 1k_tokens | **40** | 阿里云百炼 Qwen（改写）|
| `openclaw_transcribe` | llm_chat | llm_aliyun / aliyun | * | 1k_tokens | **40** | 阿里云百炼 Qwen（OpenClaw 指令解析）|
| `android_quick_action` | llm_chat | llm_aliyun / aliyun | * | 1k_tokens | **40** | 阿里云百炼 Qwen（安卓/鸿蒙一键动作）|
| `intent_router` | llm_chat | llm_aliyun / aliyun | * | 1k_tokens | **20** | 阿里云百炼 Qwen（意图路由，减半）|
| `web_search` | web_search | search_qwen / aliyun_search | * | request | **250** | 阿里云 Qwen enable_search 联网 |
| `web_search` | web_search | search_tavily / tavily | * | request | **300** | Tavily 搜索 + Qwen 整理 |

> 注：历史上还有 `embedding_correction`（向量纠错）扣费项，已在 `_clean_credit_pricing_rules` 主动过滤剔除（对应 memory：preview-server-vector-cleanup，向量方案已弃用）。

### 1.2 每个节点的计量与触发位置

| 节点 | 计量方式 | 代码位置 | 触发条件 |
|---|---|---|---|
| ASR 录音转写 | `audio_cost` = ⌈(时长/60)×100⌉ 积分，按音频**秒→分钟** | `pipeline/v1,v2/audio_pipeline.py::transcribe`（预扣 `_estimate_asr_credits`，实扣 `credit_calc.audio_cost`）| 每次录音必扣，极速模式也扣 ASR |
| ASR 实时流式 | `audio_cost` 同上，按 PCM 字节数推时长 | `services/audio/realtime_asr.py::_charge_realtime_asr` | 流结束 `finished` 事件时结算 |
| LLM 转写纠偏 | `token_cost` = ⌈(in+out)/1000×40⌉ | `agent/nodes/transcribe_node.py`、`audio_pipeline.py::invoke_llm` | transcribe 非极速/非纯语气词时 |
| LLM 改写 | `token_cost` 40/千 token | `agent/nodes/rewrite_node.py`、`rewrite_pipeline.py` | rewrite；短文本无 hints 时可直返省积分 |
| 意图路由 | `token_cost` 20/千 token | `agent/nodes/`（intent_router）、`agent_pipeline.py` | agent 流程每次分类 |
| OpenClaw 指令 | `token_cost` 40/千 token | `agent/nodes/openclaw_node.py::_refine_with_openclaw_prompt` | OpenClaw 会话激活且执行时（on/off/new-session 不扣）|
| 安卓/鸿蒙一键动作 | `token_cost` 40/千 token（预扣+补差）| `services/account/android_quick_action_service.py` | 每次 quick action |
| 联网搜索 | `request_cost` 固定 250/300 积分/次（先预扣再执行，失败退款）| `agent/nodes/search_node.py::_precharge_search_credits` / `_apply_credits` | SEARCH 意图；Tavily 路径额外叠加优化词+整理两段 LLM token 费 |

**关键实现事实**：
- `token_cost` 的 `est_input/est_output` 全部来自 `CreditCalculator._estimate_tokens(文本)` —— **只对 transcript / selected_text / result 等纯文本做字符估算（中文×1.5、ASCII×0.25），完全不含 system prompt、few-shot 示例、剪贴板、图片**。而真实上游 token 里 system prompt + 示例经常是几百到上千 token 的大头。
- ASR 采用"预扣（按时长估算）→ 实扣 → 多退少补"，搜索采用"预扣 → 失败退款"。幂等与并发用 `DistributedLockRepository` 锁 `credits:{email}`。
- 所有扣费写 `CreditLedger`（含 breakdown），并**另有** `UsageEvent`（`data/usage`）记录 provider 返回的**真实 token 数**——真实成本数据其实已经落库，只是没进计费口径。

---

## 2. 套餐、免费额度与"1 积分售价"反推

### 2.1 套餐额度（`DEFAULT_PLAN_CONFIGS`，读代码确认）

| 套餐 | 每期积分 | 重置周期 | 有效期 | 付费 | 备注 |
|---|---|---|---|---|---|
| trial 免费试用 | 3000 | month | 7 天 | 否 | 注册自动发放，每人一次 |
| free 免费套餐 | 500 | **week** | 永久 | 否 | 每周重置 ≈ 2000/月 |
| lite 轻量 | 9000 | month | 1 月 | 是 | 月/季/年付 |
| standard 标准 | 30000 | month | 1 月 | 是 | 月/季/年付 |
| pro 专业 | 75000 | month | 1 月 | 是 | 月/季/年付 |

奖励积分（`DEFAULT_BONUS_CREDIT_POLICY`）：注册奖励、邀请奖励**默认关闭且额度 0**（`enabled: False`），敞口受控，好。

### 2.2 价格来源与"1 积分售价"

**重要**：付费套餐的**实际价格不在代码里**，而是在数据库 `system_config.payment_billing_config.channel_prices` / catalog `billing_prices`（管理端可改）。代码默认 `channel_prices: []`。仓库自带的 2026-03 DB 备份早于本轮计费重构（只有旧 `platform_credit_ratio`，无 `plan_configs`），拿不到线上真值。

因此本报告用**测试夹具中的价格**作为**中低置信度的代表值**（`tests/test_billing_catalog.py`、`test_payment_rules.py` 内的金额与汇率 `CNY rate_to_usd = 0.138 ⇒ 1 USD ≈ 7.25 CNY` 完全自洽，明显照搬了产品意图）：

| 商品 | 价格（测试夹具） | 折算 |
|---|---|---|
| lite 月付 | $9.90 / ¥69 | ≈ ¥71.8（自洽）|
| lite 年付 | $99 | ≈ 10 个月价 |
| pro 年付 | $200 / ¥1449.28 | ≈ ¥1450（自洽）|

由此反推"1 积分售价"（关键锚点，**中低置信度，需用线上真值复核**）：

| 锚点 | 计算 | 1 积分售价 |
|---|---|---|
| **A — lite 月付（零售/边际最高价）** | ¥71.8 ÷ 9000 | **≈ ¥0.0080/积分** |
| **B — pro 年付（量大/最低价）** | ¥1450 ÷ 12 ÷ 75000 | **≈ ¥0.0016/积分** |
| C — standard 月付（假设 $19.9≈¥144）| ¥144 ÷ 30000 | ≈ ¥0.0048/积分（**假设值**）|

> **结论**：同样 1 个积分，卖给 lite 月付用户 ≈ ¥0.008，卖给 pro 年付用户 ≈ ¥0.0016，**差 5 倍**。这是后面所有节点毛利率要"按套餐分档看"的根因。

### 2.3 免费额度的月度成本敞口

- **trial**：3000 积分/人 = 30 分钟 ASR（100/分）。上游 ASR 成本按 ¥0.02–0.48/分钟 ⇒ **每个试用用户成本 ¥0.6–14.4**（几乎全花在 ASR 上）。
- **free**：500/周 ≈ 2000/月 = 20 分钟 ASR/月 ⇒ **每活跃免费用户 ¥0.4–9.6/月**。
- 敞口整体可控（奖励积分默认关），但**与活跃免费/试用用户数线性增长**，且**几乎全部由 ASR 贡献**——再次指向 ASR 是唯一的成本要害。

---

## 3. 上游真实成本（官方定价查证）

> 计费单位与币种已标注；置信度分档。人民币/美元换算按 1 USD ≈ 7.25 CNY。

### 3.1 ASR 语音识别

| 上游 | 官方口径 | 折算/分钟 | 置信度 | 来源 |
|---|---|---|---|---|
| 阿里云 Qwen3-ASR-Flash | "文本不计费，按音频时长计费"，一处口径 $0.00192/分钟，另一处"约 2 美分/分钟"（互相矛盾）；国内约 ¥0.0132/分钟 | **¥0.014–0.14/分钟** | 低（来源自相矛盾）| aliyun model-pricing；OpenRouter |
| 火山引擎 大模型流式 ASR（seed-asr 实时/并发版）| 纯并发计费 **1500 元/并发/月**（豆包 2.0 并发版 500 元/并发/月）；或资源包+后付费按小时阶梯 | 按并发折算强依赖并发利用率；后付费估 **¥0.12–0.48/分钟** | 低-中 | 火山引擎 豆包语音 计费说明 |
| OpenAI / Groq Whisper（兜底，基本不用）| Whisper ~$0.006/分钟 | ≈ ¥0.043/分钟 | 中 | OpenAI 定价 |

> ASR 是本次核算**最不确定**的一环，也恰是**唯一有倒挂风险**的节点。**强烈建议向财务/采购确认线上实际走量的 ASR provider 与真实结算单价**（尤其火山引擎实时 seed-asr 是并发包还是后付费、单位分钟成本）。

### 3.2 LLM（阿里云百炼 Qwen，`llm_aliyun`）

| 模型 | 输入 | 输出 | 置信度 | 来源 |
|---|---|---|---|---|
| qwen-plus | ¥0.8/百万 token（¥0.0008/千）| ¥2/百万（¥0.002/千）| 中-高 | aliyun 定价；developer.aliyun 文章 |
| qwen-turbo | ¥0.3/百万 | ¥0.6/百万（估）| 中 | 同上 |
| qwen-flash | ≈¥0.15/百万（阶梯，含免费额度）| ≈¥0.4–1.2/百万 | 中 | eesel/pricepertoken |

> 规则里 model=`*`，任意 Qwen 都按 40 积分/千 token 计。取**最贵的 qwen-plus** 作为保守成本上界：**约 ¥0.001–0.002/千 token（in+out 混合）**。

### 3.3 联网搜索

| 上游 | 官方口径 | 折算/次 | 置信度 | 来源 |
|---|---|---|---|---|
| 阿里云 Qwen enable_search（agent 策略）| $0.573411/1000 次（国内/全球）+ 联网网页拼进 prompt 的 token 费 | 搜索费 ≈ ¥0.0042/次 + token | 高（搜索费）| aliyun web-search |
| Tavily advanced（search_depth=advanced）| 2 credits/次 × $0.005–0.008/credit | ≈ ¥0.07–0.12/次 + 两段 LLM 整理 token | 高 | Tavily docs/pricing |

---

## 4. 逐节点商业核算

**典型调用假设**（写清以便复核）：
- ASR 一次口述 **1 分钟**（保守偏长；实际很多是 10–30 秒）。
- LLM 改写/转写一次 **中文 ~40 字进 + ~50 字出**（计费口径下 ≈ 105 token → 5 积分）；**真实**上游 token 因含 system prompt/示例约 **1000–2000 token**。
- 搜索一次 = 1 request（+ Tavily 路径两段 LLM 整理）。
- 售价用锚点 A（lite 月付 ¥0.008/积分，毛利最好）与锚点 B（pro 年付 ¥0.0016/积分，毛利最差）双档。

### 4.1 汇总表

| 节点 | 计量 | 当前积分 | 售价@A(lite) | 售价@B(pro年付) | 上游真实成本 | 毛利率@A | 毛利率@B |
|---|---|---|---|---|---|---|---|
| **ASR 录音转写（qwen3-asr）** | 1 分钟 | 100 | ¥0.80 | ¥0.16 | ¥0.014–0.14 | 83–98% | **13–91%** |
| **ASR 实时流式（火山 seed-asr）** | 1 分钟 | 100 | ¥0.80 | ¥0.16 | ¥0.12–0.48 | 40–85% | **-200% ~ +25%（倒挂风险）** |
| LLM 转写纠偏 | ~105 计费token | 5 | ¥0.040 | ¥0.008 | ¥0.001–0.002 | ~97% | ~80% |
| LLM 改写 | ~105 计费token | 5 | ¥0.040 | ¥0.008 | ¥0.001–0.002 | ~97% | ~80% |
| 意图路由 | ~40 计费token | 1（下限） | ¥0.008 | ¥0.0016 | ~¥0.0005 | ~94% | ~69% |
| OpenClaw 指令 | ~105 计费token | 5 | ¥0.040 | ¥0.008 | ¥0.001–0.002 | ~97% | ~80% |
| 安卓/鸿蒙一键动作 | ~1500 计费token(含prompt) | ~60* | ¥0.48 | ¥0.096 | ¥0.002–0.004 | ~99% | ~97% |
| 联网搜索（Qwen）| 1 次 | 250 | ¥2.00 | ¥0.40 | ¥0.005–0.02 | >99% | ~96% |
| 联网搜索（Tavily）| 1 次 | 300 | ¥2.40 | ¥0.48 | ¥0.08–0.14 | ~95% | ~72% |

> \* 安卓 quick action 的预扣把 system prompt 也算进了 `_estimate_tokens(system_prompt + text)`（见 `android_quick_action_service.py`），所以它反而计费更足、毛利更高——这恰好反证了主链路 LLM 节点漏算 system prompt 的问题。

### 4.2 结论标注

- **倒挂/薄利风险（唯一红区）**：**ASR 实时流式（火山 seed-asr 实时大模型）在 pro 年付套餐**下最危险。¥0.16/分钟售价对 ¥0.12–0.48/分钟成本，**乐观 +25%、悲观直接亏损**。ASR 录音转写在 pro 年付下也只有个位数到中等毛利。**这是全系统唯一需要立刻用真实上游单价复核并可能调整积分数的节点。**
- **畸高（可作溢价或有下调空间）**：**联网搜索 250–300 积分/次毛利 >95–99%**；LLM 类节点毛利 80–99%。搜索单次吃掉 lite 用户 250/9000 ≈ 2.8% 月度积分、pro 年付 250/75000 ≈ 0.3%，对用户偏贵而对平台暴利——**可考虑降到 120–180 积分**改善体验，仍安全。
- **免费额度敞口**：见 2.3，全部集中在 ASR；只要 ASR 单节点不倒挂，免费敞口就可控。

---

## 5. 配置结构评估与重构建议

### 5.1 现状评价：结构已相当好，无需大改

`credit_pricing_rules` 已经是一张**统一的、动态可配、带优先级匹配**的计费规则表：
- 维度齐全：`node_id / category / provider_id / platform_code / model / unit / credits / enabled`，支持 `*` 通配 + 打分选最具体规则（`_match_credits` 的 32/16/8/4/2 权重）。
- 三种计量单位 `minute / 1k_tokens / request` 覆盖 ASR/LLM/搜索。
- 存 `system_config`、管理端可改、有清洗与默认回填（`_clean_credit_pricing_rules`）、有账本（`CreditLedger`）与真实用量（`UsageEvent`）。

**这已经是成熟的 usage-based metering 雏形，不是散落硬编码。** 因此**不建议推倒重构**，只建议针对性增强。

### 5.2 真正的问题（按必要性排序）

**必要（P0，影响利润准确性/防倒挂）**
1. **计费 token 口径失真**：主链路 `token_cost` 用 `_estimate_tokens` 只数 transcript+result 文本，漏掉 system prompt/few-shot/剪贴板/图片，比真实 token 低 10–50 倍。系统**已在 `UsageEvent` 拿到 provider 返回的真实 token**，却没用于计费。→ **改为用 provider 真实 usage token 计费**（或至少把 system prompt 长度并入，像 quick_action 那样）。当前靠高倍费率兜底不亏，但一旦为了体验下调 LLM 费率，失真会立刻放大风险。
2. **视觉/图片输入零计费**：`_estimate_tokens` 对 `clipboard_items` 里的 image 完全不计，而 qwen-vl 处理图片是最贵的 token 消耗。→ **对含图片的请求加固定图片附加积分**（如每图 N 积分）。
3. **ASR 未按 provider 差异化定价**：qwen3-asr、火山实时 seed-asr、Whisper 成本差一个数量级，却都是 100 积分/分钟。→ **规则表本就支持按 provider 分档，应给实时/大模型 ASR 单列更高积分**，并给高价/年付套餐设"每积分最低售价地板"（见下）。

**Nice-to-have（P1，提升可运营性，别过度设计）**
4. **规则缺成本基准，无法看毛利/自动校准**：规则只有 `credits`，没有"上游单价"。→ 给每条规则加可选 `upstream_cost`（`{amount, currency, unit}`）与 `updated_at`；管理端加一个**"节点 | 计量 | 积分 | 各套餐对应售价 | 上游成本 | 毛利率"**只读视图（数据全都已具备）。这一步就能把本报告的表格变成实时看板。
5. **按套餐的毛利分档不可见**：同一积分在不同套餐售价差 5 倍。→ 在上面的毛利视图里对每个节点按 lite/standard/pro×月/季/年展开，红黄绿标注倒挂。**不需要**引入"按套餐差异化积分"（会破坏积分的简单心智），用"地板价 + 毛利看板"即可。

### 5.3 建议的配置模型（增量，非重写）

保持现有 rules 表，仅**每条规则可选扩展**：

```jsonc
{
  "node_id": "asr_realtime_transcribe",
  "category": "asr_realtime",
  "provider_id": "asr_volcengine_realtime",
  "platform_code": "volcengine_realtime",
  "model": "volc.seedasr.sauc.duration",
  "unit": "minute",
  "credits": 100,
  "enabled": true,
  // ↓ 新增可选，仅供毛利视图与告警，不参与扣费逻辑
  "upstream_cost": { "amount": 0.30, "currency": "CNY", "unit": "minute", "confidence": "low", "as_of": "2026-07" }
}
```

以及一个**全局 `credit_pricing_policy`**（可选）：

```jsonc
{
  "min_credit_sale_price_cny": 0.0016,   // 每积分最低售价地板（年付套餐参考）
  "margin_alert_threshold": 0.30,        // 毛利率低于 30% 管理端标红
  "image_surcharge_credits": 30          // 含图片请求附加积分
}
```

管理端新增只读**"计费经济性看板"**：读 rules（credits）× billing_config（各套餐每积分售价）× upstream_cost → 输出第 4.1 那张毛利表并做红黄绿告警。**这是唯一建议新增的 UI**。

### 5.4 定价校准建议（基于毛利）

| 节点 | 现值 | 建议 | 理由 |
|---|---|---|---|
| ASR 实时 seed-asr | 100/分 | **待真实成本确认；若 ≥¥0.16/分则提到 150–200/分，或给年付套餐设售价地板** | 唯一倒挂风险 |
| ASR 录音 qwen3-asr | 100/分 | 维持（成本极低），或与实时拉开分档 | 成本远低于实时 |
| 联网搜索 Qwen | 250/次 | **下调至 120–150/次** | 毛利 >99%，对用户过贵 |
| 联网搜索 Tavily | 300/次 | 下调至 180–200/次 | 毛利仍 >90% |
| LLM 改写/转写/openclaw | 40/千token | 维持；但**先修 token 口径**再谈调价 | 口径修好前别动费率 |
| 意图路由 | 20/千token | 维持 | 合理 |

---

## 6. 上游定价来源与置信度

| 项 | 来源 URL | 置信度 |
|---|---|---|
| Qwen3-ASR-Flash 计费 | https://help.aliyun.com/zh/model-studio/model-pricing ；https://openrouter.ai/qwen/qwen3-asr-flash-2026-02-10/pricing | 低（两处口径矛盾）|
| 火山引擎 豆包语音/流式 ASR 计费 | https://www.volcengine.com/docs/6561/1359370 （并发 1500 元/并发/月、豆包2.0并发版 500 元/并发/月，或资源包+后付费小时阶梯）| 低-中（未取到完整分钟单价表）|
| Qwen-plus/turbo/flash token 价 | https://help.aliyun.com/zh/model-studio/model-pricing ；https://developer.aliyun.com/article/1714977 ；https://www.eesel.ai/blog/qwen-pricing | 中-高 |
| 阿里云 Qwen 联网搜索 | https://help.aliyun.com/zh/model-studio/web-search （agent 策略 $0.573411/1000 次 + token）| 高 |
| Tavily 搜索 | https://docs.tavily.com/documentation/api-credits ；https://www.tavily.com/pricing （basic 1 / advanced 2 credit，$0.005–0.008/credit）| 高 |
| OpenAI Whisper（兜底）| OpenAI 官方定价 ~$0.006/分钟 | 中 |

**低置信度重点**：所有 ASR 单价。结论对 LLM/搜索节点稳健（无论 ASR 真值如何都畸高毛利），但**"ASR 是否倒挂"这一核心判断依赖 ASR 真实结算单价**，务必用财务实际账单校准。

---

## 7. 一页纸行动清单

1. **[P0] 拿到线上真实数据复核**：①管理端/DB 里 `payment_billing_config.channel_prices` 的真实套餐价 → 校准"1 积分售价"；②财务侧火山实时 seed-asr 与 qwen3-asr 的真实分钟成本 → 判定 ASR 是否倒挂。
2. **[P0] 计费改用真实 token**：主链路 `token_cost` 从 `_estimate_tokens` 切到 `UsageEvent` 里 provider 返回的真实 token；含图片请求加附加积分。
3. **[P0] ASR 按 provider 分档 + 年付售价地板**：实时/大模型 ASR 单列更高积分，防高价套餐倒挂。
4. **[P1] 规则加 `upstream_cost` 字段 + 管理端毛利看板**：把本报告表格变实时红黄绿告警。
5. **[P1] 下调搜索积分**（250→120–150），改善用户体验，毛利仍安全。
6. **不做**：不引入按套餐差异化积分、不推倒 rules 表重写——现有结构已足够。
