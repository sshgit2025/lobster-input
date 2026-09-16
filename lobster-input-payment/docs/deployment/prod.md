# 支付服务部署说明 - prod

本文是 `lobster-input-payment` 的生产环境部署模板，流程与 uat 保持一致。prod 的 IP、域名、数据库和中间件连接暂不填写。

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-payment` |
| 服务器目录 | `/opt/lobster-payment/` |
| systemd 服务 | `lobster-payment` |
| 监听端口 | `8890` |
| 外部路径 | `/lobster/payment` |
| prod 支付中转域名 | `https://<PROD_PAYMENT_DOMAIN>/lobster` |

支付服务是支付领域配置的唯一写入方。管理端通过内网接口代理支付服务，后端通过内网接口读取支付目录并创建 checkout。

## .env 关键项

```env
MONGODB_URI=<PROD_MONGODB_URI>
MONGODB_DB_NAME=voice_input
PAYMENT_CALLBACK_INTERNAL_KEY=<prod 支付服务内部接口鉴权密钥>
BASE_URL=/lobster/payment
COOKIE_SECURE=true
EXPOSE_API_DOCS=false
PORT=8890
HOST=0.0.0.0
PUBLIC_BASE_URL=https://<PROD_MAIN_DOMAIN>/lobster/payment
```

Creem prod 回调路径模板：

```text
Webhook URL: https://<PROD_API_DOMAIN>/lobster/payment/api/v1/payments/webhook/creem
Return URL:  https://<PROD_MAIN_DOMAIN>/lobster/payment/api/v1/payments/creem/return
```

## 同步代码

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@<GATEWAY_PUBLIC_IP>"
SSH_OPT="-o StrictHostKeyChecking=yes"

rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='.venv' --exclude='venv' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-payment/" "$GATEWAY_HOST:/opt/prod/lobster-payment/"
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
curl -s https://<PROD_MAIN_DOMAIN>/lobster/payment/health
tail -100 /var/log/lobster-payment.log
```
