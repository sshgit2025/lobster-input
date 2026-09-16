# 管理端部署说明 - uat

本文只描述 `lobster-input-admin` 管理端服务（前后端分离）在 uat（公测环境，原文档中的 "preview"）的部署。服务器整体发布顺序和网关配置见 `lobster-input-backend/docs/operations/server-deploy-uat.md`。preview（内测环境）版本见本目录 `preview.md`。

## 拓扑与凭据（重要，先读）

uat 是**两层结构**,前端/后端服务**不在网关上运行**:

| 角色 | 地址 | 说明 |
|---|---|---|
| 网关服务器 | `192.0.2.13` | 仅运行 Nginx 入口,负责把 `/lobster/admin/` 转发到业务服务器;**这里没有 node/前端服务,`/opt/lobster-admin/frontend` 仅作为同步中转,可能为空** |
| 业务服务器 | `192.0.2.14`(私网 `192.0.2.11`) | **长期实例**;真正运行后端(8888)、前端 systemd(7888)、Node、dist 的机器;`lobster-admin-frontend` 服务在此 |

发布路径:`本地 → 网关 /opt/lobster-admin/ → 业务服务器 /opt/lobster-admin/ → 在业务服务器构建并重启 systemd`。也可**直连业务服务器**完成(见下「同步代码（直连业务服务器）」)。

uat 业务服务器当前允许 root 密码登录(长期实例,密码登录为历史遗留):

```bash
BUSINESS_HOST="root@192.0.2.14"
BUSINESS_PASSWORD='YOUR_BUSINESS_PASSWORD'   # ⚠️ 仅 uat 环境;勿用于 prod。明文密码会随本仓库提交,后续建议改用 SSH key / 密钥保管库
SSH_OPT="-o StrictHostKeyChecking=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no"
# 本机无 sshpass 时: brew install hudochenkov/sshpass/sshpass
```

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-admin` |
| 服务器目录 | `/opt/lobster-admin/` |
| 后端 systemd | `lobster-admin` |
| 前端 systemd | `lobster-admin-frontend` |
| 后端端口 | `8888`（仅 API） |
| 前端端口 | `7888`（SPA 静态资源） |
| 外部路径 | `/lobster/admin` |
| uat 地址 | `https://example.com/lobster/admin/` |

## 目录结构

```text
/opt/lobster-admin/
├── backend/          # FastAPI 后端（API + 旧版模板，生产流量走前端）
│   ├── app/
│   ├── venv/
│   ├── .env
│   └── run.py
└── frontend/         # Vue 3 SPA
    ├── dist/
    └── node_modules/
```

## .env 关键项（backend/.env）

```env
MONGODB_URI=mongodb://YOUR_DB_USER:YOUR_DB_PASSWORD@localhost:27017/?authSource=admin
BASE_URL=/lobster/admin
BACKEND_URL=http://127.0.0.1:8000
BACKEND_API_KEY=<与后端 API_KEY 一致>
API_POOL_URL=http://127.0.0.1:8889
API_POOL_INTERNAL_KEY=<与号池 INTERNAL_API_KEY 一致>
PROVIDER_CONFIG_INTERNAL_KEY=<与后端 ADMIN_CONFIG_INTERNAL_KEY 一致>
PAYMENT_SERVICE_URL=http://127.0.0.1:8890
PAYMENT_CALLBACK_INTERNAL_KEY=<支付服务内部接口鉴权密钥>
ALERT_INTERNAL_KEY=<备份脚本告警上报密钥>
COOKIE_SECURE=true
EXPOSE_API_DOCS=false
PORT=8888
HOST=0.0.0.0
```

## 同步代码

> ⚠️ 注意:下面这条只把代码同步到**网关**,前端并不在网关运行。完整发布需再同步到业务服务器并在业务服务器构建重启(见 `server-deploy-uat.md` 一键脚本),或直接用下方「直连业务服务器」写法。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@192.0.2.13"
SSH_OPT="-o StrictHostKeyChecking=yes"

# 第一跳:本地 → 网关(仅中转)
rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='.venv' --exclude='venv' \
  --exclude='frontend/node_modules' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-admin/" "$GATEWAY_HOST:/opt/lobster-admin/"
```

### 仅发布前端（直连业务服务器,本任务实测可用）

只改前端时,直接把 `frontend/` 同步到业务服务器,在业务服务器构建并重启前端 systemd 即可(前端 `dist` 由服务器构建,故同步时排除本地 `dist`/`node_modules`):

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
BUSINESS_HOST="root@192.0.2.14"
BUSINESS_PASSWORD='YOUR_BUSINESS_PASSWORD'
SSH_OPT="-o StrictHostKeyChecking=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no"

rsync -az --exclude='.git' --exclude='node_modules' --exclude='dist' --exclude='logs' \
  -e "sshpass -p $BUSINESS_PASSWORD ssh $SSH_OPT" \
  "$ROOT/lobster-input-admin/frontend/" "$BUSINESS_HOST:/opt/lobster-admin/frontend/"

sshpass -p "$BUSINESS_PASSWORD" ssh $SSH_OPT "$BUSINESS_HOST" '
  set -e
  cd /opt/lobster-admin/frontend
  npm run build
  systemctl restart lobster-admin-frontend
  sleep 3
  curl -s -o /dev/null -w "admin 7888 = %{http_code}\n" http://127.0.0.1:7888/lobster/admin/
'
```

## 首次部署

```bash
# 后端
cd /opt/lobster-admin/backend
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

# 前端（需要 Node.js 18+）
cd /opt/lobster-admin/frontend
npm install
npm run build
```

## systemd - 后端

`/etc/systemd/system/lobster-admin.service`：

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

`/etc/systemd/system/lobster-admin-frontend.service`：

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

前端 `package.json` 中 `preview` 脚本监听 `7888` 端口，`vite.config.ts` 的 `base` 为 `/lobster/admin/`。

## Nginx 转发（网关）

网关将 `/lobster/admin/api/` 转发到业务服务器 `8888`，其余 `/lobster/admin/` 转发到 `7888`。详见 `lobster-input-backend/docs/operations/gateway-nginx-uat.md`。

## 发布后验证

`127.0.0.1` 的探活需在**业务服务器(192.0.2.14)本机**执行;公网 URL 可在任意机器执行:

```bash
# 业务服务器本机:
curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:8888/api/v1/alerts/latest-pending
curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:7888/lobster/admin/
tail -100 /var/log/lobster-admin.log
tail -100 /var/log/lobster-admin-frontend.log

# 任意机器(公网,经网关):
curl -sL -o /dev/null -w '%{http_code}' https://example.com/lobster/admin/login
```

## 本地开发

```bash
# 后端 + 前端一键启动
bash scripts/restart.sh
```
