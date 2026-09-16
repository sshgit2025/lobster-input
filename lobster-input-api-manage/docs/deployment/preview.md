# 号池管理平台部署说明 - preview

本文只描述 `lobster-input-api-manage` 号池管理平台（前后端分离）在 preview（内测环境，2026-07 新建）的部署。服务器整体发布顺序、网关配置与从零重建 runbook 见 `lobster-input-backend/docs/operations/server-deploy-preview.md`。uat（公测环境）版本见本目录 `uat.md`。

## 拓扑与凭据（重要,先读）

preview 与 uat 同为**两层结构**,前端/后端服务**不在网关上运行**:

| 角色 | 地址 | 说明 |
|---|---|---|
| 网关服务器 | `192.0.2.13` | uat/preview/prod 三环境共享,仅运行 Nginx 入口,把 `.cn` 域名的 `/lobster/api-pool/` 转发到 preview 业务服务器;**这里没有 node/前端服务,`/opt/preview/lobster-api-pool/frontend` 仅作同步中转,可能为空** |
| 业务服务器 | `192.0.2.15`(私网 `192.0.2.12`) | **抢占式实例,随时可能被释放回收**;真正运行后端(8889)、前端 systemd(7889)、Node、dist 的机器;`lobster-api-pool-frontend` 服务在此 |

> 实例被释放后换新 IP:只需替换上表与下文命令变量中的 IP,并同步更换网关 `.cn` vhost 的 `proxy_pass` 私网 IP,其余步骤照跑。完整重建流程见 `server-deploy-preview.md`。

发布路径:`本地 → 网关 /opt/preview/lobster-api-pool/ → 业务服务器 /opt/lobster-api-pool/ → 在业务服务器构建并重启 systemd`。也可**直连业务服务器**(见下「同步代码」)。注意网关中转目录带 `/opt/preview/` 前缀,与 uat 的 `/opt/lobster-api-pool/` 中转目录隔离;业务服务器上仍是 `/opt/lobster-api-pool/`。

preview 业务服务器应独立配置 SSH 凭据:

```bash
PREVIEW_IP="192.0.2.15"     # 实例被释放后只改这里
BUSINESS_HOST="root@$PREVIEW_IP"
BUSINESS_PASSWORD='<与 uat 业务服务器相同,见 uat.md>'
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
| preview 地址 | `https://example.net/lobster/api-pool/` |

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

密钥值 preview 独立生成,不与 uat 复用;各服务间的内部鉴权密钥必须互相匹配。

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

> ⚠️ 注意:下面这条只把代码同步到**网关**的 preview 中转目录,前端并不在网关运行。完整发布需再同步到业务服务器并在业务服务器构建重启(见 `server-deploy-preview.md` 一键脚本),或直接用下方「直连业务服务器」写法。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@192.0.2.13"
SSH_OPT="-o StrictHostKeyChecking=yes"

# 第一跳:本地 → 网关(仅中转,preview 专用前缀)
rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='.venv' --exclude='venv' \
  --exclude='frontend/node_modules' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-api-manage/" "$GATEWAY_HOST:/opt/preview/lobster-api-pool/"
```

### 仅发布前端（直连业务服务器）

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
PREVIEW_IP="192.0.2.15"
BUSINESS_HOST="root@$PREVIEW_IP"
BUSINESS_PASSWORD='<与 uat 业务服务器相同,见 uat.md>'
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

## 首次部署 / 实例重建

抢占式实例被回收后按 `server-deploy-preview.md` 的从零重建 runbook 执行;号池端部分:

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

重建后需补录必要配置数据:号池 API Key(preview 单独录入,不与 uat 共池)、管理员账号。业务数据不从 uat 同步。

## systemd - 后端

`/etc/systemd/system/lobster-api-pool.service`（与 uat 完全一致）：

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

`/etc/systemd/system/lobster-api-pool-frontend.service`（与 uat 完全一致）：

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

## Nginx 转发（网关 `.cn` vhost）

- `/lobster/api-pool/health` → preview 业务服务器 `8889`
- `/lobster/api-pool/api/` → preview 业务服务器 `8889`
- `/lobster/api-pool/api/v1/pool` → 对外返回 403
- 其余 `/lobster/api-pool/` → preview 业务服务器 `7889`

详见 `lobster-input-backend/docs/operations/gateway-nginx-preview.md`。

## 发布后验证

`127.0.0.1` 的探活需在**业务服务器(192.0.2.15)本机**执行;公网 URL 可在任意机器执行:

```bash
# 业务服务器本机:
curl -s http://127.0.0.1:8889/health
curl -sL -o /dev/null -w '%{http_code}' http://127.0.0.1:7889/lobster/api-pool/
tail -100 /var/log/lobster-api-pool.log

# 任意机器(公网,经网关):
curl -s https://example.net/lobster/api-pool/health
curl -sL -o /dev/null -w '%{http_code}' https://example.net/lobster/api-pool/login
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
