# 服务器整体部署与一键发布 - uat

本文是 uat（公测环境，原文档中的 "preview"）服务器服务的完整发布流程，只覆盖服务器服务，不包含 Mac、Windows、Android、iOS 客户端在线更新发布。

uat 业务服务器为**长期实例**，不会被回收。新建内测环境 preview（抢占式实例）的发布与重建流程见 `docs/operations/server-deploy-preview.md`。

单服务细节分散在各自仓库：

| 服务 | 仓库文档 | 服务器目录 | 端口 |
|---|---|---|---|
| 后端 | `lobster-input-backend/docs/deployment/uat.md` | `/opt/lobster-backend/` | 8000 |
| 管理端 API | `lobster-input-admin/docs/deployment/uat.md` | `/opt/lobster-admin/backend/` | 8888 |
| 管理端前端 | `lobster-input-admin/docs/deployment/uat.md` | `/opt/lobster-admin/frontend/` | 7888 |
| 号池端 API | `lobster-input-api-manage/docs/deployment/uat.md` | `/opt/lobster-api-pool/backend/` | 8889 |
| 号池端前端 | `lobster-input-api-manage/docs/deployment/uat.md` | `/opt/lobster-api-pool/frontend/` | 7889 |
| 支付端 | `lobster-input-payment/docs/deployment/uat.md` | `/opt/lobster-payment/` | 8890 |
| 官网后端 API | `lobster-input-landing/docs/deployment/uat.md` | `/opt/lobster-landing/backend/` | 8891 |
| 官网前端 SPA | `lobster-input-landing/docs/deployment/uat.md` | `/opt/lobster-landing/frontend/` | 7891 |
| LangWatch 平台 | `lobster-input-backend/docs/operations/langwatch.md` | `/opt/langwatch/` | 5560（私网） |

## 当前拓扑

| 角色 | 当前 uat 值 | 说明 |
|---|---|---|
| 网关服务器 | `192.0.2.13` | 运行 Nginx，作为 uat/preview/prod 三环境共享入口服务器；各环境使用不同域名配置 |
| uat 业务服务器 | `192.0.2.14` | 长期实例，运行所有业务服务、MongoDB、Redis |
| uat 业务私网 IP | `192.0.2.11` | Nginx 转发和备份优先使用私网 IP |
| uat 主域名 | `example.com` | 官网、管理端、号池、支付页面 |
| uat API 域名 | `api.example.com` | 客户端 API 与 WebSocket |
| uat 支付域名 | `payment.example.com` | 浏览器支付中转页 |

网关服务器描述保持中性：它不是"uat 服务器"，而是 uat/preview/prod 三环境共享的网关入口。环境隔离体现在不同 `server_name` 和转发目标。

## LangWatch 环境隔离

- LangWatch 平台只在 uat 业务服务器 `/opt/langwatch/` 部署一套，preview 不部署平台组件。
- uat 后端使用 `lobster-backend-uat` 项目，preview 后端使用 `lobster-backend-preview` 项目，API Key 必须不同。
- 两台业务服务器都使用 `LANGWATCH_ENDPOINT=http://192.0.2.11:5560` 私网上报；`https://langwatch.example.com` 只是 Web 运维入口。
- 正式 Key 保存在各自 `/opt/lobster-backend/.env`（`root:root`、`chmod 600`）。项目 ID、Key 校验、轮换和备份流程见 `docs/operations/langwatch.md`。
- uat 必须启用 `langwatch-firewall.service`，不允许通过 uat 公网 IP 直连 `5560`。

## 发布前检查

UAT 验证码邮件使用共享网关的私网专用出口：`AOKSEND_API_URL=http://192.0.2.16/index/api/send_email`。只在 UAT `.env` 设置该覆盖值，保留现有 `AOKSEND_API_KEY` 和 `AOKSEND_TEMPLATE_ID`；Preview/production 不随本次修复改动。网关配置和验证步骤见 [验证码邮件运维](email-delivery-uat.md)。

```bash
ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"

for repo in \
  lobster-input-backend \
  lobster-input-admin \
  lobster-input-api-manage \
  lobster-input-payment \
  lobster-input-landing
do
  git -C "$ROOT/$repo" status --short --branch
done
```

发布前应确认：

- 每个仓库当前分支就是要发布的分支。
- 工作区没有未预期改动。
- `.env` 不随代码同步，由服务器本地保留。
- 后端、管理端、号池端、支付端使用同一套内部鉴权密钥约定。
- uat/preview 后端的 LangWatch API Key 分别归属正确项目，两边 `LANGWATCH_ENDPOINT` 都是 uat 私网地址。
- UAT 邮件私网转发的空参数探测返回 AokSend `code=40001`，并在需要时通过团队测试邮箱验证真实发码，不能仅检查 `/health`。

## 一键发布全部服务器服务

在本地 Mac 执行。脚本会先同步到网关服务器的 `/opt/lobster-*` 目录（uat 专用中转目录；preview 环境使用 `/opt/preview/lobster-*` 前缀，两者不冲突），再由网关服务器同步到 uat 业务服务器并按顺序重启服务。

uat 业务服务器当前允许 root 密码登录；如果本机没有 SSH key，使用 `sshpass` 执行非交互命令：

```bash
BUSINESS_HOST="root@192.0.2.14"
BUSINESS_PASSWORD='YOUR_BUSINESS_PASSWORD'
SSH_OPT="-o StrictHostKeyChecking=yes -o PreferredAuthentications=password -o PubkeyAuthentication=no"

sshpass -p "$BUSINESS_PASSWORD" ssh $SSH_OPT "$BUSINESS_HOST" 'hostname; systemctl status lobster-backend --no-pager'
```

默认发布脚本仍优先展示 SSH key 写法。若当前机器使用密码登录，把 `ssh $SSH_OPT` 和 `rsync -e "ssh $SSH_OPT"` 替换为对应 `sshpass -p "$BUSINESS_PASSWORD" ssh $SSH_OPT` / `rsync -e "sshpass -p \"$BUSINESS_PASSWORD\" ssh $SSH_OPT"`。uat 为长期实例，密码登录只是历史遗留，后续建议改用 SSH key / 密钥保管库。

```bash
set -euo pipefail

ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
GATEWAY_HOST="root@192.0.2.13"
BUSINESS_HOST="root@192.0.2.14"
BUSINESS_IP="192.0.2.14"
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
  "$ROOT/lobster-input-backend/backend/" "$GATEWAY_HOST:/opt/lobster-backend/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-admin/" "$GATEWAY_HOST:/opt/lobster-admin/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-api-manage/" "$GATEWAY_HOST:/opt/lobster-api-pool/"

rsync -az "${COMMON_EXCLUDES[@]}" \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-payment/" "$GATEWAY_HOST:/opt/lobster-payment/"

# 官网已前后端分离：排除服务器本地产物（venv/node_modules/dist/.env），不要 --delete
rsync -az "${COMMON_EXCLUDES[@]}" \
  --exclude='frontend/node_modules' --exclude='frontend/dist' --exclude='frontend/logs' \
  -e "ssh $SSH_OPT" \
  "$ROOT/lobster-input-landing/" "$GATEWAY_HOST:/opt/lobster-landing/"

ssh $SSH_OPT "$GATEWAY_HOST" "
  set -euo pipefail
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='uploads/' --exclude='venv' /opt/lobster-backend/ $BUSINESS_HOST:/opt/lobster-backend/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/lobster-admin/ $BUSINESS_HOST:/opt/lobster-admin/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/lobster-api-pool/ $BUSINESS_HOST:/opt/lobster-api-pool/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' /opt/lobster-payment/ $BUSINESS_HOST:/opt/lobster-payment/
  rsync -az --exclude='__pycache__' --exclude='*.pyc' --exclude='.env' --exclude='venv' --exclude='frontend/node_modules' --exclude='frontend/dist' /opt/lobster-landing/ $BUSINESS_HOST:/opt/lobster-landing/
"

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
curl -s https://api.example.com/lobster/health
curl -sL -o /dev/null -w '%{http_code}\n' https://example.com/lobster/admin/login
curl -s https://example.com/lobster/api-pool/health
curl -s https://example.com/lobster/payment/health
curl -sI https://example.com/
```

业务服务器本机验证：

```bash
ssh root@192.0.2.14 '
  systemctl status lobster-api-pool lobster-api-pool-frontend lobster-admin lobster-admin-frontend lobster-payment lobster-backend --no-pager
  curl -s http://127.0.0.1:8000/health
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8888/api/v1/alerts/latest-pending
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7888/lobster/admin/
  curl -s http://127.0.0.1:8889/health
  curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7889/lobster/api-pool/
  curl -s http://127.0.0.1:8890/health
'
```

## 基础设施和恢复

- 网关 Nginx（.com vhost）：`docs/operations/gateway-nginx-uat.md`
- ASR 用户词典纠偏：`docs/asr-correction-guide.md`
- uat 为长期实例，一般无需重建；若确需迁移服务器：重建基础软件、恢复 MongoDB/Redis 备份、更新网关 Nginx 的业务私网 IP（可参考 `server-deploy-preview.md` 的从零重建 runbook，流程同构）。

uat 当前备份定时任务必须保持暂停，恢复自动备份前需重新评估数据丢失窗口和磁盘空间策略。
