# Lobster Payment

`lobster-input-payment` 是 Lobster Input 的支付领域服务，负责支付配置、商品价格、渠道绑定、checkout 创建、支付平台回调、订单、退款和支付事件幂等。

架构边界：

- 客户端公开后端继续负责登录、配置读取、套餐余额读取和业务扣积分。
- 管理端负责套餐配置、rank 优先级、人工开通、支付中心页面和运营查询。支付中心通过内网接口调用支付服务，不直接写支付服务数据结构。
- 支付服务负责支付领域数据和外部支付平台调用。支付渠道 API Key、Webhook Secret、商品、价格、支付方式、渠道账号、商品渠道绑定、优惠券码都保存在支付服务数据库配置表中，不写入 `.env`。

支付服务写入集合包括：

- `payment_callback_events`
- `payment_orders`
- `payment_checkout_sessions`
- `payment_attempts`
- `payment_transactions`
- `payment_refunds`
- `users`
- `credit_grants`
- `subscription_refund_events`

## API

### 客户端支付闭环

客户端不直接调用 Creem，也不持有 Creem API Key：

1. 客户端通过后端 `GET /api/v1/payments/catalog` 获取订阅商品、加购商品和可用支付方式。
2. 客户端通过后端 `POST /api/v1/payments/subscription/checkout` 或 `POST /api/v1/payments/credits-topup/checkout` 发起支付。
3. 后端验证用户登录态后，使用内部签名转发到 payment 服务。
4. payment 服务读取数据库 `system_config.payment_billing_config`，按商品、支付方式和渠道绑定选择支付渠道账号，自动挂载对应 provider adapter。当前 Creem 适配器调用 `POST /v1/checkouts` 创建 checkout session，返回 `checkout_url`。
5. 客户端打开 `checkout_url`，用户在支付平台托管页完成支付。
6. 支付平台调用 `POST /api/v1/payments/webhook/{provider}`，payment 服务验签后写入订阅或加购积分。
7. provider return URL 只展示“支付处理中”，客户端应回到应用后刷新套餐信息；业务权益以 webhook 为准。

套餐与加购价格以支付服务的商品价格配置为准。外部支付平台有商品概念时，通过商品渠道绑定记录外部商品 ID；外部支付平台没有商品概念时，通过金额下单模式使用本地价格创建订单。支付配置使用 1 分钟本地进程缓存，切换平台或环境配置不要求秒级生效。后续新增支付平台时新增独立 adapter 和注册元数据，再由管理端支付中心维护该平台账号和商品绑定。

Creem Dashboard 需要配置：

- Webhook URL：`https://api.example.com/lobster/payment/api/v1/payments/webhook/creem`
- Product return URL：`https://example.com/lobster/payment/api/v1/payments/creem/return`
- API Key、Webhook Secret、API Base URL、商品渠道绑定、默认优惠券都在管理端“支付中心”页面配置。

数据库配置结构：

```json
{
  "key": "payment_billing_config",
  "value": {
    "products": [
      {
        "code": "standard_monthly",
        "type": "subscription",
        "name": "Standard monthly",
        "plan_code": "standard",
        "billing_cycle": "monthly",
        "enabled": true
      },
      {
        "code": "credits_topup",
        "type": "credits_topup",
        "name": "积分加购",
        "topup_credits": 10000,
        "enabled": true
      }
    ],
    "currencies": [
      {
        "code": "USD",
        "name": "美元",
        "symbol": "$",
        "rate_to_usd": 1,
        "rate_source": "fixed",
        "auto_update": false,
        "enabled": true
      },
      {
        "code": "CNY",
        "name": "人民币",
        "symbol": "¥",
        "rate_to_usd": 0.138,
        "rate_source": "manual",
        "auto_update": true,
        "enabled": true
      }
    ],
    "payment_methods": [
      {
        "code": "card",
        "name": "银行卡",
        "currencies": ["USD"],
        "channel_code": "creem",
        "enabled": true
      },
      {
        "code": "wechat",
        "name": "微信支付",
        "currencies": ["CNY"],
        "channel_code": "zpay",
        "enabled": true
      }
    ],
    "channels": [
      {
        "provider_code": "creem",
        "code": "creem",
        "name": "Creem",
        "enabled": true,
        "active_account_code": "creem_test",
        "accounts": [
          {
            "code": "creem_test",
            "name": "Creem Test",
            "environment": "test",
            "api_base_url": "https://test-api.creem.io",
            "api_key": "...",
            "webhook_secret": "...",
            "dashboard_url": "https://creem.io",
            "settlement_currency": "USD",
            "enabled": true
          }
        ]
      }
    ],
    "channel_prices": [
      {
        "product_code": "standard_monthly",
        "payment_method": "card",
        "channel_code": "creem",
        "account_code": "creem_test",
        "mode": "external_product",
        "external_product_id": "prod_xxx",
        "currency": "USD",
        "amount_cents": 990,
        "pricing_strategy": "fixed",
        "enabled": true
      },
      {
        "product_code": "standard_monthly",
        "payment_method": "wechat",
        "channel_code": "zpay",
        "account_code": "zpay_live",
        "mode": "amount_order",
        "currency": "CNY",
        "amount_cents": 7200,
        "pricing_strategy": "exchange_rate",
        "base_currency": "USD",
        "base_amount_cents": 990,
        "enabled": true
      }
    ],
    "exchange_rate_provider": {
      "provider": "tianapi",
      "api_key": "...",
      "base_currency": "USD",
      "refresh_hour": 3,
      "enabled": true
    }
  }
}
```

订阅商品不保存积分、有效期、rank、自助购买权限，这些都归 `plan_configs` 套餐模块维护。支付商品只负责“卖哪个套餐账期”；只有 `credits_topup` 这类加购商品保存 `topup_credits`，因为它本身就是单独售卖积分包。

所有回调接口都要求：

- Header `X-API-Key`
- Header `X-Callback-Timestamp`
- Header `X-Callback-Signature`

签名内容为：

```text
METHOD
PATH
QUERY
TIMESTAMP
BODY
```

使用部署侧配置的支付服务内部接口鉴权密钥做 HMAC-SHA256。该密钥只用于后端、管理端和支付服务之间的内网接口鉴权，不是支付渠道密钥。

### 订阅支付回调

`POST /api/v1/payments/callback/subscription`

支付成功后立即覆盖或续费订阅。套餐有效优先级 = (等级 `rank`, 账期时长) 字典序，仅允许严格向上变更：同套餐同账期为续费；同套餐更长账期(月→年)或更高等级为升级(可走 `settlement_mode=prorated_difference` 补差价)；同套餐更短账期(年→月)、跨级降级、低等级购买一律拒绝。详见后端 `docs/subscription-upgrade-proration.md`。Apple IAP 由苹果订阅组自行按比例折算，回调固定 `full_price` 记账并采信苹果到期时间。

### 积分加购回调

`POST /api/v1/payments/callback/credits-topup`

只允许当前有效付费套餐、且当前总可用积分为 0 的用户加购。加购批次跟随当前订阅到期。

### Provider Webhook

`POST /api/v1/payments/webhook/creem`

直接由支付平台调用。当前 Creem 适配器使用 `creem-signature` 头和激活配置的 `webhook_secret` 对原始 body 做 HMAC-SHA256 验签。

当前处理：

- `checkout.completed`：只用于单次积分加购发放。
- `subscription.paid`：用于订阅首次付款和后续自动续费。
- `subscription.scheduled_cancel` / `subscription.canceled`：关闭用户态自动续费，权益保留到当前周期结束。
- `subscription.past_due` / `subscription.expired`：同步订阅状态，实际降级仍由后端惰性生命周期闭环处理。

## Local Run

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
python run.py
```

## Deploy Notes

建议端口：`8890`

systemd 示例：

```ini
[Unit]
Description=Lobster Payment
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-payment
EnvironmentFile=/opt/lobster-payment/.env
ExecStart=/opt/lobster-payment/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8890 --workers 1
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-payment.log
StandardError=append:/var/log/lobster-payment.log

[Install]
WantedBy=multi-user.target
```
