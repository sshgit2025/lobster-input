# 计费经济性管理体系 · 权威设计与契约(Credit Billing Management)

> 2026-07-13。面向上线的成熟产品设计。本文是**前后端唯一契约来源**:任何一端实现
> 与本文不符即为 bug。配套经济核算见 `credit-pricing-economics-review.md`。

## 一、目标与边界

把积分扣费从"能跑但算不准、难扩展"的雏形,升级为**数据驱动、可运营管理、可校验**的计费体系:

- 每个扣费节点显式带**上游成本基准**,运营可按真实账单在管理端调整。
- 系统自动算出**每节点×每套餐的毛利率**,并对**每积分最低售价锚点**(通常 pro 年付)做
  **≥75% 最低毛利地板校验**(Tavily 等可豁免;备用 provider 仅告警不阻断)。
- 保存扣费规则时**强制地板校验**,不达标默认拒绝保存(可 force 强制)。
- 提供**按目标利润率反算建议积分**的校准助手。
- 计费口径修正(P0):LLM 类按 provider **真实 token**(替代失真估算)计费;图片输入**按图附加积分**。

不做(避免过度设计):不按套餐差异化单节点积分;不重写规则表结构;不引入用量分层/阶梯。

## 二、成本口径(重要,决定默认是否达标)

默认成本 `upstream_cost_cny` 采用各上游**按量付费(pay-as-you-go)的官方公开单价**,口径与 `unit` 对齐:

| provider | 节点 | 默认成本(CNY) | unit | 说明 |
|---|---|---|---|---|
| asr_dashscope | asr_transcribe | 0.0132 | minute | qwen3-asr-flash 按量 |
| asr_qwen_realtime | asr_realtime_transcribe | 0.0132 | minute | qwen 实时 |
| asr_volcengine | asr_transcribe | 0.0088 | minute | 火山 seed-asr **按量** |
| asr_volcengine_realtime | asr_realtime_transcribe | 0.0088 | minute | 火山实时 **按量** |
| asr_openai(Whisper) | asr_transcribe | 0.043 | minute | 备用,is_fallback |
| asr_groq | asr_transcribe | 0.0134 | minute | 备用,is_fallback |
| llm_aliyun(*) | llm_* / intent | 0.002 | 1k_tokens | qwen-plus 输出价,保守 |
| search_qwen | web_search | 0.004 | request | qwen enable_search |
| search_tavily | web_search | 0.058 | request | **margin_floor_exempt** |

> ⚠️ **采购口径警示**:火山 ASR 若走**并发包月**且并发利用率偏低,等效每分钟成本会升到
> ¥0.12(30% 利用)甚至更高,届时火山节点在默认 100 积分下会跌破 75% 地板。
> **建议 ASR 走按量付费**;若确实用并发包月,运营须在管理端把火山成本改成真实等效值,
> 系统会自动标红并给出达标所需积分。默认值代表按量口径下的健康基线。

## 三、数据模型

### credit_pricing_rules(system_config,数组)
每条规则:
```
node_id, category, provider_id, platform_code, model, unit, credits, enabled   # 原有
upstream_cost_cny   float   # 上游单位成本(CNY),口径同 unit
cost_source         str     # 成本来源(官方定价页/账单),审计用
cost_updated_at     str     # 更新时间
margin_floor_exempt bool    # true=不参与地板校验(Tavily)
is_fallback         bool    # true=备用 provider,不达标仅告警(warning)不阻断
```

### credit_pricing_policy(system_config,对象)
```
margin_floor_ratio        0.75    # 最低毛利地板
margin_alert_threshold    0.30    # 低于此值看板标红
image_surcharge_credits   15      # 含图片请求每图附加积分(P0)
min_credit_sale_price_cny 0.0016  # 每积分最低售价参考(pro 年付锚点)
```

## 四、利润率算法(margin_engine,纯函数)

- **每积分售价** = 套餐月均价 / 套餐每月积分额度(整期价按账期月数摊回月均;USD 按 `cny_per_usd` 折 CNY)。
- **毛利率** = (credits × 每积分售价 − upstream_cost) / (credits × 每积分售价)。
- **全局最低每积分售价** = 所有套餐×账期里的最小值(毛利最差锚点,通常 pro 年付)。
- **地板校验**:逐 节点×套餐 取最差毛利;`margin_floor_exempt` 跳过;`is_fallback` 不达标记 warning;
  其余不达标记 critical → `passed=false`。每个不达标项给出最差套餐下**达标所需积分**。
- **反算**:以全局最低售价锚点,给定 target_margin 反算各节点建议积分 = ⌈cost / (售价×(1−target))⌉。

## 五、API 契约(业务后端 `/api/v1/config/*`,内部 HMAC 鉴权 verify_internal_api_key;管理端经 `/api/v1/billing-margin/*` 代理)

鉴权头三件套:`X-API-Key` / `X-Internal-Timestamp` / `X-Internal-Signature`。

1. **GET /billing-rules** → `{ "rules": [规则...], "policy": {策略...} }`
2. **POST /billing-rules** body `{ rules?, policy?, force? }` →
   - 达标或 force:`{ "saved": true, "forced": bool, "floor_check": {...} }`
   - critical 不达标且未 force:**HTTP 200** `{ "saved": false, "floor_check": { "passed": false, "violations": [...], "critical_count", "warning_count" }, "message": "..." }`
3. **GET /billing-margin-report** → `{ sale_price_table:[...], global_min_credit_sale_price:{plan_code,cycle,credit_sale_price_cny}, matrix:{ rows:[{node_id,provider_id,unit,upstream_cost_cny,is_fallback,margin_floor_exempt,min_margin,max_margin,cells:[{plan_code,cycle,margin,status}]}], skipped:[...] }, floor_check:{...}, policy:{...} }`
   - cell.status ∈ `green|yellow|red|unknown`(red<alert_threshold,yellow<floor,green≥floor)。
4. **POST /billing-calibrate** body `{ target_margin:0~1 }` → `{ target_margin, based_on:{锚点}, suggestions:[{node_id,provider_id,unit,upstream_cost_cny,current_credits,current_margin_at_anchor,suggested_credits,delta}], skipped:[...] }`

> 前端务必按上述**真实字段**读取:失败判定用 `resp.saved===false` + `resp.floor_check.violations`;
> 看板锚点用 `global_min_credit_sale_price.credit_sale_price_cny`;矩阵用 `matrix.rows[].cells[]`。

## 六、管理端界面(lobster-input-admin,`/billing-margin`)

1. **利润率看板**:`matrix.rows` × 套餐列的毛利矩阵,按 cell.status 红/黄/绿;顶部全局最低每积分售价、
   critical/warning 计数、地板阈值。豁免/备用节点特殊标注。
2. **成本录入 + 规则结构化管理**:表格编辑各规则 credits / upstream_cost_cny / cost_source /
   margin_floor_exempt / is_fallback / enabled;保存走 POST,critical 不达标弹告警明细(可强制)。
3. **定价校准助手**:输入目标利润率(默认 0.75)→ calibrate → 建议积分 vs 现值,可一键回填。
4. **策略编辑**:policy 四项(地板/告警阈值/图片附加积分/最低售价参考)。

## 七、P0 计费口径修正(接线要求)

- **真实 token**:LLM 类扣费的 `unit=1k_tokens` 计量,优先取 `UsageEvent` 的 provider 真实
  `YOUR_SECRET_FROM_SECRET_STORE`,拿不到才回退文本估算。不得再用只数结果文本的失真估算。
- **图片附加积分**:含图片输入的请求,按图片张数追加 `policy.image_surcharge_credits`(默认 15)/图。
- 两项只影响"每次扣多少积分",不改变节点单位毛利率;但修正后计费不再失真。
