# 宣传官网部署说明 - uat

本文只描述 `lobster-input-landing` 宣传官网的**单独部署**。官网已从纯静态站点重构为
**前后端分离**两个项目（与管理端 `lobster-input-admin` 同一模式）：

- `frontend/`：Vue 3 + Vite + TS SPA，挂在根路径 `/`。
- `backend/`：FastAPI，官网专属后端，**与主后端共享同一个 MongoDB（voice_input 库）**，
  自管独立网页登录态（`lobster_site_token` Cookie），不依赖也不改动主后端的单平台单设备会话。

本文描述 uat（公测环境，原文档中的 "preview"）的部署；uat 业务服务器（192.0.2.14）为长期实例。
preview（内测环境）版本见本目录 `preview.md`。
服务器整体发布顺序与网关配置见 `lobster-input-backend/docs/operations/server-deploy-uat.md`
与 `lobster-input-backend/docs/operations/gateway-nginx-uat.md`。

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
| 官网域名（uat） | `https://example.com`、`https://www.example.com`（`.cn` 域名已划归 preview 内测环境） |

> 旧静态站点的 `lobster-landing`（9010 端口、`python -m http.server`）已废弃；切换成功后停用。

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

```env
PORT=8891
HOST=0.0.0.0
BASE_URL=/lobster/site
# 与主后端/管理端共享主库（直接复用 /opt/lobster-admin/backend/.env 的 MONGODB_URI）
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

官网从“整仓 `--delete` 静态镜像”改为“排除服务器本地产物”的前后端分离同步。
uat 业务服务器允许 root 密码登录（密码见 `server-deploy-uat.md`），本机无 SSH key 时用 `sshpass`。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
BUSINESS="root@192.0.2.14"
RSH="sshpass -p '<password>' ssh -o StrictHostKeyChecking=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no"

rsync -az \
  --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
  --exclude='backend/.env' --exclude='backend/venv' --exclude='backend/.pid' --exclude='backend/logs' \
  --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='frontend/.preview.pid' --exclude='frontend/logs' \
  -e "$RSH" \
  "$ROOT/lobster-input-landing/" "$BUSINESS:/opt/lobster-landing/"
```

> **关键**：去掉 `--delete`，并排除 `venv` / `node_modules` / `.env`，避免误删服务器本地产物。

## 首次部署（在业务服务器执行）

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

# 4. 切换成功后停用旧静态服务
systemctl disable --now lobster-landing
```

## systemd - 后端

`/etc/systemd/system/lobster-landing-api.service`：

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

`/etc/systemd/system/lobster-landing-frontend.service`：

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

前端 `package.json` 的 `preview` 脚本监听 `7891`，`vite.config.ts` 的 `base` 为 `/`。

## Nginx 转发（网关）

网关把 `^~ /lobster/site/api/` rewrite 掉前缀后转发到 `8891`，其余根路径 `/` 转发到 `7891`。
uat 只涉及 `.com` vhost（`example.net` vhost 属于 preview 内测环境，转发到 preview 业务服务器，
见 `gateway-nginx-preview.md`）。详见
`lobster-input-backend/docs/operations/gateway-nginx-uat.md`。

## 重构后的行为要点

- 首页 / 营销页样式、交互、动画、6 语言 i18n、内测倒计时与下载逻辑**与旧站完全一致**，
  仅由纯静态重构为组件化 Vue 工程。
- 隐私政策 `/privacy` 与用户协议 `/terms` 改为**动态**：后端直读主库 `agreements` 集合，
  按右上角选中语言展示，缺失回退 `en`。旧 URL `/privacy.html`、`/terms.html` 保留为重定向桩。
- 登录/注册（邮箱验证码，对齐 Mac 端逻辑、受管理端配置门控：邀请码/注册开关/人数上限）、
  右上角登录态（个人中心 + 退出登录）、个人中心（账号 + 各项积分 + 订阅订单明细，无退款入口）。
- 发码复用主后端公开接口；登录/注册/积分/订单/协议全部基于共享主库，官网自管会话。

## 发布后验证

```bash
# 业务服务器本机
curl -s  http://127.0.0.1:8891/health
curl -sL -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7891/
curl -sL -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7891/privacy.html

# 网关 / 公网
curl -sI https://example.com/
curl -s  https://example.com/lobster/site/api/v1/config/startup
curl -s  "https://example.com/lobster/site/api/v1/agreements?type=privacy&lang=zh" | head -c 120
curl -s -o /dev/null -w '%{http_code}\n' https://example.com/lobster/site/api/v1/auth/me   # 401（未登录）

# 回归其它端不受影响
curl -s  https://api.example.com/lobster/health
curl -sL -o /dev/null -w '%{http_code}\n' https://example.com/lobster/admin/login
```

## 本地开发

```bash
# 后端
cd backend && bash scripts/restart.sh        # uvicorn 8891
# 前端（vite preview 自带 /lobster/site → 8891 代理，本地直连预览自洽）
cd frontend && bash scripts/restart.sh       # vite preview 7891
```
