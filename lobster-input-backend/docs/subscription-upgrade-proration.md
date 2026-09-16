# 套餐升级补差价(Proration)设计

> 2026-07-12 落地。解决"购买月付后无法升级同套餐年付"的设计缺陷,并规范降级拦截。

## 规则:套餐有效优先级

参考 Apple 订阅组 / Stripe Billing 的成熟设计,套餐的**有效优先级 = (等级 rank, 账期时长 months) 的字典序**,自助购买仅允许**严格向上**变更:

| 当前订阅 → 目标 | 判定 | 结算 |
|---|---|---|
| 无有效付费订阅 → 任意 | 放行 | 全价 `full_price` |
| 同套餐、更长账期(月→季/年) | 放行(`cycle_upgrade`) | **补差价 `prorated_difference`** |
| 同套餐、同账期 | 拒绝 `duplicate_purchase`(续费走自动续费) | — |
| 同套餐、更短账期(年→月) | 拒绝 `cycle_downgrade` | — |
| 更高等级、账期不缩短 | 放行(`activate_now`) | **补差价 `prorated_difference`** |
| 更高等级、账期缩短(年付→高级月付) | 拒绝 `cycle_downgrade` | — |
| 更低等级(含高级月付→低级年付) | 拒绝 `lower_tier` | — |

补差价金额 = 目标目录价 − 当前套餐未使用价值(按剩余时间比例折算),下限 1 分。

抵扣基准优先取**上一笔订单同币种实付金额**(扣除已退款),否则取当前套餐在同支付方式下的目录价;权益窗口取上一笔结算事件的 entitlement 起止。无法可靠计算(如管理员手工授予、无支付事件)时**回退全价模式**(维持原全价购买 + 未用部分退款台账行为)。

仅支持动态金额下单的渠道(`amount_order`,如 ZPay 微信/支付宝)可补差;外部固定价商品渠道(`external_product`,如 Creem)回退全价模式。

Apple IAP 不走此逻辑:同一订阅组内的升降级由苹果原生按比例折算,结算回调 `_resolve_change_mode` 保持宽松(仅拦截跨级降级),避免误伤苹果已扣款交易。

## 实现位置

### lobster-input-payment(权威)
- `app/api/v1/payments.py`
  - `_checkout_block_reason` / `_reject_duplicate_or_downgrade_checkout`:购买闸门(上表)。
  - `_upgrade_credit_cents` / `_resolve_checkout_pricing`:补差定价(服务端权威,忽略客户端传入 settlement_mode)。
  - `create_subscription_checkout`:应付金额=补差价;订单落 `list_price_cents`/`upgrade_credit_cents`/`change_mode`。
  - `POST /api/v1/payments/quote/subscription-options`:批量报价(后端 catalog/收银台展示用)。
  - 结算回调 `prorated_difference` 路径为既有逻辑:全新授予权益、不再退旧套餐差额。

### lobster-input-backend
- `backend/app/api/v1/payments.py`
  - 同构闸门 `_checkout_block_reason`(与支付端一致,双重校验)。
  - `create_subscription_checkout`:向支付端拉取报价定 intent 展示价与结算模式。
  - `GET /api/v1/payments/catalog` 新增:`current_plan.billing_cycle`;每个 billing_option 新增 `payable_price_cents` / `settlement_mode` / `upgrade_credit_cents` / `purchasable` / `blocked_reason`(响应时计算,不落库)。
  - 收银台 intent 页展示"补差价升级:原价 X,已抵扣 Y"(六语言)。

### 客户端(Mac/安卓/鸿蒙/Win 对称;iOS 零改动)
- 判定从"套餐级"改为"选项级":以服务端 `purchasable`/`blocked_reason` 为准;`purchasable` 缺失时回退旧套餐级逻辑(兼容旧后端)。
- 价格展示 `payable_price_cents ?? price_cents`;补差价选项按钮文案"补差价升级"+ 小字"已抵扣未使用部分"。
- 购买请求体不变(服务端权威决定结算方式,存量老客户端天然兼容:老客户端同套餐卡片仍显示"当前套餐"不可点,不受影响)。

## 测试
- 支付端:`tests/test_payment_rules.py`(33,含 7 个升级规则新测试)。
- 后端:`backend/tests/test_payments_checkout_gate.py`(9)。

## 已知边界
- 跨平台重复扣费:iOS 苹果自动续订与网页升级并存时,苹果侧订阅不会自动取消(现状已存在,阶段二计费重构处理)。
- 管理端订单页暂未展示 `list_price_cents`/`upgrade_credit_cents`/`change_mode`(仅展示缺口,阶段二补)。
