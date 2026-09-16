# 宣传官网部署说明 - prod

> **当前状态**：尚未搭建独立的 prod 环境。本文内容暂时与
> `uat.md` 保持一致（前后端分离、端口、systemd、Nginx 套路相同）。
> 待 prod 环境（独立域名、独立业务服务器、独立证书）就绪后，再据实修改本文的
> 服务器 IP、域名、证书路径与密钥，并补充与 uat 的差异点。

本文只描述 `lobster-input-landing` 宣传官网的**单独部署**。官网已从纯静态站点重构为
**前后端分离**两个项目（与管理端 `lobster-input-admin` 同一模式）：

- `frontend/`：Vue 3 + Vite + TS SPA，挂在根路径 `/`。
- `backend/`：FastAPI 官网专属后端，**与主后端共享同一个 MongoDB（voice_input 库）**，
  自管独立网页登录态（`lobster_site_token` Cookie），不依赖也不改动主后端的单平台单设备会话。

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-landing` |
| 服务器目录 | `/opt/lobster-landing/`（`backend/` + `frontend/`） |
| 后端 systemd | `lobster-landing-api` |
| 前端 systemd | `lobster-landing-frontend` |
| 后端端口 | `8891`（仅 API） |
| 前端端口 | `7891`（SPA，vite preview） |
| 后端 API 外部前缀 | `/lobster/site/api/`（Nginx rewrite 掉 `/lobster/site` 转 8891） |
| 前端外部路径 | `/`（根） |
| 官网域名（prod 待定） | 暂沿用 uat：`example.com`（`.cn` 已划归 preview 内测环境）；prod 独立后改此处 |

> 旧静态站点（9010、`python -m http.server`）已废弃，prod 不再使用。

## 部署流程

与 `uat.md` 完全一致：

1. **同步代码**（排除 `venv` / `node_modules` / `.env`，**不要 `--delete`**）：
   ```bash
   rsync -az \
     --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
     --exclude='backend/.env' --exclude='backend/venv' \
     --exclude='frontend/node_modules' --exclude='frontend/dist' \
     -e "ssh -o StrictHostKeyChecking=yes" \
     "$ROOT/lobster-input-landing/" "root@<PROD_BUSINESS_IP>:/opt/lobster-landing/"
   ```
2. **后端**：`/usr/local/bin/python3.12 -m venv venv` → `pip install -r requirements.txt` →
   创建 `backend/.env`（`MONGODB_URI` 复用 prod 主库、`SITE_JWT_SECRET` 随机、`COOKIE_SECURE=true`、
   `BACKEND_URL=http://127.0.0.1:8000`）→ systemd `lobster-landing-api`（8891）。
3. **前端**：`npm install` → `npm run build` → systemd `lobster-landing-frontend`（7891）。
4. **网关 Nginx**（prod 对应 vhost）：新增 `^~ /lobster/site/api/` → 8891；根 `/` → 7891。

systemd 单元文件、`.env` 模板、Nginx location 写法、验证清单详见 `uat.md`，
prod 仅替换域名 / 业务服务器 IP / 证书路径 / 密钥。

## prod 与 uat 的预期差异（待 prod 环境就绪后补全）

- 业务服务器公网 / 私网 IP（Nginx `proxy_pass` 目标）。
- 域名与 SSL 证书路径。
- `COOKIE_SECURE` 保持 `true`（prod 必须 HTTPS）。
- `.env` 各密钥使用 prod 独立值（切勿复用 uat/preview 密钥）。
- 若 prod 与 uat/preview 同网关共存，用不同 `server_name` 区隔，端口前缀策略不变。

## 发布后验证

```bash
curl -s  http://127.0.0.1:8891/health
curl -sL -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7891/
curl -sI https://<PROD_DOMAIN>/
curl -s  https://<PROD_DOMAIN>/lobster/site/api/v1/config/startup
curl -s  "https://<PROD_DOMAIN>/lobster/site/api/v1/agreements?type=privacy&lang=zh" | head -c 120
```
