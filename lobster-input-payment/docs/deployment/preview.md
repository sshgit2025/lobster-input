# 支付服务部署说明 - preview

本文只描述 `lobster-input-payment` 支付服务在 preview（内测环境，2026-07 新建）的部署。服务器整体发布顺序、网关配置与从零重建 runbook 见 `lobster-input-backend/docs/operations/server-deploy-preview.md`。uat（公测环境）版本见本目录 `uat.md`。

> **preview 业务服务器是抢占式实例，随时可能被释放回收。** IP 只在下表集中定义；实例更换后替换本表与命令变量即可,并同步更换网关 `.cn` vhost 的 `proxy_pass` 私网 IP。

## 拓扑（当前值）

| 角色 | 当前值 |
|---|---|
| 网关服务器（三环境共享） | `192.0.2.13` |
| preview 业务服务器公网 IP | `192.0.2.15` |
| preview 业务服务器私网 IP | `192.0.2.12` |
| preview 支付域名 | `payment.example.net` |

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-payment` |
| 服务器目录 | `/opt/lobster-payment/` |
| systemd 服务 | `lobster-payment` |
| 监听端口 | `8890` |
| 外部路径 | `/lobster/payment` |
| preview 支付中转域名 | `https://payment.example.net/lobster` |

支付渠道 API Key、Webhook Secret、支付方式、商品、价格、商品渠道绑定、优惠券码不写入 `.env`，统一由支付服务数据库配置表保存（`system_config.payment_billing_config`），并通过管理端"支付中心"维护（preview 的管理端地址：`https://example.net/lobster/admin/`）。

> **当前渠道密钥来源**：各环境当前均使用**沙盒密钥**，preview 的渠道账户配置（含 merchant_id / api_key / webhook_secret）直接从 uat 的 `system_config` 整集合同步而来（`preview-server-bootstrap.sh` 第 7 步一并同步，无需在 preview 管理端重新录入）。uat 将来接入生产支付时会在 uat 管理端手动改这些配置，preview 保持沙盒不动。同步后 bootstrap 会自动把 `payment_runtime_config.checkout_public_base_url` 从 .com 改写为 .cn。

## .env 关键项

`.env` 里只有服务运行参数与内部鉴权密钥;支付渠道账户密钥在 `system_config.payment_billing_config`(沙盒,从 uat 同步)。当前各环境均为沙盒密钥,`.env` 直接对齐 uat(仅 `PUBLIC_BASE_URL` 改 .cn),含 uat 中保留的 Creem 配置注释项。

```env
MONGODB_URI=mongodb://YOUR_DB_USER:YOUR_DB_PASSWORD@localhost:27017/?authSource=admin
MONGODB_DB_NAME=voice_input
PAYMENT_CALLBACK_INTERNAL_KEY=<支付服务内部接口鉴权密钥，必须与后端和管理端一致>
BASE_URL=/lobster/payment
COOKIE_SECURE=true
EXPOSE_API_DOCS=false
PORT=8890
HOST=0.0.0.0
PUBLIC_BASE_URL=https://example.net/lobster/payment
```

## 支付渠道回调（preview 用 .cn 域名）

Creem preview 回调路径：

```text
Webhook URL: https://api.example.net/lobster/payment/api/v1/payments/webhook/creem
Return URL:  https://example.net/lobster/payment/api/v1/payments/creem/return
```

ZPay preview 回调路径（动态金额渠道，notify/return 由下单参数携带）：

```text
notify_url: https://example.net/lobster/payment/api/v1/payments/webhook/zpay
return_url: https://example.net/lobster/payment/api/v1/payments/zpay/return
```

> **下单链路可用**：preview 与 uat 共用同一套沙盒渠道账户密钥,下单、生成 checkout 意图、`.cn` 支付中转页均正常(已实测)。
>
> **已知限制（Webhook 回调）**：支付渠道（Creem/ZPay）后台的 Webhook 地址是**账号级全局单值**,当前登记的是 uat 的 `.com` 地址。因此 preview 发起的支付,其异步回调仍会送达 uat,不会回到 `.cn`。这是沙盒渠道账号共用带来的固有限制,不影响 preview 的下单/中转页验证;涉及回调的对账、订阅激活、退款闭环仍需在 uat 观察。若将来要让 preview 回调独立,需在渠道后台为 preview 单独登记 `.cn` Webhook/Return URL（独立商户号/应用,或渠道支持多 webhook 时追加一条）。

## 同步代码

preview 走网关 `/opt/preview/` 前缀中转（与 uat 的 `/opt/lobster-payment/` 中转目录隔离），再由网关同步到 preview 业务服务器的 `/opt/lobster-payment/`。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@192.0.2.13"
PREVIEW_IP="192.0.2.15"   # 实例被释放后只改这里
SSH_OPT="-o StrictHostKeyChecking=yes"

rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='.venv' --exclude='venv' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-payment/" "$GATEWAY_HOST:/opt/preview/lobster-payment/"

ssh $SSH_OPT "$GATEWAY_HOST" "
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' \
    /opt/preview/lobster-payment/ root@$PREVIEW_IP:/opt/lobster-payment/
"
```

## 首次部署 / 实例重建

抢占式实例被回收后按 `server-deploy-preview.md` 的从零重建 runbook 执行;支付端部分:

```bash
cd /opt/lobster-payment
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

## systemd

`/etc/systemd/system/lobster-payment.service`（与 uat 完全一致）：

```ini
[Unit]
Description=Lobster Payment Service
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

## 发布后验证

```bash
# 业务服务器本机
curl -s http://127.0.0.1:8890/health

# 公网（经网关 .cn vhost）
curl -s https://example.net/lobster/payment/health
curl -s https://payment.example.net/lobster/health
tail -100 /var/log/lobster-payment.log
```

初始化或刷新支付配置时使用本仓库脚本（重建后必跑，商品/价格/渠道基础配置）：

```bash
cd /opt/lobster-payment
venv/bin/python scripts/init_billing_config.py
```

渠道 Key、Webhook Secret 等敏感配置随 `system_config` 整集合从 uat 同步(当前均为沙盒密钥,见上文"当前渠道密钥来源")。如需 preview 使用独立密钥,再在管理端"支付中心"按 preview 覆盖录入即可。
