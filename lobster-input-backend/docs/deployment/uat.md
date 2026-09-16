# 后端部署说明 - uat

本文只描述 `lobster-input-backend` 后端服务在 uat（公测环境，原 "preview"）的部署。服务器整体发布顺序、网关、数据库、Redis 和跨服务联动见 `docs/operations/server-deploy-uat.md`。uat 业务服务器（`192.0.2.14`）为长期实例。

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

`backend/` 目录才是部署源，不能把仓库根目录整体同步到 `/opt/lobster-backend/`，否则会产生多余的 `backend/` 子目录。

## .env 关键项

```env
APP_ENV=uat
MONGODB_URI=mongodb://YOUR_DB_USER:YOUR_DB_PASSWORD@localhost:27017/?authSource=admin
REDIS_URL=redis://localhost:6379/0

# 验证码邮件：通过共享网关私网出口连接 AokSend，不使用网关公网 IP
AOKSEND_API_URL=http://192.0.2.16/index/api/send_email
AOKSEND_API_KEY=<保留服务器现有 AokSend Key>
YOUR_AOKSEND_API_KEY<保留服务器现有模板 ID>

API_POOL_URL=http://127.0.0.1:8889
API_POOL_INTERNAL_KEY=<与号池 INTERNAL_API_KEY 一致>
ADMIN_CONFIG_URL=http://127.0.0.1:8888
ADMIN_CONFIG_INTERNAL_KEY=<与管理端 PROVIDER_CONFIG_INTERNAL_KEY 一致>
PROVIDER_CONFIG_CACHE_TTL_SEC=600
INTERNAL_SIGNATURE_TOLERANCE_SEC=300

PAYMENT_SERVICE_URL=http://127.0.0.1:8890
PAYMENT_CALLBACK_INTERNAL_KEY=<与支付服务一致>
PAYMENT_CHECKOUT_PUBLIC_BASE_URL=https://payment.example.com/lobster

TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128,<网关内网 CIDR>
ASR_CORRECTION_ENABLED=true

LANGWATCH_ENABLED=true
LANGWATCH_ENDPOINT=http://192.0.2.11:5560
LANGWATCH_API_KEY=<lobster-backend-uat 项目 Key>
```

> 当前代码已在 `backend/app/core/config.py` 中支持 `APP_ENV=uat`。
> uat 的固定验证码通道仅在显式开启、配置 6 位验证码且邮箱命中白名单时生效；
> production 不在允许环境列表中。

LLM、ASR、Search API Key 由管理端 Provider 配置和号池端统一管理，后端 `.env` 不再保存上游模型密钥。ASR 纠偏只依赖 MongoDB `hotwords` 用户词典集合，不需要额外向量服务。LangWatch 平台只部署在 uat，但项目必须按环境隔离：uat 使用 `lobster-backend-uat`，preview 使用 `lobster-backend-preview`，两个项目 Key 不得复用。服务器上报统一走 uat 私网地址；公网域名只用于运维人员访问 Web UI。

## 同步代码

验证码邮件的私网转发配置、无发信探测、失败诊断及回滚见 [UAT 验证码邮件运维](../operations/email-delivery-uat.md)。不要把公网 `/health` 正常当作邮件供应商可用的证明。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@192.0.2.13"
SSH_OPT="-o StrictHostKeyChecking=yes"

rsync -az --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' \
  --exclude='.env' --exclude='uploads/' --exclude='.venv' --exclude='venv' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-backend/backend/" "$GATEWAY_HOST:/opt/lobster-backend/"
```

uat 当前使用网关服务器作为代码中转站（uat 中转目录 `/opt/lobster-backend/`；preview 环境走 `/opt/preview/` 前缀，互不冲突），再由网关服务器同步到业务服务器。完整一键流程见 `docs/operations/server-deploy-uat.md`。

## 首次部署

```bash
cd /opt/lobster-backend
/usr/local/bin/python3.12 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

## systemd

`/etc/systemd/system/lobster-backend.service`：

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
curl -s https://api.example.com/lobster/health
tail -100 /var/log/lobster-backend.log
```

发布后必须执行系统配置初始化脚本，它是幂等的：

```bash
cd /opt/lobster-backend
PYTHONPATH=/opt/lobster-backend \
  /opt/lobster-backend/venv/bin/python3.12 scripts/init_system_config.py
```
