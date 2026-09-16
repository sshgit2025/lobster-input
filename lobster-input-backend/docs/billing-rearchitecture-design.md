# 计费域重构设计(Billing Re-architecture)

> 2026-07-12 立项。目标:在保证现有业务闭环(含补差价升级,见 `subscription-upgrade-proration.md`)的前提下,
> 提升计费栈的抽象度、可配置性与标准化程度,降低配置变更的影响面。
> 本文档基于对 Stripe / Kill Bill / Chargebee / Recurly / Lago / Paddle / RevenueCat 的调研
> (来源清单见文末),按本项目规模(单产品线、5 套餐 × 3 账期、creem/zpay/Apple 三渠道)裁剪。

## 一、现状痛点

1. 五层职责(卖什么/订了什么/能用什么/钱的凭证/扣款尝试)揉在 `system_config` + `users` + 一堆 ad-hoc 集合里。
2. 改价改配置直接原地修改,影响面不可控,无版本化、无 grandfathering。
3. 升降级/补差价规则在 backend 与 payment 两个服务重复实现,易漂移。
4. 权益由 payment 服务、Apple handler 各自直写 `users`,存在竞态与口径漂移风险。
5. 账务记录分散(payment_orders / payment_callback_events / subscription_purchase_events / refund events),无统一台账纪律。
6. 管理端部分配置是原始 JSON 表单;payment_runtime_config 无管理页;订单页缺新字段展示。

## 二、核心设计原则(采纳的行业不变量)

1. **五层分离**:CATALOG / SUBSCRIPTION / ENTITLEMENT / INVOICE-LEDGER / PAYMENT。
2. **价格不可变**:改价 = 新建 price 记录 + 归档旧记录;存量订阅永远引用售出时价格(grandfathering 默认)。
3. **稳定别名 lookup_key**:客户端/营销位按 `pro_yearly` 取"当前在售价",与价格版本解耦。
4. **变更规则硬编码且单点**(学 Lago):升级(rank↑或同套餐周期↑)立即生效+补差价;降级/缩周期 = `scheduled_change` 期末生效可撤销;取消默认期末;退款永远显式。规则只存在于 billing 服务一个模块。
5. **Entitlement projector 唯一写者**:`users` 权益字段降级为投影,由 projector 从 subscriptions + credit_grants 幂等重算终态(从事实重算,不做增量加减)。
6. **Webhook 幂等摄取**:验签 → 原始事件落库(`(provider, event_id)` 唯一索引)→ 先 200 → 异步处理;事件只当触发器,权威状态回查。
7. **台账纪律**:orders/transactions 只增不改;退款是新 REFUND 行;对账差异落 anomaly 表。
8. **展示与计费分离**:营销文案/排序挂 plan(随时可改);金额/币种/周期挂不可变 price。

## 三、目标领域模型(MongoDB)

```
billing_plans   { plan_code(PK), rank, name, display{}, entitlements{credits_per_period},
                  status: active|hidden|retired }

billing_prices  # 不可变;被引用后 amount/currency/period/channel_bindings 禁改
                { price_id(PK), plan_code, period, currency, amount_cents,
                  lookup_key(唯一指向在售版), sellable, version, effective_from,
                  channel_bindings{ creem{mode,external_product_id}, zpay{mode}, apple{apple_product_id} } }

subscriptions   { _id, user_id, plan_code, price_id, source: web|apple,
                  status: active|past_due|canceled|expired,
                  current_period_start/end, cancel_at_period_end,
                  scheduled_change{action, target_price_id, effective_at} | null,
                  apple{original_transaction_id(唯一), auto_renew_status} | null }

orders          # payment_orders 演进,兼任轻量 invoice
                { order_id, user_id, type: new|upgrade|renewal|topup,
                  price_snapshot{}, proration{old_price_id, credit_amount, charge_amount} | null,
                  status, channel, provider_ref, paid_at }

payment_transactions { txn_id, order_id, type: PURCHASE|REFUND, provider, provider_ref,
                  status: PROCESSED|PENDING|ERROR|CANCELED|UNKNOWN, amount, raw_snapshot }  # append-only

webhook_events  { provider, event_id, UNIQUE(provider,event_id), raw, signature_ok,
                  status: received|processing|done|failed }

reconciliation_anomalies { source, kind, local_ref, remote_ref, detail, resolved }
```

`users` 权益字段(subscription_plan_code/expires_at/credits 等)**原样保留**,唯一写者改为 projector。
`credit_grants` 保留,补 source_ref,加"余额=明细之和"校验 job。

**明确放弃**(对本规模是过度设计):Kill Bill 式 catalog XML/Phase 体系、完整复式记账、发票 PDF/税务、
usage metering、多 phase schedule、动态网关路由引擎(静态 `route(method, currency, platform)` 函数即可)、
Stripe Feature 粒度 entitlement。

## 四、管理端最小页面集(6 页)

1. 套餐列表+详情:price point 矩阵(period × currency),Active/Archived 过滤,渠道绑定状态。
2. 改价向导:强制"新建 price → 归档旧价 → lookup_key 转移"三步,明示"不影响存量订阅"。
3. 渠道绑定页:price × channel 配置 + apple_product_id 映射。
4. 用户订阅详情(客服中枢):订阅时间线、scheduled_change 可视化与撤销、手动延期/补偿/退款,变更前显示应收/应退预览。
5. 订单与交易流水:含 list_price/upgrade_credit/change_mode 展示、退款入口。
6. Webhook 事件浏览器 + 对账异常:原始 payload、处理状态、手动 replay。

注意:管理端 Vue SPA 与 Jinja 旧模板双轨,改动需同步两处(或借此机会下线对应 Jinja 页)。

## 五、迁移路径(分阶段、可回滚、老客户端零感知)

- **阶段 0(✅ 2026-07-12 已落地)**:`webhook_events` 幂等摄取(creem/zpay/apple 三入口,验签失败也留痕,
  failed 事件可管理端 replay);admin API:`GET/POST /api/v1/payments/admin/webhook-events*`。
  实现:payment `app/services/webhook_ingest.py` + `app/api/v1/webhook_admin.py`。
- **阶段 1(✅ 2026-07-12 已落地)**:billing_plans/billing_prices 目录域(价格不可变+lookup_key+版本化),
  改价=新建版本+归档旧价+lookup_key 转移;**发布投影**(物化写回 system_config.plan_configs 与
  payment_billing_config,两服务读路径零改动,dry-run diff+发布审计 catalog_publish_log);
  迁移脚本 `scripts/migrate_catalog_v1.py`(幂等,迁移后 dry-run 零 diff 验证往返一致;
  legacy billing_options 与价格派生条目合并,存量账期语义不丢失;无渠道价组合不生成 0 元价)。
  admin API:`/api/v1/payments/admin/catalog/*`(plans/prices/publish/publish-log)。
  实现:payment `app/services/billing_catalog.py` + `app/api/v1/catalog_admin.py`。
- **同期落地**:自动续费分渠道策略(见 `auto-renewal-strategy.md`:zpay 强制 auto_renew=false、
  Creem customer portal 入口);收银台取消按地区二选一,全部支付方式同时展示(地区仅影响排序)。
- **阶段 2(subscriptions + projector)**:回填 subscriptions;projector 先 shadow write(与 users 现值比对告警),
  稳定后切唯一写者,payment/Apple handler 停止直写 users。
- **阶段 3(规则收敛)**:升降级/proration 收敛到 billing 服务单模块,backend 改内部 API 调用;
  Apple 通知归一为 domain event;上线 Apple 每日对账 + anomaly 表。
- **阶段 4(清理)**:旧集合转只读归档;管理端 raw JSON 表单下线;补对账 job。

## 六、落地前待补功课

- 核对 Creem 与 ZPay webhook 文档:唯一 event id、重试策略、查单接口;若无 event id,用合成键并强制依赖查单。
- Apple V2 通知重试节奏(约 5 次/1-12-24-48-72h)建议沙盒实测;配 Get All Subscription Statuses 每日对账。

## 来源(调研主线)

Stripe docs(products-prices/prorations/upgrade-downgrade/webhooks/entitlements/customer balance)、
Kill Bill docs+blog(entitlement 分离/invoice diff 引擎/payment 插件接口/catalog versioning)、
Chargebee PC2.0(price point 矩阵/改价只影响新订阅)、Recurly(credit invoice/change timeframe)、
Lago(升级立即降级期末硬编码)、Paddle(scheduled_change 一等对象)、RevenueCat(entitlement 投影/多商店合并)、
Apple App Store Server Notifications V2、Airbnb/Shopify/Modern Treasury 工程实践。
