# 号池管理平台部署说明 - uat

本文只描述 `lobster-input-api-manage` 号池管理平台（前后端分离）在 uat（公测环境，原文档中的 "preview"）的部署。服务器整体发布顺序和网关配置见 `lobster-input-backend/docs/operations/server-deploy-uat.md`。preview（内测环境）版本见本目录 `preview.md`。

## 拓扑与凭据（重要,先读）

uat 是**两层结构**,前端/后端服务**不在网关上运行**:

| 角色 | 地址 | 说明 |
|---|---|---|
| 网关服务器 | `192.0.2.13` | 仅运行 Nginx 入口,把 `/lobster/api-pool/` 转发到业务服务器;**这里没有 node/前端服务,`/opt/lobster-api-pool/frontend` 仅作同步中转,可能为空** |
| 业务服务器 | `192.0.2.14`(私网 `192.0.2.11`) | **长期实例**;真正运行后端(8889)、前端 systemd(7889)、Node、dist 的机器;`lobster-api-pool-frontend` 服务在此 |

发布路径:`本地 → 网关 /opt/lobster-api-pool/ → 业务服务器 /opt/lobster-api-pool/ → 在业务服务器构建并重启 systemd`。也可**直连业务服务器**(见下「同步代码」)。

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
| 本地仓库 | `lobster-input-api-manage` |
| 服务器目录 | `/opt/lobster-api-pool/` |
| 后端 systemd | `lobster-api-pool` |
| 前端 systemd | `lobster-api-pool-frontend` |
| 后端端口 | `8889`（API + /health） |
| 前端端口 | `7889`（SPA 静态资源） |
| 外部管理路径 | `/lobster/api-pool` |
| 内部接口 | `/api/v1/pool/*`，只允许内网服务调用 |
| uat 地址 | `https://example.com/lobster/api-pool/` |

## 目录结构

```text
/opt/lobster-api-pool/
├── backend/
│   ├── app/
│   ├── venv/
│   ├── .env
│   └── run.py
└── frontend/
    ├── dist/
    └── node_modules/
```

## .env 关键项（backend/.env）

```env
MONGODB_URI=mongodb://YOUR_DB_USER:YOUR_DB_PASSWORD@localhost:27017/?authSource=admin
MONGODB_DB_NAME=lobster_api_pool
INTERNAL_API_KEY=<与后端 API_POOL_INTERNAL_KEY 一致>
INTERNAL_SIGNATURE_TOLERANCE_SEC=300
COOKIE_SECURE=true
EXPOSE_API_DOCS=false
PORT=8889
HOST=0.0.0.0
BASE_URL=/lobster/api-pool
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
  "$ROOT/lobster-input-api-manage/" "$GATEWAY_HOST:/opt/lobster-api-pool/"
```

### 仅发布前端（直连业务服务器,本任务实测可用）

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
BUSINESS_HOST="root@192.0.2.14"
BUSINESS_PASSWORD='YOUR_BUSINESS_PASSWORD'
SSH_OPT="-o StrictHostKeyChecking=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no"

rsync -az --exclude='.git' --exclude='node_modules' --exclude='dist' --exclude='logs' \
  -e "sshpass -p $BUSINESS_PASSWORD ssh $SSH_OPT" \
  "$ROOT/lobster-input-api-manage/frontend/" "$BUSINESS_HOST:/opt/lobster-api-pool/frontend/"

sshpass -p "$BUSINESS_PASSWORD" ssh $SSH_OPT "$BUSINESS_HOST" '
  set -e
  cd /opt/lobster-api-pool/frontend
  npm run build
  systemctl restart lobster-api-pool-frontend
  sleep 3
  curl -s -o /dev/null -w "api-pool 7889 = %{http_code}\n" http://127.0.0.1:7889/lobster/api-pool/
'
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

`/etc/systemd/system/lobster-api-pool.service`：

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

`/etc/systemd/system/lobster-api-pool-frontend.service`：

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

## Nginx 转发（网关）

- `/lobster/api-pool/health` → 业务服务器 `8889`
- `/lobster/api-pool/api/` → 业务服务器 `8889`
- `/lobster/api-pool/api/v1/pool` → 对外返回 403
- 其余 `/lobster/api-pool/` → 业务服务器 `7889`

详见 `lobster-input-backend/docs/operations/gateway-nginx-uat.md`。

## 发布后验证

`127.0.0.1` 的探活需在**业务服务器(192.0.2.14)本机**执行;公网 URL 可在任意机器执行:

```bash
# 业务服务器本机:
curl -s http://127.0.0.1:8889/health
curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:7889/lobster/api-pool/
tail -100 /var/log/lobster-api-pool.log

# 任意机器(公网,经网关):
curl -s https://example.com/lobster/api-pool/health
curl -sL -o /dev/null -w '%{http_code}' https://example.com/lobster/api-pool/login
```

如需补齐实时 ASR Key：

```bash
cd /opt/lobster-api-pool/backend
venv/bin/python scripts/seed_realtime_asr_key.py
```

## 本地开发

```bash
bash scripts/restart.sh
```
