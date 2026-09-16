# 服务器整体部署与一键发布 - prod

本文是 prod 环境服务器服务的完整发布模板，只覆盖服务器服务，不包含客户端在线更新发布。prod 流程与 uat 保持同款；当前没有正式 prod 服务器，因此 IP、域名、中间件连接和私网地址均留空。

prod 与 uat、preview 三环境共享网关服务器，但使用不同的 Nginx `server_name`、证书和转发目标。官网只有一个，对外描述可与 uat 保持一致。

## 目标拓扑

| 角色 | prod 值 |
|---|---|
| 共享网关服务器 | `<GATEWAY_PUBLIC_IP>` |
| prod 业务服务器公网 IP | `<PROD_BUSINESS_PUBLIC_IP>` |
| prod 业务服务器私网 IP | `<PROD_BUSINESS_PRIVATE_IP>` |
| prod 主域名 | `<PROD_MAIN_DOMAIN>` |
| prod API 域名 | `<PROD_API_DOMAIN>` |
| prod 支付域名 | `<PROD_PAYMENT_DOMAIN>` |
| MongoDB | `<PROD_MONGODB_URI>` |
| Redis | `<PROD_REDIS_URL>` |

## 发布服务清单

| 服务 | 仓库文档 | 服务器目录 | 端口 |
|---|---|---|---|
| 后端 | `lobster-input-backend/docs/deployment/prod.md` | `/opt/lobster-backend/` | 8000 |
| 管理端 | `lobster-input-admin/docs/deployment/prod.md` | `/opt/lobster-admin/` | 8888 |
| 号池端 | `lobster-input-api-manage/docs/deployment/prod.md` | `/opt/lobster-api-pool/` | 8889 |
| 支付端 | `lobster-input-payment/docs/deployment/prod.md` | `/opt/lobster-payment/` | 8890 |
| 官网 | `lobster-input-landing/docs/deployment/prod.md` | `/opt/lobster-landing/` | 9010 |

## 一键发布全部服务器服务

默认写法假设本机、共享网关服务器、prod 业务服务器之间已配置 SSH key。若 prod 首次部署阶段仍使用密码登录，把 `ssh $SSH_OPT` 和 `rsync -e "ssh $SSH_OPT"` 替换为对应 `sshpass` 命令，密码只保存在发布机或密钥管理工具中，不写入仓库。

```bash
set -euo pipefail

ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@<GATEWAY_PUBLIC_IP>"
BUSINESS_HOST="root@<PROD_BUSINESS_PUBLIC_IP>"
SSH_OPT="-o StrictHostKeyChecking=yes"

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
  "$ROOT/lobster-input-backend/backend/" "$GATEWAY_HOST:/opt/prod/lobster-backend/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-admin/" "$GATEWAY_HOST:/opt/prod/lobster-admin/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-api-manage/" "$GATEWAY_HOST:/opt/prod/lobster-api-pool/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-payment/" "$GATEWAY_HOST:/opt/prod/lobster-payment/"

rsync -az --delete --exclude='.git' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-landing/" "$GATEWAY_HOST:/opt/prod/lobster-landing/"

ssh $SSH_OPT "$GATEWAY_HOST" "
  set -euo pipefail
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='uploads/' --exclude='venv' /opt/prod/lobster-backend/ $BUSINESS_HOST:/opt/lobster-backend/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/prod/lobster-admin/ $BUSINESS_HOST:/opt/lobster-admin/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/prod/lobster-api-pool/ $BUSINESS_HOST:/opt/lobster-api-pool/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/prod/lobster-payment/ $BUSINESS_HOST:/opt/lobster-payment/
  rsync -az --delete --exclude='.git' /opt/prod/lobster-landing/ $BUSINESS_HOST:/opt/lobster-landing/
"

ssh $SSH_OPT "$BUSINESS_HOST" '
  set -euo pipefail
  find /opt/lobster-backend /opt/lobster-admin /opt/lobster-api-pool /opt/lobster-payment -name "*.pyc" -delete 2>/dev/null || true
  find /opt/lobster-backend /opt/lobster-admin /opt/lobster-api-pool /opt/lobster-payment -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true

  cd /opt/lobster-backend
  PYTHONPATH=/opt/lobster-backend /opt/lobster-backend/venv/bin/python3.12 scripts/init_system_config.py

  systemctl restart lobster-api-pool
  sleep 3
  systemctl restart lobster-admin
  sleep 3
  systemctl restart lobster-payment
  sleep 3
  systemctl restart lobster-backend
  if systemctl list-unit-files | grep -q "^lobster-landing.service"; then
    systemctl restart lobster-landing
  fi
'
```

## 发布后验证

```bash
curl -s https://<PROD_API_DOMAIN>/lobster/health
curl -sL -o /dev/null -w '%{http_code}\n' https://<PROD_MAIN_DOMAIN>/lobster/admin/login
curl -s https://<PROD_MAIN_DOMAIN>/lobster/api-pool/health
curl -s https://<PROD_MAIN_DOMAIN>/lobster/payment/health
curl -sI https://example.com/
```

## prod 上线前必须确认

- prod Nginx 配置不能复用 uat/preview 域名，转发目标必须是 prod 业务服务器。
- prod `.env` 内部鉴权密钥与 uat/preview 分离。
- prod MongoDB、Redis 数据与 uat/preview 分离，除非明确执行迁移。
- prod 支付渠道配置、Webhook、Return URL 指向 prod 域名。
- prod 客户端 API 地址由各客户端发版文档单独控制，不在本文一键发布范围内。
