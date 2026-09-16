# 支付服务部署说明 - uat

本文只描述 `lobster-input-payment` 支付服务在 uat（公测环境，原文档中的 "preview"）的部署。uat 业务服务器（192.0.2.14）为长期实例。服务器整体发布顺序和网关配置见 `lobster-input-backend/docs/operations/server-deploy-uat.md`。preview（内测环境）版本见本目录 `preview.md`。

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-payment` |
| 服务器目录 | `/opt/lobster-payment/` |
| systemd 服务 | `lobster-payment` |
| 监听端口 | `8890` |
| 外部路径 | `/lobster/payment` |
| uat 支付中转域名 | `https://payment.example.com/lobster` |

支付渠道 API Key、Webhook Secret、支付方式、商品、价格、商品渠道绑定、优惠券码不写入 `.env`，统一由支付服务数据库配置表保存，并通过管理端“支付中心”维护。

## .env 关键项

```env
MONGODB_URI=mongodb://YOUR_DB_USER:YOUR_DB_PASSWORD@localhost:27017/?authSource=admin
MONGODB_DB_NAME=voice_input
PAYMENT_CALLBACK_INTERNAL_KEY=<支付服务内部接口鉴权密钥，必须与后端和管理端一致>
BASE_URL=/lobster/payment
COOKIE_SECURE=true
EXPOSE_API_DOCS=false
PORT=8890
HOST=0.0.0.0
PUBLIC_BASE_URL=https://example.com/lobster/payment
```

Creem uat 当前回调路径：

```text
Webhook URL: https://api.example.com/lobster/payment/api/v1/payments/webhook/creem
Return URL:  https://example.com/lobster/payment/api/v1/payments/creem/return
```

## 同步代码

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@192.0.2.13"
SSH_OPT="-o StrictHostKeyChecking=yes"

rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='.venv' --exclude='venv' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-payment/" "$GATEWAY_HOST:/opt/lobster-payment/"
```

## 首次部署

```bash
cd /opt/lobster-payment
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

## systemd

`/etc/systemd/system/lobster-payment.service`：

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
curl -s http://127.0.0.1:8890/health
curl -s https://example.com/lobster/payment/health
tail -100 /var/log/lobster-payment.log
```

初始化或刷新支付配置时使用本仓库脚本：

```bash
cd /opt/lobster-payment
venv/bin/python scripts/init_billing_config.py
```
