# 宣传官网部署说明 - preview

本文只描述 `lobster-input-landing` 宣传官网在 preview（内测环境，2026-07 新建）的**单独部署**。官网为**前后端分离**两个项目（与管理端 `lobster-input-admin` 同一模式）：

- `frontend/`：Vue 3 + Vite + TS SPA，挂在根路径 `/`。
- `backend/`：FastAPI，官网专属后端，**与主后端共享同一个 MongoDB（voice_input 库）**，
  自管独立网页登录态（`lobster_site_token` Cookie），不依赖也不改动主后端的单平台单设备会话。

服务器整体发布顺序、网关配置与从零重建 runbook 见 `lobster-input-backend/docs/operations/server-deploy-preview.md`
与 `lobster-input-backend/docs/operations/gateway-nginx-preview.md`。uat（公测环境）版本见本目录 `uat.md`。

> **preview 业务服务器是抢占式实例，随时可能被释放回收。** IP 只在下表集中定义；实例更换后替换本表与命令变量即可,并同步更换网关 `.cn` vhost 的 `proxy_pass` 私网 IP。

## 拓扑（当前值）

| 角色 | 当前值 |
|---|---|
| 网关服务器（三环境共享） | `192.0.2.13` |
| preview 业务服务器公网 IP | `192.0.2.15` |
| preview 业务服务器私网 IP | `192.0.2.12` |
| preview 官网域名 | `https://example.net`、`https://www.example.net` |

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-landing` |
| 服务器目录 | `/opt/lobster-landing/`（`backend/` + `frontend/`） |
| 后端 systemd | `lobster-landing-api` |
| 前端 systemd | `lobster-landing-frontend` |
| 后端端口 | `8891`（仅 API） |
| 前端端口 | `7891`（SPA 静态资源，vite preview） |
| 后端 API 外部前缀 | `/lobster/site/api/`（Nginx rewrite 掉 `/lobster/site` 转 8891） |
| 前端外部路径 | `/`（根） |
| 官网域名（preview） | `https://example.net`、`https://www.example.net` |

## 目录结构

```text
/opt/lobster-landing/
├── backend/            # FastAPI 官网后端
│   ├── app/            # core / middleware / repositories / services / api / schemas
│   ├── venv/           # 服务器本地，不随代码同步
│   ├── .env            # 服务器本地，含密钥，不随代码同步
│   └── run.py
└── frontend/           # Vue 3 SPA
    ├── dist/           # npm run build 产物（含 public 里的 sitemap/robots/favicon/重定向桩）
    ├── node_modules/   # 服务器本地，不随代码同步
    └── package.json
```

## .env 关键项（backend/.env）

密钥值 preview 独立生成,不与 uat 复用。

```env
PORT=8891
HOST=0.0.0.0
BASE_URL=/lobster/site
# 与主后端/管理端共享 preview 本机主库（直接复用 /opt/lobster-admin/backend/.env 的 MONGODB_URI）
MONGODB_URI=mongodb://YOUR_DB_USER:YOUR_DB_PASSWORD@localhost:27017/?authSource=admin
MONGODB_DB_NAME=voice_input
# 官网独立会话密钥（与主后端 JWT 完全独立，随机生成）
SITE_JWT_SECRET=<随机 48 字节 urlsafe>
SITE_JWT_ALGORITHM=HS256
SITE_JWT_EXPIRE_MINUTES=10080
AUTH_COOKIE_NAME=lobster_site_token
COOKIE_SECURE=true
COOKIE_PATH=/
# 仅用于代理发送验证码，复用主后端真实邮件与限频
BACKEND_URL=http://127.0.0.1:8000
TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
EXPOSE_API_DOCS=false
```

## 同步代码

采用"排除服务器本地产物"的前后端分离同步（不要 `--delete`）。
preview 业务服务器应独立配置 SSH 凭据，实际值不写入仓库，本机无 SSH key 时用 `sshpass`。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
PREVIEW_IP="192.0.2.15"   # 实例被释放后只改这里
BUSINESS="root@$PREVIEW_IP"
RSH="sshpass -p '<password>' ssh -o StrictHostKeyChecking=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no"

rsync -az \
  --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
  --exclude='backend/.env' --exclude='backend/venv' --exclude='backend/.pid' --exclude='backend/logs' \
  --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='frontend/.preview.pid' --exclude='frontend/logs' \
  -e "$RSH" \
  "$ROOT/lobster-input-landing/" "$BUSINESS:/opt/lobster-landing/"
```

> **关键**：去掉 `--delete`，并排除 `venv` / `node_modules` / `.env`，避免误删服务器本地产物。
> 走网关两跳中转时，网关上的 preview 中转目录为 `/opt/preview/lobster-landing/`（与 uat 的
> `/opt/lobster-landing/` 中转目录隔离），见 `server-deploy-preview.md` 一键脚本。

## 首次部署 / 实例重建（在业务服务器执行）

抢占式实例被回收后按 `server-deploy-preview.md` 的从零重建 runbook 执行;官网部分:

```bash
# 1. 后端 venv + 依赖
cd /opt/lobster-landing/backend
/usr/local/bin/python3.12 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt
# 创建 /opt/lobster-landing/backend/.env：复用 admin 的 MONGODB_URI，生成随机 SITE_JWT_SECRET
ADMIN_MONGO=$(grep '^MONGODB_URI=' /opt/lobster-admin/backend/.env)
SITE_SECRET=$(/usr/local/bin/python3.12 -c 'import secrets;print(secrets.token_urlsafe(48))')
# ……写入上面的 .env 模板，替换 MONGODB_URI / SITE_JWT_SECRET，chmod 600

# 2. 前端构建（Node 18+）
cd /opt/lobster-landing/frontend
npm install
npm run build   # 产出 dist/

# 3. 安装并启动 systemd
systemctl daemon-reload
systemctl enable --now lobster-landing-api
systemctl enable --now lobster-landing-frontend
```

## systemd - 后端

`/etc/systemd/system/lobster-landing-api.service`（与 uat 完全一致）：

```ini
[Unit]
Description=Lobster Landing Site API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-landing/backend
EnvironmentFile=/opt/lobster-landing/backend/.env
ExecStart=/opt/lobster-landing/backend/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8891 --workers 1
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-landing-api.log
StandardError=append:/var/log/lobster-landing-api.log

[Install]
WantedBy=multi-user.target
```

## systemd - 前端

`/etc/systemd/system/lobster-landing-frontend.service`（与 uat 完全一致）：

```ini
[Unit]
Description=Lobster Landing Frontend SPA
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/lobster-landing/frontend
ExecStart=/usr/bin/npm run preview
Restart=always
RestartSec=5
StandardOutput=append:/var/log/lobster-landing-frontend.log
StandardError=append:/var/log/lobster-landing-frontend.log

[Install]
WantedBy=multi-user.target
```

前端 `package.json` 的 `preview` 脚本（vite preview,与环境名无关）监听 `7891`，`vite.config.ts` 的 `base` 为 `/`。

## Nginx 转发（网关 `.cn` vhost）

网关 `lobster-input-cn.conf` 把 `^~ /lobster/site/api/` rewrite 掉前缀后转发到 preview 业务服务器 `8891`，其余根路径 `/` 转发到 `7891`。preview 只涉及 `.cn` vhost（`.com` 属于 uat）。详见
`lobster-input-backend/docs/operations/gateway-nginx-preview.md`。

## 发布后验证

```bash
# 业务服务器本机
curl -s  http://127.0.0.1:8891/health
curl -sL -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7891/
curl -sL -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7891/privacy.html

# 网关 / 公网（.cn）
curl -sI https://example.net/
curl -s  https://example.net/lobster/site/api/v1/config/startup
curl -s  "https://example.net/lobster/site/api/v1/agreements?type=privacy&lang=zh" | head -c 120
curl -s -o /dev/null -w '%{http_code}\n' https://example.net/lobster/site/api/v1/auth/me   # 401（未登录）

# 回归 preview 其它服务不受影响
curl -s  https://api.example.net/lobster/health
curl -sL -o /dev/null -w '%{http_code}\n' https://example.net/lobster/admin/login
```

## 本地开发

```bash
# 后端
cd backend && bash scripts/restart.sh        # uvicorn 8891
# 前端（vite preview 自带 /lobster/site → 8891 代理，本地直连预览自洽）
cd frontend && bash scripts/restart.sh       # vite preview 7891
```
