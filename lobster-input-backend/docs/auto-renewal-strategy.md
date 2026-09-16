# 自动续费分渠道策略(zpay / Creem / Apple)

> 2026-07-12 调研并落地。结论:自动续费能力**完全由渠道决定**,采用业界通行的"双轨制"。

## 调研结论

| 渠道 | 自动续费 | 依据 |
|---|---|---|
| **Creem**(国际卡) | **平台托管**。用户绑卡后 Creem 按周期自动扣款,商户只消费 webhook(`subscription.paid` 续期记账、`subscription.past_due` 扣款失败、`subscription.scheduled_cancel/canceled/expired` 状态机)。扣款失败平台自动 dunning 重试 | docs.creem.io/code/webhooks |
| **ZPay**(微信/支付宝,易支付协议) | **无任何代扣能力**,仅单笔收款(submit.php/mapi.php)。微信委托代扣/支付宝周期扣款仅对企业商户开放且门槛极高,易支付系产品续费一律"到期提醒+手动再购" | z-pay.cn/doc.html;微信/支付宝商户文档 |
| **Apple IAP** | 平台托管(订阅组自动续订),App Store Server Notifications 驱动 | 现状已接 |

## 落地规则

1. **auto_renew 语义按渠道收敛**:
   - zpay 订单:checkout 创建时强制 `auto_renew=false`(用户勾选无效),订阅态不出现"自动续费开启"的误导。
   - creem/apple 订单:auto_renew 为真实状态;`subscription.scheduled_cancel`/`DID_CHANGE_RENEWAL_PREF` → false。
2. **管理入口**:
   - 新增后端 `POST /api/v1/payments/subscription/manage-portal`(登录态)→ 支付端 `POST /api/v1/payments/portal/subscription` → Creem `POST /v1/customers/billing` 换取 customer portal 链接(取消订阅/管理支付方式)。zpay/无托管订阅用户返回 400。
   - 取消自动续费保留当期权益应走 Creem cancel API 的 `scheduled` 模式(portal 内自助取消行为待 test mode 实测,见"待验证")。
3. **到期提醒(zpay 用户,后续迭代)**:到期前 7/3/1 天 + 到期日,站内 + 邮件双通道;到期后 1-3 天宽限期再降级。Creem 用户无需续费提醒,仅需 `past_due` 时提示更新支付方式。

## 待验证(Creem test mode)

- portal 内用户自助取消是"立即"还是"期末"生效(文档表述与 cancel API 的 scheduled 模式不一致)。
- external_product 模式下 upgrade/proration API 是否可用。

完整调研备忘录(含微信/支付宝代扣资质门槛、社区实践、来源清单)见任务记录;架构上下文见 `billing-rearchitecture-design.md`。
