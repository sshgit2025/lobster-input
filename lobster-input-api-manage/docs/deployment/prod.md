# 号池管理平台部署说明 - prod

本文是 `lobster-input-api-manage` 的生产环境部署模板（前后端分离），流程与 uat 保持一致。

## 拓扑（重要）

与 uat/preview 一致,prod 也是**两层结构**:`<GATEWAY_PUBLIC_IP>`(Nginx 入口网关,仅转发,不跑 node/前端)→ prod 业务服务器(真正运行后端 8889、前端 systemd `lobster-api-pool-frontend` 7889、Node、dist)。`/opt/prod/lobster-api-pool/frontend` 在网关上仅作同步中转。完整发布路径(本地 → 网关 → 业务服务器 → 在业务服务器构建并重启)以 `lobster-input-backend/docs/operations/server-deploy-prod.md` 为准。

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-api-manage` |
| 服务器目录 | `/opt/lobster-api-pool/` |
| 后端 systemd | `lobster-api-pool` |
| 前端 systemd | `lobster-api-pool-frontend` |
| 后端端口 | `8889` |
| 前端端口 | `7889` |
| 外部管理路径 | `/lobster/api-pool` |
| prod 地址 | `https://<PROD_MAIN_DOMAIN>/lobster/api-pool/` |

## 目录结构

```text
/opt/lobster-api-pool/
├── backend/
└── frontend/
```

## .env 关键项（backend/.env）

```env
MONGODB_URI=<PROD_MONGODB_URI>
MONGODB_DB_NAME=lobster_api_pool
INTERNAL_API_KEY=<与 prod 后端 API_POOL_INTERNAL_KEY 一致>
INTERNAL_SIGNATURE_TOLERANCE_SEC=300
COOKIE_SECURE=true
EXPOSE_API_DOCS=false
PORT=8889
HOST=0.0.0.0
BASE_URL=/lobster/api-pool
```

## 同步代码

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@<GATEWAY_PUBLIC_IP>"
SSH_OPT="-o StrictHostKeyChecking=yes"

rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='.venv' --exclude='venv' \
  --exclude='frontend/node_modules' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-api-manage/" "$GATEWAY_HOST:/opt/prod/lobster-api-pool/"
```

## 首次部署

```bash
cd /opt/lobster-api-pool/backend
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

cd /opt/lobster-api-pool/frontend
npm install
npm run build
```

## systemd - 后端

```ini
[Unit]
Description=Lobster API Pool Manager API
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-api-pool/backend
EnvironmentFile=/opt/lobster-api-pool/backend/.env
ExecStart=/opt/lobster-api-pool/backend/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8889 --workers 1
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-api-pool.log
StandardError=append:/var/log/lobster-api-pool.log

[Install]
WantedBy=multi-user.target
```

## systemd - 前端

```ini
[Unit]
Description=Lobster API Pool Frontend SPA
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-api-pool/frontend
ExecStart=/usr/bin/npm run preview
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-api-pool-frontend.log
StandardError=append:/var/log/lobster-api-pool-frontend.log

[Install]
WantedBy=multi-user.target
```

## Nginx

详见 `lobster-input-backend/docs/operations/gateway-nginx-prod.md`。

## 发布后验证

```bash
curl -s http://127.0.0.1:8889/health
curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:7889/lobster/api-pool/
curl -s https://<PROD_MAIN_DOMAIN>/lobster/api-pool/health
curl -sL -o /dev/null -w '%{http_code}' https://<PROD_MAIN_DOMAIN>/lobster/api-pool/login
```
