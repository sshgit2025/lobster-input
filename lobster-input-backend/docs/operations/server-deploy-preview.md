# 服务器整体部署与一键发布 - preview

本文是 preview（内测环境，2026-07 新建）服务器服务的完整发布流程与**从零重建 runbook**，只覆盖服务器服务，不包含客户端在线更新发布。uat（公测环境）流程见 `docs/operations/server-deploy-uat.md`。

> **重要：preview 业务服务器是抢占式实例，随时可能被释放回收。** 本文按"可换 IP 从零重建"编写：所有 IP 只在下方拓扑表集中定义，命令一律引用 shell 变量。实例被释放后换新 IP，只需替换本表和脚本变量，其余步骤照跑。

## 当前拓扑（IP 唯一事实源）

| 角色 | 当前 preview 值 | 说明 |
|---|---|---|
| 网关服务器 | `192.0.2.13` | 运行 Nginx，uat/preview/prod 三环境共享入口；不属于任何单一环境 |
| preview 业务服务器公网 IP | `192.0.2.15` | **抢占式实例，会被释放回收**；运行所有业务服务、MongoDB、Redis |
| preview 业务服务器私网 IP | `192.0.2.12` | 网关 Nginx `proxy_pass` 目标 |
| preview 主域名 | `example.net` | 官网、管理端、号池、支付页面 |
| preview API 域名 | `api.example.net` | 客户端 API 与 WebSocket |
| preview 支付域名 | `payment.example.net` | 浏览器支付中转页 |

统一 shell 变量（本文所有命令以此为准）：

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_IP="192.0.2.13"
PREVIEW_IP="192.0.2.15"          # 实例被释放后只改这里
PREVIEW_PRIVATE_IP="192.0.2.12" # 实例被释放后只改这里（网关 Nginx 同步更换）
GATEWAY_HOST="root@$GATEWAY_IP"
BUSINESS_HOST="root@$PREVIEW_IP"
SSH_OPT="-o StrictHostKeyChecking=yes"
```

网关与业务服务器应使用独立 SSH 凭据，实际值由密钥管理系统提供。无 SSH key 时把 `ssh $SSH_OPT` / `rsync -e "ssh $SSH_OPT"` 替换为 `sshpass -p "$BUSINESS_PASSWORD" ssh $SSH_OPT` 写法。

与 uat 的关键差异：

- 业务数据不同步：preview 用独立 MongoDB/Redis 数据，只初始化必要配置数据。
- LangWatch/qdrant 等可观测性平台组件**不部署**到 preview；preview 后端仍向 uat 上的 LangWatch 上报，并使用独立的 `lobster-backend-preview` 项目 Key。
- 网关中转目录使用 `/opt/preview/` 前缀（`/opt/preview/lobster-*`），避免与 uat 的 `/opt/lobster-*` 中转目录冲突；业务服务器上的目录结构与 uat 完全一致（仍为 `/opt/lobster-*`）。
- 目录结构、端口（8000/8888/7888/8889/7889/8890/8891/7891）、systemd 服务名与 uat 完全一致。

单服务细节分散在各自仓库：

| 服务 | 仓库文档 | 服务器目录 | 端口 |
|---|---|---|---|
| 后端 | `lobster-input-backend/docs/deployment/preview.md` | `/opt/lobster-backend/` | 8000 |
| 管理端 API | `lobster-input-admin/docs/deployment/preview.md` | `/opt/lobster-admin/backend/` | 8888 |
| 管理端前端 | `lobster-input-admin/docs/deployment/preview.md` | `/opt/lobster-admin/frontend/` | 7888 |
| 号池端 API | `lobster-input-api-manage/docs/deployment/preview.md` | `/opt/lobster-api-pool/backend/` | 8889 |
| 号池端前端 | `lobster-input-api-manage/docs/deployment/preview.md` | `/opt/lobster-api-pool/frontend/` | 7889 |
| 支付端 | `lobster-input-payment/docs/deployment/preview.md` | `/opt/lobster-payment/` | 8890 |
| 官网后端 API | `lobster-input-landing/docs/deployment/preview.md` | `/opt/lobster-landing/backend/` | 8891 |
| 官网前端 SPA | `lobster-input-landing/docs/deployment/preview.md` | `/opt/lobster-landing/frontend/` | 7891 |

## 实例被回收后的恢复路径（总览）

1. 新购抢占式实例（同地域同 VPC，拿到新公网/私网 IP）。
2. 更新本文顶部拓扑表与 `PREVIEW_IP` / `PREVIEW_PRIVATE_IP` 变量。
3. 执行一键重建脚本 `lobster-input-backend/scripts/preview-server-bootstrap.sh <新公网IP>`（见下节），或按"从零重建"章节手工执行。
4. 更换网关 Nginx 两个 .cn vhost 中的 `proxy_pass` 私网 IP，`nginx -t && nginx -s reload`。
5. 跑"发布后验证"。

## 一键重建脚本

`lobster-input-backend/scripts/preview-server-bootstrap.sh`（以新机公网 IP 为参数）封装了下文"从零重建"章节的全部步骤：基础软件安装、目录创建、五服务代码同步、`.env` 生成、systemd 单元安装、必要配置数据初始化。

```bash
PREVIEW_LANGWATCH_API_KEY='<lobster-backend-preview 项目 Key>' \
  bash "$ROOT/lobster-input-backend/scripts/preview-server-bootstrap.sh" "$PREVIEW_IP"
```

`PREVIEW_LANGWATCH_API_KEY` 必须取自 LangWatch 的 `lobster-backend-preview` 项目，不能使用 `lobster-backend-uat` 项目 Key。项目 ID、正式 Key 位置、归属校验和轮换流程见 `docs/operations/langwatch.md`。

脚本执行完后仍需人工完成两步：① 网关 Nginx 私网 IP 更换并 reload；② 发布后验证。若脚本尚未就绪或执行失败，按下文手工 runbook 逐节执行。

## 从零重建 runbook

以下命令除注明"本地执行"外，均在 preview 业务服务器上执行（`ssh $SSH_OPT $BUSINESS_HOST`）。

### 1. 基础软件安装

与 uat 同构：Python 3.12、MongoDB（带 admin 认证）、Redis、Node.js 18+。

```bash
# Python 3.12（源码或包管理器安装，保证 /usr/local/bin/python3.12 可用）
python3.12 --version   # 期望 3.12.x

# MongoDB 7.x（安装后开启认证）
systemctl enable --now mongod
mongosh --eval '
  use admin;
  db.createUser({user:"admin", pwd:"<与 uat 约定一致，见各服务 .env>", roles:["root"]});
'
# /etc/mongod.conf 开启 security.authorization: enabled 后重启 mongod

# Redis
systemctl enable --now redis

# Node.js 18+（前端 SPA 构建与 vite preview 托管）
node --version   # 期望 >= 18
```

### 2. 目录结构创建

```bash
mkdir -p /opt/lobster-backend /opt/lobster-admin /opt/lobster-api-pool /opt/lobster-payment /opt/lobster-landing
```

网关服务器上创建 preview 专用中转目录（本地执行）：

```bash
ssh $SSH_OPT "$GATEWAY_HOST" 'mkdir -p /opt/preview/lobster-backend /opt/preview/lobster-admin /opt/preview/lobster-api-pool /opt/preview/lobster-payment /opt/preview/lobster-landing'
```

### 3. 五个服务代码同步（本地执行）

与 uat 相同的两跳路径：本地 → 网关 `/opt/preview/lobster-*` → 业务服务器 `/opt/lobster-*`。

```bash
set -euo pipefail
# 变量定义见文档顶部

COMMON_EXCLUDES=(
  --exclude='.git'
  --exclude='__pycache__'
  --exclude='*.pyc'
  --exclude='.env'
  --exclude='.venv'
  --exclude='venv'
)

rsync -az "${COMMON_EXCLUDES[@]}" --exclude='uploads/' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-backend/backend/" "$GATEWAY_HOST:/opt/preview/lobster-backend/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-admin/" "$GATEWAY_HOST:/opt/preview/lobster-admin/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-api-manage/" "$GATEWAY_HOST:/opt/preview/lobster-api-pool/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-payment/" "$GATEWAY_HOST:/opt/preview/lobster-payment/"

# 官网前后端分离：排除服务器本地产物，不要 --delete
rsync -az "${COMMON_EXCLUDES[@]}" \
  --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='frontend/logs' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-landing/" "$GATEWAY_HOST:/opt/preview/lobster-landing/"

ssh $SSH_OPT "$GATEWAY_HOST" "
  set -euo pipefail
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='uploads/' --exclude='venv' /opt/preview/lobster-backend/ root@$PREVIEW_IP:/opt/lobster-backend/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/preview/lobster-admin/ root@$PREVIEW_IP:/opt/lobster-admin/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/preview/lobster-api-pool/ root@$PREVIEW_IP:/opt/lobster-api-pool/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/preview/lobster-payment/ root@$PREVIEW_IP:/opt/lobster-payment/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' --exclude='frontend/node_modules' --exclude='frontend/dist' /opt/preview/lobster-landing/ root@$PREVIEW_IP:/opt/lobster-landing/
"
```

### 4. venv / 前端依赖安装

```bash
for d in /opt/lobster-backend /opt/lobster-admin/backend /opt/lobster-api-pool/backend /opt/lobster-payment /opt/lobster-landing/backend; do
  cd "$d"
  /usr/local/bin/python3.12 -m venv venv
  ./venv/bin/pip install --upgrade pip
  ./venv/bin/pip install -r requirements.txt
done

for d in /opt/lobster-admin/frontend /opt/lobster-api-pool/frontend /opt/lobster-landing/frontend; do
  cd "$d"
  npm install
  npm run build
done
```

### 5. .env 配置（preview 值）

`.env` 不随代码同步，重建时须在业务服务器逐个创建（`chmod 600`）。密钥值与 uat 的约定关系一致（内部鉴权密钥各服务间必须互相匹配；preview 与 uat 的密钥相互独立，不要复用）。

`/opt/lobster-backend/.env`：

```env
APP_ENV=preview
MONGODB_URI=mongodb://YOUR_DB_USER:YOUR_DB_PASSWORD@localhost:27017/?authSource=admin
REDIS_URL=redis://localhost:6379/0

API_POOL_URL=http://127.0.0.1:8889
API_POOL_INTERNAL_KEY=<与号池 INTERNAL_API_KEY 一致>
ADMIN_CONFIG_URL=http://127.0.0.1:8888
ADMIN_CONFIG_INTERNAL_KEY=<与管理端 PROVIDER_CONFIG_INTERNAL_KEY 一致>
PROVIDER_CONFIG_CACHE_TTL_SEC=600
INTERNAL_SIGNATURE_TOLERANCE_SEC=300

PAYMENT_SERVICE_URL=http://127.0.0.1:8890
PAYMENT_CALLBACK_INTERNAL_KEY=<与支付服务一致>
PAYMENT_CHECKOUT_PUBLIC_BASE_URL=https://payment.example.net/lobster

TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128,<网关内网 CIDR>
ASR_CORRECTION_ENABLED=true

LANGWATCH_ENABLED=true
LANGWATCH_ENDPOINT=http://192.0.2.11:5560
LANGWATCH_API_KEY=<lobster-backend-preview 项目 Key，不得使用 uat Key>
```

其余四个服务的 `.env` 模板见各仓库 `docs/deployment/preview.md`：

- 管理端 `/opt/lobster-admin/backend/.env`：`lobster-input-admin/docs/deployment/preview.md`
- 号池端 `/opt/lobster-api-pool/backend/.env`：`lobster-input-api-manage/docs/deployment/preview.md`
- 支付端 `/opt/lobster-payment/.env`：`lobster-input-payment/docs/deployment/preview.md`（`PUBLIC_BASE_URL` 用 `https://example.net/lobster/payment`）
- 官网 `/opt/lobster-landing/backend/.env`：`lobster-input-landing/docs/deployment/preview.md`

### 6. systemd 单元

八个单元文件与 uat 完全同名同内容（见各仓库 `docs/deployment/preview.md` 中的全文）：
`lobster-backend`、`lobster-admin`、`lobster-admin-frontend`、`lobster-api-pool`、`lobster-api-pool-frontend`、`lobster-payment`、`lobster-landing-api`、`lobster-landing-frontend`。

```bash
systemctl daemon-reload
systemctl enable --now lobster-api-pool lobster-api-pool-frontend
systemctl enable --now lobster-admin lobster-admin-frontend
systemctl enable --now lobster-payment
systemctl enable --now lobster-backend
systemctl enable --now lobster-landing-api lobster-landing-frontend
```

### 7. 必要配置数据初始化

业务数据不从 uat 同步，只初始化必要配置：

```bash
# 后端系统配置（幂等）
cd /opt/lobster-backend
PYTHONPATH=/opt/lobster-backend /opt/lobster-backend/venv/bin/python3.12 scripts/init_system_config.py

# 支付配置初始化（商品/价格/渠道等基础配置）
cd /opt/lobster-payment
venv/bin/python scripts/init_billing_config.py

# 号池实时 ASR Key 种子（key 值按 preview 单独录入，不复用 uat 池数据导出亦可）
cd /opt/lobster-api-pool/backend
venv/bin/python scripts/seed_realtime_asr_key.py
```

另需人工在管理端补齐（登录 `https://example.net/lobster/admin/`）：

- 管理员账号（首次可用管理端初始化脚本/注册流程创建）。
- Provider 配置（LLM/ASR/Search 上游模型配置，preview 单独维护）。
- 号池 API Key（在号池管理端 `https://example.net/lobster/api-pool/` 录入）。
- 支付渠道配置（Creem/ZPay 的 Key、Webhook Secret，回调地址用 .cn 域名，见支付端 preview 文档）。

### 8. 网关 Nginx 私网 IP 更换

实例更换后网关上只需改两处 .cn vhost 的 `proxy_pass` 私网 IP（本地执行）：

```bash
ssh $SSH_OPT "$GATEWAY_HOST" "
  sed -i 's/172\.17\.101\.<旧私网尾号>/$PREVIEW_PRIVATE_IP/g' \
    /www/server/panel/vhost/nginx/lobster-input-cn.conf \
    /www/server/panel/vhost/nginx/payment-lobster-input-cn.conf
  nginx -t && nginx -s reload
"
```

> 只允许改 .cn 两个 vhost；`lobster-input.conf`（.com，uat）和 prod 配置一律不动。完整 .cn vhost 目标配置见 `docs/operations/gateway-nginx-preview.md`。

## 日常发布（服务器已就绪时）

与从零重建的第 3 步相同（代码同步），随后在业务服务器清理缓存、跑 `init_system_config.py` 并按 uat 相同顺序重启：

```bash
ssh $SSH_OPT "$BUSINESS_HOST" '
  set -euo pipefail
  find /opt/lobster-backend /opt/lobster-admin /opt/lobster-api-pool /opt/lobster-payment -name "*.pyc" -delete 2>/dev/null || true
  find /opt/lobster-backend /opt/lobster-admin /opt/lobster-api-pool /opt/lobster-payment -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

  cd /opt/lobster-backend
  PYTHONPATH=/opt/lobster-backend /opt/lobster-backend/venv/bin/python3.12 scripts/init_system_config.py

  systemctl restart lobster-api-pool
  systemctl restart lobster-api-pool-frontend
  sleep 3
  systemctl restart lobster-admin
  systemctl restart lobster-admin-frontend
  sleep 3
  systemctl restart lobster-payment
  sleep 3
  systemctl restart lobster-backend
  systemctl restart lobster-landing-api
  systemctl restart lobster-landing-frontend
'
```

## 发布后验证

```bash
curl -s https://api.example.net/lobster/health
curl -sL -o /dev/null -w '%{http_code}\n' https://example.net/lobster/admin/login
curl -s https://example.net/lobster/api-pool/health
curl -s https://example.net/lobster/payment/health
curl -s https://payment.example.net/lobster/health
curl -sI https://example.net/
```

业务服务器本机验证：

```bash
ssh $SSH_OPT "$BUSINESS_HOST" '
  systemctl status lobster-api-pool lobster-api-pool-frontend lobster-admin lobster-admin-frontend lobster-payment lobster-backend lobster-landing-api lobster-landing-frontend --no-pager
  curl -s http://127.0.0.1:8000/health
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8888/api/v1/alerts/latest-pending
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7888/lobster/admin/
  curl -s http://127.0.0.1:8889/health
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7889/lobster/api-pool/
  curl -s http://127.0.0.1:8890/health
  curl -s http://127.0.0.1:8891/health
  curl -sL -o /dev/null -w "%{http_code}" http://127.0.0.1:7891/
'
```

## 基础设施

- 网关 Nginx（.cn vhost 完整目标配置）：`docs/operations/gateway-nginx-preview.md`
- ASR 用户词典纠偏：`docs/asr-correction-guide.md`
- preview 不部署 LangWatch/qdrant 等平台组件；LangWatch 只在 uat 业务服务器运行，但 preview 后端通过独立 `lobster-backend-preview` 项目上报，见 `docs/operations/langwatch.md`。
- preview 为抢占式实例且业务数据可丢弃，不配置自动备份；重要配置以本 runbook 可重放为准。
