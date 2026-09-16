# 后端部署说明 - prod

本文是 `lobster-input-backend` 的生产环境部署模板，流程与 uat 保持一致。当前 prod 服务器尚未落地，IP、域名、数据库地址、私网地址和中间件连接均使用占位符。

服务器整体发布顺序、共享网关和全服务一键发布见 `docs/operations/server-deploy-prod.md`。

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-backend` |
| 本地同步源 | `lobster-input-backend/backend/` |
| 服务器目录 | `/opt/lobster-backend/` |
| systemd 服务 | `lobster-backend` |
| 监听端口 | `8000` |
| 健康检查 | `/health` |
| prod API 域名 | `<PROD_API_DOMAIN>` |
| prod 网关入口 | 与 uat、preview 共享网关服务器，使用独立 prod 域名配置 |

## .env 关键项

```env
APP_ENV=production
MONGODB_URI=<PROD_MONGODB_URI>
REDIS_URL=<PROD_REDIS_URL>

API_POOL_URL=http://127.0.0.1:8889
API_POOL_INTERNAL_KEY=<与 prod 号池 INTERNAL_API_KEY 一致>
ADMIN_CONFIG_URL=http://127.0.0.1:8888
ADMIN_CONFIG_INTERNAL_KEY=<与 prod 管理端 PROVIDER_CONFIG_INTERNAL_KEY 一致>
PROVIDER_CONFIG_CACHE_TTL_SEC=600
INTERNAL_SIGNATURE_TOLERANCE_SEC=300

PAYMENT_SERVICE_URL=http://127.0.0.1:8890
PAYMENT_CALLBACK_INTERNAL_KEY=<与 prod 支付服务一致>
PAYMENT_CHECKOUT_PUBLIC_BASE_URL=https://<PROD_PAYMENT_DOMAIN>/lobster

TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128,<PROD_GATEWAY_CIDR>
ASR_CORRECTION_ENABLED=true
QDRANT_HOST=127.0.0.1
QDRANT_PORT=6333
QDRANT_GRPC_PORT=6334
QDRANT_PREFER_GRPC=true
QDRANT_SEARCH_HNSW_EF=16
```

## 同步代码

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@<GATEWAY_PUBLIC_IP>"
SSH_OPT="-o StrictHostKeyChecking=yes"

rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='uploads/' --exclude='.venv' --exclude='venv' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-backend/backend/" "$GATEWAY_HOST:/opt/prod/lobster-backend/"
```

如果 prod 业务服务与 uat/preview 一样使用网关中转，再由网关同步到 prod 业务服务器，目标目录仍为 prod 业务服务器的 `/opt/lobster-backend/`。

## 首次部署

```bash
cd /opt/lobster-backend
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

## systemd

`/etc/systemd/system/lobster-backend.service`：

```ini
[Unit]
Description=Lobster Input Backend
After=network.target mongod.service docker.service
Wants=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-backend
EnvironmentFile=/opt/lobster-backend/.env
ExecStart=/opt/lobster-backend/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-backend.log
StandardError=append:/var/log/lobster-backend.log

[Install]
WantedBy=multi-user.target
```

## 发布后验证

```bash
curl -s http://127.0.0.1:8000/health
curl -s https://<PROD_API_DOMAIN>/lobster/health
tail -100 /var/log/lobster-backend.log
```

```bash
cd /opt/lobster-backend
PYTHONPATH=/opt/lobster-backend \
  /opt/lobster-backend/venv/bin/python3.12 scripts/init_system_config.py
```
