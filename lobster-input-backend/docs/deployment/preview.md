# 后端部署说明 - preview

本文只描述 `lobster-input-backend` 后端服务在 preview（内测环境，2026-07 新建）的部署。服务器整体发布顺序、网关、数据库、Redis、跨服务联动与**从零重建 runbook** 见 `docs/operations/server-deploy-preview.md`。uat（公测环境）版本见 `docs/deployment/uat.md`。

> **preview 业务服务器是抢占式实例，随时可能被释放回收。** IP 只在下表集中定义；实例更换后只需替换本表与命令中的变量值，流程照跑。

## 拓扑（当前值）

| 角色 | 当前值 |
|---|---|
| 网关服务器（三环境共享） | `192.0.2.13` |
| preview 业务服务器公网 IP | `192.0.2.15` |
| preview 业务服务器私网 IP | `192.0.2.12` |
| preview API 域名 | `api.example.net` |

## 服务定位

| 项目 | 值 |
|---|---|
| 本地仓库 | `lobster-input-backend` |
| 本地同步源 | `lobster-input-backend/backend/` |
| 服务器目录 | `/opt/lobster-backend/` |
| systemd 服务 | `lobster-backend` |
| 监听端口 | `8000` |
| 健康检查 | `/health` |
| 外部路径 | `/lobster/api/v1/`、`/lobster/api/v2/`、`/lobster/health` |

`backend/` 目录才是部署源，不能把仓库根目录整体同步到 `/opt/lobster-backend/`，否则会产生多余的 `backend/` 子目录。业务服务器上的目录、端口、systemd 服务名与 uat 完全一致。

## .env 关键项

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

# LangWatch 平台不在 preview 部署，但 preview 后端仍上报到 uat 上的平台
LANGWATCH_ENABLED=true
LANGWATCH_ENDPOINT=http://192.0.2.11:5560
LANGWATCH_API_KEY=<lobster-backend-preview 项目 Key>
```

内部鉴权密钥 preview 独立生成，不与 uat 复用。LLM、ASR、Search API Key 由管理端 Provider 配置和号池端统一管理，后端 `.env` 不保存上游模型密钥。ASR 纠偏只依赖 MongoDB `hotwords` 用户词典集合，不需要额外向量服务。LangWatch/qdrant 平台组件不部署到 preview，但 preview 后端必须使用 `lobster-backend-preview` 项目的独立 Key，通过 uat 私网地址 `http://192.0.2.11:5560` 上报。

## 同步代码

preview 使用网关服务器作为代码中转站，中转目录用 `/opt/preview/` 前缀（与 uat 的 `/opt/lobster-*` 中转目录隔离），再由网关同步到 preview 业务服务器的 `/opt/lobster-backend/`。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@192.0.2.13"
PREVIEW_IP="192.0.2.15"   # 实例被释放后只改这里
SSH_OPT="-o StrictHostKeyChecking=yes"

# 第一跳：本地 → 网关（preview 专用中转目录）
rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='uploads/' --exclude='.venv' --exclude='venv' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-backend/backend/" "$GATEWAY_HOST:/opt/preview/lobster-backend/"

# 第二跳：网关 → preview 业务服务器
ssh $SSH_OPT "$GATEWAY_HOST" "
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='uploads/' --exclude='venv' \
    /opt/preview/lobster-backend/ root@$PREVIEW_IP:/opt/lobster-backend/
"
```

完整一键流程与五服务发布顺序见 `docs/operations/server-deploy-preview.md`。

## 首次部署 / 实例重建

抢占式实例被回收后须从零重建（基础软件、目录、.env、systemd、必要配置数据），完整 runbook 与一键重建脚本（`scripts/preview-server-bootstrap.sh`）见 `docs/operations/server-deploy-preview.md`。后端部分：

```bash
cd /opt/lobster-backend
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

## systemd

`/etc/systemd/system/lobster-backend.service`（与 uat 完全一致）：

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

```bash
systemctl daemon-reload
systemctl enable lobster-backend
systemctl restart lobster-backend
```

## 发布后验证

```bash
curl -s http://127.0.0.1:8000/health
curl -s https://api.example.net/lobster/health
tail -100 /var/log/lobster-backend.log
```

发布后必须执行系统配置初始化脚本，它是幂等的：

```bash
cd /opt/lobster-backend
PYTHONPATH=/opt/lobster-backend \
  /opt/lobster-backend/venv/bin/python3.12 scripts/init_system_config.py
```
