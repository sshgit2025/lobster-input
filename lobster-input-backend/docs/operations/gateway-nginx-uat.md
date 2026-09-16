# 共享网关 Nginx 配置 - uat（.com vhost）

网关服务器承载 uat、preview、prod 三个环境的入口配置，三环境共享同一台网关（`192.0.2.13`）。不要把它描述成某一个环境的专属服务器；环境隔离体现在不同 `server_name`、日志和 `proxy_pass` 目标，uat 与 preview 共用同一张 `.com/.cn` 通配证书。

## uat 域名

| 用途 | 域名 |
|---|---|
| 官网、管理端、号池、支付页面 | `example.com`、`www.example.com` |
| 客户端 API / WebSocket | `api.example.com` |
| 支付中转 | `payment.example.com` |

## uat 转发目标

| 服务 | 目标 |
|---|---|
| 后端 API | `http://192.0.2.11:8000` |
| 管理端 API | `http://192.0.2.11:8888` |
| 管理端前端 | `http://192.0.2.11:7888` |
| 号池管理端 API | `http://192.0.2.11:8889` |
| 号池管理端前端 | `http://192.0.2.11:7889` |
| 支付服务 | `http://192.0.2.11:8890` |
| 官网后端 API | `http://192.0.2.11:8891` |
| 官网前端 SPA | `http://192.0.2.11:7891` |
| LangWatch 可观测性 | `http://192.0.2.11:5560`（独立子域名 `langwatch.example.com`，见 `langwatch.conf`） |

更换业务服务器时，只改上表私网 IP，再执行 `nginx -t && nginx -s reload`。

## Nginx 配置

宝塔面板 vhost 配置文件路径（uat / .com 域名入口文件；历史上曾用过 `lobster-input-preview.conf` 的名字，实际生效文件是下面这个）：

```text
/www/server/panel/vhost/nginx/lobster-input.conf
```

> **注意环境边界**：`.cn` 系列域名（`lobster-input-cn.conf`、`payment-lobster-input-cn.conf`）
> 现在属于 preview（内测环境），转发目标是 preview 业务服务器，完整目标配置见
> `docs/operations/gateway-nginx-preview.md`。改 uat 配置时不要顺手改 .cn vhost，反之亦然。

> **官网前后端分离后的两处改动**：官网由静态站点重构为
> 前后端分离后，根 `/` 不再转发到 9010，而是：① 新增 `^~ /lobster/site/api/`（rewrite 掉
> `/lobster/site` 前缀后转发到官网后端 `8891`）；② 根 `/` 改为转发到官网前端 SPA `7891`。
> 其余 `/lobster/api`、`/lobster/admin`、`/lobster/api-pool`、`/lobster/payment` 等 location 一律不动。
> （preview 的 `.cn` vhost 结构与本文完全对齐，同样包含这两处，见 `gateway-nginx-preview.md`。）

```nginx
server {
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name example.com www.example.com api.example.com 192.0.2.13;

    # SSL 证书（由宝塔申请，路径保持不变）
    ssl_certificate     /www/server/panel/vhost/cert/www.example.com/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/www.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # HTTP 自动跳转 HTTPS
    if ($scheme = http) {
        return 301 https://$host$request_uri;
    }

    client_max_body_size 50m;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;
    proxy_connect_timeout 10s;

    # Let's Encrypt 证书续签验证路径（本地响应，不转发）
    location /.well-known/acme-challenge/ {
        root /www/wwwroot/www.example.com;
        try_files $uri =404;
    }

    # 后端 API（含 WebSocket 支持）
    location ^~ /lobster/api/v1/ {
        proxy_pass http://192.0.2.11:8000/api/v1/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }

    location ^~ /lobster/api/v2/ {
        proxy_pass http://192.0.2.11:8000/api/v2/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_buffering off;
    }

    location = /lobster/health {
        proxy_pass http://192.0.2.11:8000/health;
        proxy_set_header Host $host;
    }

    # 支付服务（支付平台回调写路径，必须由服务校验 X-API-Key + HMAC 签名）
    location ^~ /lobster/payment {
        rewrite ^/lobster/payment(/.*)$ $1 break;
        rewrite ^/lobster/payment$ / break;
        proxy_pass http://192.0.2.11:8890;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 管理端 API（前后端分离：API 走后端 8888）
    location ^~ /lobster/admin/api/ {
        rewrite ^/lobster/admin(/.*)$ $1 break;
        proxy_pass http://192.0.2.11:8888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 管理端前端 SPA（Vue，端口 7888）
    location ^~ /lobster/admin/ {
        proxy_pass http://192.0.2.11:7888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 号池屏蔽外部直接访问 pool 接口
    location ^~ /lobster/api-pool/api/v1/pool {
        return 403;
    }

    # 号池健康检查走后端
    location = /lobster/api-pool/health {
        rewrite ^/lobster/api-pool(/.*)$ $1 break;
        proxy_pass http://192.0.2.11:8889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    # 号池 API
    location ^~ /lobster/api-pool/api/ {
        rewrite ^/lobster/api-pool(/.*)$ $1 break;
        proxy_pass http://192.0.2.11:8889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 号池前端 SPA（Vue，端口 7889）
    location ^~ /lobster/api-pool/ {
        proxy_pass http://192.0.2.11:7889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /lobster {
        default_type application/json;
        return 200 '{"service":"lobster-input","env":"uat","status":"running"}';
    }

    # 官网后端 API（前后端分离：API 走后端 8891，Nginx rewrite 掉 /lobster/site 前缀）
    location ^~ /lobster/site/api/ {
        rewrite ^/lobster/site(/.*)$ $1 break;
        proxy_pass http://192.0.2.11:8891;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 根路径转发到官网前端 SPA（7891 端口）
    location / {
        proxy_pass http://192.0.2.11:7891/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    access_log  /www/wwwlogs/lobster-input.log;
    error_log   /www/wwwlogs/lobster-input.error.log;
}
```

支付中转域名使用独立 vhost，避免未匹配的 `payment.example.com` 请求落到其它默认站点。支付中转页由后端 `lobster-input-backend/backend/app/api/v1/payments.py` 提供，外部路径是：

```text
https://payment.example.com/lobster/api/v1/payments/checkout-intents/{intent_id}
```

`/auth/signin` 不是 Lobster 支付中转页接口；该路径通常来自 LangWatch/NextAuth 登录页。支付域名下除支付中转页和健康检查外不应转发到官网或 LangWatch。

配置文件：

```text
/www/server/panel/vhost/nginx/payment-lobster-input.conf
```

```nginx
server {
    listen 80;
    server_name payment.example.com;

    location /.well-known/acme-challenge/ {
        root /www/wwwroot/www.example.com;
        try_files $uri =404;
    }

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name payment.example.com;

    ssl_certificate     /www/server/panel/vhost/cert/www.example.com/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/www.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    client_max_body_size 10m;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;
    proxy_connect_timeout 10s;

    location ^~ /lobster/api/v1/payments/ {
        proxy_pass http://192.0.2.11:8000/api/v1/payments/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Prefix /lobster;
    }

    location = /lobster {
        default_type application/json;
        return 200 '{"service":"lobster-payment-checkout","env":"uat","status":"running"}';
    }

    location = /lobster/health {
        proxy_pass http://192.0.2.11:8000/health;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }

    location / {
        default_type application/json;
        return 404 '{"detail":"payment checkout route not found"}';
    }

    access_log  /www/wwwlogs/payment-lobster-input.log;
    error_log   /www/wwwlogs/payment-lobster-input.error.log;
}
```

## 验证

```bash
nginx -t && nginx -s reload
curl -s https://api.example.com/lobster/health
curl -s https://payment.example.com/lobster/health
curl -s https://payment.example.com/lobster/api/v1/payments/checkout-intents/not-exist | head
curl -s https://payment.example.com/auth/signin
curl -sI https://example.com/
# LangWatch 可达性检查（DNS 解析到位后）
curl -sI https://langwatch.example.com/
```

## 验证码邮件私网出口

2026-08-27 新增独立 vhost `/www/server/panel/vhost/nginx/lobster-mail-relay.conf`，源码在 `docker/nginx/lobster-mail-relay.conf`。它复用 80 端口，精确匹配 `Host: 192.0.2.16`，仅允许 UAT 私网源 `192.0.2.11` 对 `/index/api/send_email` 发起 POST，再经校验证书的 HTTPS 访问 AokSend。它不是开放代理，不属于 `.com/.cn` 对外业务路由；公网来源即使伪造 Host / X-Forwarded-For 也不能发信。

不需要新增 `8003` 端口或相应安全组/防火墙规则。完整部署、探测和回滚见 [UAT 验证码邮件运维](email-delivery-uat.md)。

## 通配证书自动续签与故障预防

共享网关使用同一张 Let's Encrypt 通配证书，覆盖以下名称：

```text
*.example.com
*.example.net
example.com
example.net
```

证书由宝塔面板 ACME 客户端管理，通配域名必须通过阿里云 DNS API 完成
`dns-01` 校验，不能改成只枚举当前已有子域名的普通证书。Nginx 当前统一引用：

```text
/www/server/panel/vhost/cert/www.example.com/fullchain.pem
/www/server/panel/vhost/cert/www.example.com/privkey.pem
```

### 保存 DNS API 凭据后的强制检查

- `AccessKey` 和 `SecretKey` 前后不得包含空格、换行或引号。宝塔 11.7.0
  保存凭据时不会自动清理首尾空白，空白会参与 HMAC 计算并导致
  `SignatureDoesNotMatch`。
- 保存后必须在宝塔 DNS API 页面执行一次读取/测试，确认阿里云
  `DescribeDomainRecords` 返回成功；不能等到证书进入续签窗口后才验证。
- 使用专用 RAM 用户和最小权限，只授权目标域名所需的
  `DescribeDomainRecords`、`AddDomainRecord`、`DeleteDomainRecord` 等 DNS
  记录操作，并限制 AccessKey 的来源 IP。

宝塔通常只在证书剩余约 30 天时真正发起续签。计划任务每天显示执行完成，
不等于证书续签成功，必须以日志中的 `续签成功`、证书有效期和公网实际证书
三项结果为准。

### 手工续签与验证

在共享网关执行：

```bash
# 先备份证书和 DNS 凭据配置
cp -a /www/server/panel/config/dns_mager.conf \
  /www/server/panel/config/dns_mager.conf.bak-$(date +%Y%m%d%H%M%S)
cp -a /www/server/panel/vhost/cert/www.example.com \
  /www/server/panel/vhost/cert/www.example.com.bak-$(date +%Y%m%d%H%M%S)

# 手工触发宝塔 ACME 续签；成功日志必须包含“续签成功”
/www/server/cron/3ab48c27ec99cb9787749c362afae517 start

# 检查磁盘证书和 Nginx 配置
openssl x509 \
  -in /www/server/panel/vhost/cert/www.example.com/fullchain.pem \
  -noout -serial -dates -ext subjectAltName
nginx -t && systemctl reload nginx

# 检查公网实际加载的证书
echo | openssl s_client \
  -servername api.example.com \
  -connect api.example.com:443 2>/dev/null \
  | openssl x509 -noout -serial -dates -ext subjectAltName
curl -fsS https://api.example.com/lobster/health
```

### 监控要求

- 在宝塔“设置 → 告警设置”先配置实际使用的通知通道，再为证书添加
  30 天、15 天、7 天三级到期告警。
- 为 `https://api.example.com/lobster/health` 配置独立的公网拨测；本机
  `127.0.0.1:8000/health` 正常不能证明网关 TLS 正常。
- 每周至少执行一次公网证书检查；证书剩余不足 30 天时立即检查 ACME 日志，
  不要等到浏览器或客户端报错。
- 每次修改或轮换阿里云 AccessKey 后，立刻做只读 DNS API 测试和一次手工
  ACME 续签验证。

### 2026-07-21 故障记录

证书于 2026-07-20 到期，后端服务和网关 Nginx 进程均正常，但公网 TLS
握手失败。根因是宝塔保存的阿里云 `SecretKey` 开头多了一个空白字符：原值
调用只读 DNS API 返回 `SignatureDoesNotMatch`，移除首部空白后同一请求返回
200，随后通配证书续签成功。故障期间没有配置证书到期或公网拨测告警，因此
续签从首次失败到证书过期一直未被发现。

## LangWatch 独立子域名

LangWatch 使用独立子域名 `langwatch.example.com`（而非路径前缀），避免 Next.js 静态资源路径冲突。

LangWatch 服务本体只部署在 uat 业务服务器，但 uat 与 preview 后端都通过 uat 私网地址 `http://192.0.2.11:5560` 向该实例上报；两套环境通过独立项目 `lobster-backend-uat`、`lobster-backend-preview` 和不同 API Key 隔离。共享网关的 `https://langwatch.example.com` 只提供 Web UI 入口，主 `.com/.cn` vhost 均不配置 `/langwatch` location。

配置文件：`/www/server/panel/vhost/nginx/langwatch.conf`

**DNS 要求：** 需在 DNS 控制台为 `langwatch.example.com` 添加 A 记录，指向网关服务器 `192.0.2.13`。
