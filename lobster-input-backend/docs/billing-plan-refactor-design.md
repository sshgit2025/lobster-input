# 套餐与计费重构设计(统一入口 · 稳定计费 · 异步执行)

> 2026-07-13。针对现状"配置双写、免费套餐语义混乱、per-provider 两套计费、计费同步阻塞 ASR、毛利体系过度治理"的重构。
> 锚点:回归 git 最早稳定版(`de1f547`)的极简三段式,只保留历史验证有用的增量,砍掉过度治理。

## 一、根因(调研确认)

1. **配置双写**:`system_config.plan_configs` 是运行时唯一真源(只有 PlanService 认),却被 PlansView(直接写 credits)和 BillingCatalogView(写 billing_plans.credits_per_period → 发布投影覆盖 plan_configs)两处写,不同步、互相回滚。DEFAULT 常量+清洗逻辑还各存三份。
2. **免费套餐语义混乱**:validity(有效期)与 reset_period(积分刷新周期)两个正交概念,free=永久+每周,三个页面文案不一致;trial=7天有效但 reset=月(自相矛盾,重置永不触发)。
3. **per-provider 两套计费**:同一 asr_transcribe 节点,不同 provider 配不同积分(100/110),用户按后台命中的 provider 被扣不同,无感知。
4. **计费同步阻塞 ASR**:扣费/退款/账本全在返回结果前 await,叠加分布式锁+无缓存读库。
5. **毛利体系过度治理**:75% 地板线上强拦截 / 校准 / is_fallback,对当前体量过重(设计文档自己都划了红线)。

## 二、目标架构:三件事彻底分离,各自单一真源与单一入口

| 关注点 | 是什么 | 单一真源 | 单一入口 | 计量口径 |
|---|---|---|---|---|
| **套餐 Plan** | 订阅授予什么:每期积分、刷新周期、有效期、等级、可购性 | `system_config.plan_configs` | 管理端 PlansView | 发放侧 |
| **价格 Price** | 每套餐×账期×币种×渠道卖多少钱 | `billing_prices`(不可变版本) | 管理端 价格页(原 catalog 降级为纯价格) | 售价侧 |
| **计费 Meter** | 每次调用扣多少积分(**按业务节点单一稳定价**) | `credit_pricing_rules` | 管理端 计费页 | 消耗侧 |

配套:**成本/毛利仅内部监控**(只读看板),不参与用户扣费、不做保存拦截。

## 三、关键设计决策

### D1 套餐配置单一入口(消除双写)
- **plan_configs 是套餐定义(积分/刷新/有效期/等级/可购性)的唯一真源,只由 PlansView 编辑。**
- **catalog 域不再建模/投影套餐积分与有效期**:`billing_plans` 的 entitlements 字段废弃;发布投影只生成 `payment_billing_config` 的商品与价格,**不再覆盖 plan_configs**。BillingCatalogView 降级为"价格管理页",套餐积分只读展示(来自 plan_configs)。
- **DEFAULT_PLAN_CONFIGS + 清洗逻辑合并为一份**(后端为准,管理端/支付端复用或通过接口取,消除三副本漂移)。

### D2 免费/试用套餐语义清晰化(已定)
- **两个正交维度必须解耦,所有页面一致展示且各自可编辑**:
  - `有效期 validity`(套餐何时结束):forever / N天 / 按账期。
  - `积分刷新周期 reset_period`(有效期内积分多久重置一次):**每套餐可任意指定(week/month/…),仅影响积分刷新,绝不影响有效期**。
- **free = 永久有效 + 可配置刷新周期,是所有套餐到期后的唯一默认兜底,自身永不过期**(现有行为正确,修 UI 文案一致)。free 的 reset_period 保持可配(当前 week,运营可随时改 month)。
- **trial = 限时 N 天一次性额度**;修掉 reset=month 的矛盾:trial 的 reset_period 语义应为"有效期内不再周期重置"(置为与有效期一致或标记 none),避免"重置永不触发"的误导。
- 管理端:validity 与 reset_period 两个字段**分列、都可编辑、文案分明**;客户端展示区分"有效期"与"积分刷新"。

### D3 计费回归"按业务节点单一稳定价"(消除 per-provider 两套计费)
- **credit_pricing_rules 以业务节点为主键,每节点一个稳定 credits**:asr_transcribe=100/min、asr_realtime=100/min、llm_*=40/1k、intent=20/1k、web_search=X/req。**同一节点无论后台走哪个 provider,用户扣费一致。**
- **删除 is_fallback、per-provider 差异 credits**。provider 成本差异是平台内部消化。
- 保留 pricing rule 的"节点+(可选)provider"匹配能力用于灰度/特例,但**默认每节点单价**,不制造用户可感知的两套标准。

### D4 成本/毛利降级为内部只读监控
- **删除 75% 地板保存拦截 / force / calibration 反算**(线上强治理)。
- 保留一个**只读毛利监控**:给定各节点单价 + 各 provider 参考成本 → 展示每 provider 毛利率(顾问性,红绿提示),**不阻断任何配置、不影响用户扣费**。
- 上游成本作为**参考成本表**(provider→cost),仅供监控视图;≥75% 作为**设计期人工核对**目标,而非运行时系统。

### D5 计费异步化(不阻塞 ASR)
- **预扣(防超支)保留在链路内但精简**:合并 ASR+LLM 多次预扣为一次、余额检查走缓存,减少锁往返。
- **最终结算 + 账本写入移出响应路径**:识别结果先返回,`_charge_uncovered_credits` 差额补扣与 `credit_ledger` 写入用后台任务异步完成(预扣已兜住余额,不会超支)。
- **计费规则加缓存**(TTL),消除单请求 4 次 `system_config` 无缓存读与重复读。
- 账本写入补 `idempotency_key`(现路径未传,幂等保护失效)。

### D6 统一架构与清理
- 三个管理页职责重划:PlansView=套餐定义(唯一)、价格页=价格、计费页=节点单价+只读毛利监控。删除 catalog 对套餐积分的编辑与投影。
- 收敛重复:DEFAULT 常量、清洗逻辑、计费规则读取缓存。

## 四、不做(避免再次过度设计)
- 不做 75% 线上强拦截、不做校准反算、不做 is_fallback 两套计费。
- 不按套餐差异化单节点积分、不做用量阶梯。
- 不保留 billing_plans 对套餐积分/有效期的重复建模。

## 附:阶段A 数据模型与 API 契约(计费单价 + 只读毛利监控)

### 数据模型(system_config)
- **credit_pricing_rules**(计费,按业务节点单一价,与 provider 无关):
  ```
  { node_id, category, unit(minute|1k_tokens|request), credits, enabled }   # 每节点一条,provider 无关
  ```
  匹配:仅按 node_id(+unit)。同一节点无论后台走哪个 provider,用户扣费一致。默认节点:
  asr_transcribe=100/min、asr_realtime_transcribe=100/min、llm_transcribe/llm_rewrite/openclaw_transcribe/android_quick_action=40/1k_tokens、intent_router=20/1k_tokens、web_search=按次(见下)。
  注:web_search 现按 provider(qwen/tavily)不同,可保留 provider 维度作为**特例**(搜索是整包外部服务、成本差异大且用户可感知"联网搜索"这一动作),但 ASR/LLM 一律单节点价。
- **credit_provider_costs**(新增,上游参考成本,仅供毛利监控,不参与扣费):
  ```
  { node_id, provider_id, platform_code?, model?, unit, upstream_cost_cny, cost_source, updated_at }
  ```
  每节点可多条(一条一个 provider)。默认:asr qwen/火山按量 0.0088~0.0132、whisper/groq 0.043/0.0134、llm qwen 0.002、search qwen 0.004 / tavily 0.058。
- **credit_pricing_policy**(简化,阈值仅用于监控着色,不做拦截):
  ```
  { image_surcharge_credits(默认15), margin_target_ratio(默认0.75,监控参考), margin_alert_ratio(默认0.30) }
  ```

### API(内部 HMAC verify_internal_api_key)
- `GET /config/billing-rules` → `{ rules:[节点单价...], policy:{...} }`
- `POST /config/billing-rules` `{rules, policy?}` → `{saved:true}`;**只校验字段合法性,不做毛利地板拦截、无 force**。
- `GET /config/billing-provider-costs` / `POST /config/billing-provider-costs` `{costs:[...]}` → 成本表 CRUD。
- `GET /config/billing-margin-report` → **只读监控**:`{ nodes:[{node_id, unit, credits, providers:[{provider_id, upstream_cost_cny, margin, status(green|yellow|red)}]}], global_min_credit_sale_price, policy }`。margin=1−cost/(credits×全局最低每积分售价),status 按 policy 阈值着色。**顾问性,不阻断任何操作。**
- **删除** `POST /config/billing-calibrate`(反算)与保存时的 floor 拦截(过度治理)。

### 管理端 BillingMarginView → 只读毛利监控 + 节点单价编辑 + 成本表编辑
- 节点单价:简单表格编辑 credits(每节点一行),保存不拦截。
- 成本表:provider→成本 编辑(供监控)。
- 毛利监控:每节点×每 provider 毛利率红绿灯(只读),顶部全局最低每积分售价。无"强制保存/违规拦截/校准"。

## 五、影响面与验证
- 后端:plan_repository(合并 DEFAULT/清洗)、credit_pricing_rules(节点单价、去 fallback)、pipeline(异步化结算+账本、规则缓存、合并预扣)、margin_engine(降级为只读监控或移除强校验)、config API(去 floor 拦截)。
- 支付端:billing_catalog 投影不再写 plan_configs(只写 payment_billing_config 价格段)。
- 管理端:PlansView 文案一致化、BillingCatalogView 降级为价格页、BillingMarginView 降级为只读监控。
- 验证:uat mock 用户跑 ASR/LLM 扣费(确认单价稳定、异步不阻塞、余额正确)、套餐到期→free 兜底、周期刷新;单测覆盖节点单价匹配与异步结算幂等。
