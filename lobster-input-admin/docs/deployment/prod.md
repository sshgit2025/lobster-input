# 管理端部署说明 - prod

本文是 `lobster-input-admin` 的生产环境部署模板（前后端分离），流程与 uat 保持一致。

## 拓扑（重要）

与 uat/preview 一致,prod 也是**两层结构**:`<GATEWAY_PUBLIC_IP>`(Nginx 入口网关,仅转发,不跑 node/前端)→ prod 业务服务器(真正运行后端 8888、前端 systemd `lobster-admin-frontend` 7888、Node、dist)。`/opt/prod/lobster-admin/frontend` 在网关上仅作同步中转。完整发布路径(本地 → 网关 → 业务服务器 → 在业务服务器构建并重启)以 `lobster-input-backend/docs/operations/server-deploy-prod.md` 为准。

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-admin` |
| 服务器目录 | `/opt/lobster-admin/` |
| 后端 systemd | `lobster-admin` |
| 前端 systemd | `lobster-admin-frontend` |
| 后端端口 | `8888` |
| 前端端口 | `7888` |
| 外部路径 | `/lobster/admin` |
| prod 地址 | `https://<PROD_MAIN_DOMAIN>/lobster/admin/` |

## 目录结构

```text
/opt/lobster-admin/
├── backend/
└── frontend/
```

## .env 关键项（backend/.env）

```env
MONGODB_URI=<PROD_MONGODB_URI>
BASE_URL=/lobster/admin
BACKEND_URL=http://127.0.0.1:8000
BACKEND_API_KEY=<与 prod 后端 API_KEY 一致>
API_POOL_URL=http://127.0.0.1:8889
API_POOL_INTERNAL_KEY=<与 prod 号池 INTERNAL_API_KEY 一致>
PROVIDER_CONFIG_INTERNAL_KEY=<与 prod 后端 ADMIN_CONFIG_INTERNAL_KEY 一致>
PAYMENT_SERVICE_URL=http://127.0.0.1:8890
PAYMENT_CALLBACK_INTERNAL_KEY=<prod 支付服务内部接口鉴权密钥>
ALERT_INTERNAL_KEY=<prod 告警上报密钥>
COOKIE_SECURE=true
EXPOSE_API_DOCS=false
PORT=8888
HOST=0.0.0.0
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
  "$ROOT/lobster-input-admin/" "$GATEWAY_HOST:/opt/prod/lobster-admin/"
```

## 首次部署

```bash
cd /opt/lobster-admin/backend
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

cd /opt/lobster-admin/frontend
npm install
npm run build
```

## systemd - 后端

```ini
[Unit]
Description=Lobster Input Admin API
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-admin/backend
EnvironmentFile=/opt/lobster-admin/backend/.env
ExecStart=/opt/lobster-admin/backend/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8888 --workers 1
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-admin.log
StandardError=append:/var/log/lobster-admin.log

[Install]
WantedBy=multi-user.target
```

## systemd - 前端

```ini
[Unit]
Description=Lobster Admin Frontend SPA
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-admin/frontend
ExecStart=/usr/bin/npm run preview
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-admin-frontend.log
StandardError=append:/var/log/lobster-admin-frontend.log

[Install]
WantedBy=multi-user.target
```

## Nginx

详见 `lobster-input-backend/docs/operations/gateway-nginx-prod.md`：`/lobster/admin/api/` → 8888，其余 `/lobster/admin/` → 7888。

## 发布后验证

```bash
curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:8888/api/v1/alerts/latest-pending
curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:7888/lobster/admin/
curl -sL -o /dev/null -w '%{http_code}' https://<PROD_MAIN_DOMAIN>/lobster/admin/login
```
