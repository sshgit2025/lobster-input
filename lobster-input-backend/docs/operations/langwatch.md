# LangWatch 自托管部署与运维

LangWatch 是 LLM 可观测性平台，用于追踪和分析后端 AI 管道（LLM 调用、Agent trace）的运行数据。平台服务本体只部署一套，但 uat 与 preview 后端分别使用独立项目上报，禁止共用项目 API Key。

## 服务信息

| 项目 | 值 |
|---|---|
| 部署位置 | uat 业务服务器 `192.0.2.14`（LangWatch 只部署在 uat，不部署到 preview 内测环境） |
| 部署目录 | `/opt/langwatch/` |
| 数据目录 | `/opt/langwatch/data/`（宿主机持久化挂载） |
| 访问端口 | `5560`（仅绑定 uat 私网 IP `192.0.2.11`，由共享网关 Nginx 反代） |
| 外部访问 | `https://langwatch.example.com`（独立子域名，需 DNS A 记录指向 `192.0.2.13`） |
| 数据保留 | 30 天（ClickHouse TTL 由应用层自动维护） |
| 管理模式 | Docker Compose，配置文件 `/opt/langwatch/compose.yml` |
| uat 上报项目 | `lobster-backend-uat` |
| preview 上报项目 | `lobster-backend-preview` |

> “不部署到 preview”只表示 preview 业务服务器不运行 LangWatch Docker Compose、PostgreSQL、ClickHouse 等平台组件，不表示关闭 preview 后端上报。preview 后端必须访问 uat 上的统一入口，并使用 `lobster-backend-preview` 的独立 API Key。

`5560` 虽绑定私网 IP，云公网 IP 仍可能 NAT 到该端口。uat 必须同时启用 `langwatch-firewall.service`，只放行 uat 本机 `192.0.2.11`、preview `192.0.2.12` 和共享网关 `192.0.2.16` 的私网源地址。

## 目录结构

```
/opt/langwatch/
├── compose.yml          # Docker Compose 配置
├── .env                 # 生产密钥（不入 git）
└── data/                # 所有持久化数据
    ├── postgres/        # PostgreSQL 数据
    ├── redis/           # Redis 数据
    ├── clickhouse/      # ClickHouse Trace 数据（主要存储）
    └── objects/         # 文件对象存储（数据集等）
```

## 服务组成

| 容器 | 镜像 | 端口 | 说明 |
|---|---|---|---|
| `app` | `langwatch/langwatch:latest` | 5560 | 主应用（Web UI + API） |
| `workers` | `langwatch/langwatch:latest` | — | 后台任务处理 |
| `langwatch_nlp` | `langwatch/langwatch_nlp:latest` | 5561 | NLP 分析（Topic 聚类等） |
| `postgres` | `postgres:16` | — | 控制面数据库 |
| `redis` | `redis:alpine` | — | 任务队列与缓存 |
| `clickhouse` | `langwatch/clickhouse-serverless:0.2.0` | 8123 | Trace 分析存储 |

## 首次部署

### 前置要求

- Docker 24+（已安装）
- Docker Compose v2（已安装于 `/usr/local/lib/docker/cli-plugins/docker-compose`）

### 初始化步骤

```bash
# 1. 创建目录（首次已执行）
mkdir -p /opt/langwatch/data/{postgres,redis,clickhouse,objects}

# 2. 上传 compose.yml（从本地仓库）
sshpass -p 'YOUR_BUSINESS_PASSWORD' scp -o "StrictHostKeyChecking yes" -o "PreferredAuthentications password" -o "PubkeyAuthentication no" \
  lobster-input-backend/docker/langwatch/compose.yml \
  root@192.0.2.14:/opt/langwatch/compose.yml

# 2.1 上传并启用 5560 私网访问控制
sshpass -p 'YOUR_BUSINESS_PASSWORD' scp -o "StrictHostKeyChecking yes" -o "PreferredAuthentications password" -o "PubkeyAuthentication no" \
  docker/langwatch/langwatch-firewall.service \
  root@192.0.2.14:/etc/systemd/system/
sshpass -p 'YOUR_BUSINESS_PASSWORD' ssh -o "StrictHostKeyChecking yes" -o "PreferredAuthentications password" -o "PubkeyAuthentication no" \
  root@192.0.2.14 \
  'systemctl daemon-reload && systemctl enable --now langwatch-firewall.service'

# 3. 在服务器上创建 .env（首次已执行，密钥自动生成）
# ssh 进入服务器后，密钥存储在 /opt/langwatch/.env，请妥善保管

# 4. 拉取镜像并启动
cd /opt/langwatch
docker compose pull
docker compose up -d

# 5. 检查状态
docker compose ps
docker compose logs -f app --tail=50
```

### 首次登录

**前置条件：** 需在 DNS 控制台为 `langwatch.example.com` 添加 A 记录指向 `192.0.2.13`。

LangWatch 启动后访问 `https://langwatch.example.com`，使用邮箱密码注册第一个管理员账号，然后：

1. 进入 Settings → Projects，分别创建 `lobster-backend-uat` 和 `lobster-backend-preview`。
2. 分别获取两个项目的 API Key，禁止交叉使用或复用。
3. 将对应 API Key 填入两台业务服务器的后端 `.env`。

uat `/opt/lobster-backend/.env`：

```env
LANGWATCH_API_KEY=<lobster-backend-uat 项目 Key>
LANGWATCH_ENABLED=true
LANGWATCH_ENDPOINT=http://192.0.2.11:5560
```

preview `/opt/lobster-backend/.env`：

```env
LANGWATCH_API_KEY=<lobster-backend-preview 项目 Key>
LANGWATCH_ENABLED=true
LANGWATCH_ENDPOINT=http://192.0.2.11:5560
```

4. 分别在两台业务服务器执行 `systemctl restart lobster-backend`。

项目归属由 API Key 决定，后端没有 `LANGWATCH_PROJECT_NAME` 配置项；仅修改本地服务名或增加未被代码读取的环境变量不能实现项目隔离。

## 日常运维

### 查看状态

```bash
cd /opt/langwatch
docker compose ps
docker compose logs -f app --tail=100
docker compose logs -f workers --tail=50
```

### 启动 / 停止 / 重启

```bash
cd /opt/langwatch
docker compose up -d          # 启动
docker compose down           # 停止（数据保留）
docker compose restart app    # 重启单个服务
```

### 更新版本

```bash
cd /opt/langwatch
docker compose pull           # 拉取最新镜像
docker compose up -d          # 滚动更新（数据不丢失）
```

### 查看数据占用

```bash
du -sh /opt/langwatch/data/clickhouse/    # ClickHouse（最大，存 Trace）
du -sh /opt/langwatch/data/postgres/      # PostgreSQL（配置、用户）
du -sh /opt/langwatch/data/redis/         # Redis（队列、缓存）
df -h /opt/langwatch/                     # 磁盘总览
```

## 数据保留策略

ClickHouse TTL 由应用层在启动时自动设置为 30 天，无需手动操作。相关环境变量（已在 `.env` 中配置）：

```env
TIERED_STORAGE_DEFAULT_HOT_DAYS=30
TIERED_EVENT_LOG_TABLE_HOT_DAYS=30
TIERED_STORED_SPANS_TABLE_HOT_DAYS=30
TIERED_TRACE_SUMMARIES_TABLE_HOT_DAYS=30
```

ClickHouse 会自动后台清理 30 天前的数据，写入始终优先于清理，**不会因清理操作阻塞 Trace 写入**。

## 后端接入说明

后端 `app/main.py` 在启动时读取以下配置初始化 LangWatch SDK：

| 环境变量 | 说明 |
|---|---|
| `LANGWATCH_ENABLED` | `true` 启用，`false` 完全跳过 |
| `LANGWATCH_API_KEY` | 当前环境对应的 LangWatch 项目 API Key；uat/preview 必须不同 |
| `LANGWATCH_ENDPOINT` | 服务器上报地址；uat/preview 都使用私网 `http://192.0.2.11:5560` |

SDK 初始化是**非阻塞**的，失败或未配置时仅打印日志，不影响后端正常启动和业务处理。

当前项目命名规范：

| 服务与环境 | LangWatch 项目名 |
|---|---|
| 后端 uat | `lobster-backend-uat` |
| 后端 preview | `lobster-backend-preview` |

后续其他服务接入时统一采用 `<service>-uat`、`<service>-preview`，每个项目使用独立 API Key。历史 trace 无需迁移；环境拆分后只要求新数据进入正确项目。

## API Key 管理

| 环境 | 项目名 | 项目 ID | 正式 Key 存放位置 |
|---|---|---|---|
| uat | `lobster-backend-uat` | `project_tNjcVVlv6xtdOlD9GRdoY` | uat `192.0.2.14:/opt/lobster-backend/.env` |
| preview | `lobster-backend-preview` | `project_jY3su74nHNcaVN0k8J2nz` | preview `192.0.2.15:/opt/lobster-backend/.env` |

- 两台服务器的 `.env` 必须设为 `chmod 600`，由 `root` 持有。项目 Key 以 `sk-lw-` 开头，不要复用。
- LangWatch 项目与 Key 的中央数据保存在 uat `/opt/langwatch/data/postgres/`；宿主机备份和数据库备份必须覆盖该目录或 `Project` 表。
- 新建或重建环境时，从 LangWatch Settings → Projects 确认项目名和项目 ID，取得该项目 Key 后写入对应服务器 `.env`，然后执行 `systemctl restart lobster-backend`。
- 轮换 Key 时，先在 LangWatch 创建或确认新 Key，备份目标 `.env`，替换并重启单个环境，发送一条测试 trace 验证项目归属，最后再废弃旧 Key。不要同时轮换两个环境。
- 仓库文档要保留项目名、项目 ID、Key 的存放位置、配置模板和轮换流程。正式 Key 值以服务器 `.env` 和 LangWatch 数据库为准，避免文档副本在轮换后失效。

2026-07-21 环境拆分前的 `Project` 表备份保存在 uat `/opt/langwatch/project-backup-before-env-split-20260721110047.sql`（`chmod 600`）。两台后端切换私网 endpoint 前的 `.env` 备份为各自服务器上的 `/opt/lobster-backend/.env.bak-langwatch-private-20260721`。

### 不显示 Key 明文的归属校验

运维核对时只比较 Key 摘要，不要把 Key 明文输出到终端历史或工单。可分别在业务服务器执行：

```bash
set -a
. /opt/lobster-backend/.env
set +a
printf %s "$LANGWATCH_API_KEY" | sha256sum
```

在 uat 的 LangWatch PostgreSQL 中计算指定项目 Key 的同类摘要（不输出明文）：

```bash
PROJECT_NAME=lobster-backend-uat  # 或 lobster-backend-preview
project_key=$(docker exec langwatch-postgres-1 psql -U prisma -d mydb -Atc \
  "SELECT \"apiKey\" FROM mydb.\"Project\" WHERE name='${PROJECT_NAME}';")
printf %s "$project_key" | sha256sum
unset project_key
```

两个摘要一致表示该服务器使用了指定项目 Key。摘要校验不代替实际 trace 上报验证。

## 故障排查

### LangWatch Web UI 无法访问

```bash
# 检查容器状态
cd /opt/langwatch && docker compose ps
# 检查 5560 端口监听
ss -tlnp | grep 5560
# 在 uat 检查私网监听
curl -s http://192.0.2.11:5560/api/health || curl -sI http://192.0.2.11:5560
# 检查持久化访问控制
systemctl is-active langwatch-firewall.service
iptables -S DOCKER-USER | grep 5560
```

### Trace 数据不显示

```bash
# 检查后端 LangWatch 初始化日志
grep -i langwatch /var/log/lobster-backend.log | tail -20
# 检查 workers 是否正常
cd /opt/langwatch && docker compose logs workers --tail=50
```

同时检查两台业务服务器的启动日志都包含：

```text
LangWatch initialized, endpoint=http://192.0.2.11:5560
```

若显示 `LangWatch disabled or API key not set`，说明该环境没有完成接入。遇到数据串环境时，优先核对 `.env` 中 API Key 是否属于正确项目，不要只检查 endpoint；两套环境本来就共用同一个 endpoint。

### workers 的 `system.backup_log` 告警

当前 `langwatch/clickhouse-serverless:0.2.0` 镜像不提供 `system.backup_log` 系统表，workers 的备份指标采集会周期性记录 `Unknown table expression identifier 'system.backup_log'`。该日志自现有部署初期就存在，只影响备份指标查询，不代表 Trace 写入失败。排查时应以测试 trace 是否进入正确 `TenantId`、`stored_spans` 是否有新记录为准，不要因此单条指标告警误判为 LangWatch 整体故障。

### ClickHouse 内存超限

ClickHouse 容器限制 2GB 内存，如遇 OOM 可适当调高 `compose.yml` 中的 `memory` 限制，但需确认服务器剩余内存充足。

## 第三方许可

使用 LangWatch 前请核对所部署版本的官方许可证和功能范围。需要商业功能时，通过供应商的正式渠道取得适用授权，并使用官方支持的配置方式。项目源码许可证不授予第三方商业功能的使用权。

## 备份说明

部署者应按实际持久化目录制定加密备份、访问控制和恢复验证方案。以下仅为数据目录备份示例；环境配置与授权材料另行安全保管，不得纳入源码仓库：

```bash
tar czf langwatch-backup-$(date +%Y%m%d).tar.gz /opt/langwatch/data/
```
