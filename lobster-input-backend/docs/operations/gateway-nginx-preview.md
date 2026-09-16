# 共享网关 Nginx 配置 - preview（.cn vhost）

网关服务器 `192.0.2.13` 承载 uat、preview、prod 三个环境的入口配置，三环境共享同一台网关。本文描述 preview（内测环境）的 `.cn` 系列 vhost **完整目标配置**，结构与 uat 的 `.com` vhost（`docs/operations/gateway-nginx-uat.md`）完全对齐，主要差异如下：

1. `server_name` 为 `.cn` 系列域名；
2. 所有 `proxy_pass` 指向 preview 业务私网 IP `192.0.2.12`；
3. 环境标识和访问日志名称使用 preview / `.cn` 后缀；
4. LangWatch 服务本体只部署在 uat，并使用独立的 `langwatch.example.com` vhost；uat、preview 的主 vhost 都不包含 `/langwatch` location。

> preview 业务服务器为抢占式实例，实例被释放更换后，只需把本文两个 vhost 中的私网 IP 全部替换为新私网 IP，然后 `nginx -t && nginx -s reload`。

## preview 域名

| 用途 | 域名 |
|---|---|
| 官网、管理端、号池、支付页面 | `example.net`、`www.example.net` |
| 客户端 API / WebSocket | `api.example.net` |
| 支付中转 | `payment.example.net` |

## preview 转发目标

| 服务 | 目标 |
|---|---|
| 后端 API | `http://192.0.2.12:8000` |
| 管理端 API | `http://192.0.2.12:8888` |
| 管理端前端 | `http://192.0.2.12:7888` |
| 号池管理端 API | `http://192.0.2.12:8889` |
| 号池管理端前端 | `http://192.0.2.12:7889` |
| 支付服务 | `http://192.0.2.12:8890` |
| 官网后端 API | `http://192.0.2.12:8891` |
| 官网前端 SPA | `http://192.0.2.12:7891` |

## 证书

沿用现有通配符证书，无需为 `.cn` 新申请：`/www/server/panel/vhost/cert/www.example.com/` 下的证书已同时覆盖 `*.example.com` 和 `*.example.net`。

## 主 vhost：lobster-input-cn.conf

配置文件路径：

```text
/www/server/panel/vhost/nginx/lobster-input-cn.conf
```

目标配置全文（改完后 `nginx -t && nginx -s reload`）：

```nginx
server {
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name example.net www.example.net api.example.net;

    # SSL 证书（通配符证书已覆盖 *.example.net，路径保持不变）
    ssl_certificate     /www/server/panel/vhost/cert/www.example.com/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/www.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL_CN:10m;
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
        root /www/wwwroot/www.example.net;
        try_files $uri =404;
    }

    # 后端 API（含 WebSocket 支持）
    location ^~ /lobster/api/v1/ {
        proxy_pass http://192.0.2.12:8000/api/v1/;
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
        proxy_pass http://192.0.2.12:8000/api/v2/;
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
        proxy_pass http://192.0.2.12:8000/health;
        proxy_set_header Host $host;
    }

    # 支付服务（支付平台回调写路径，必须由服务校验 X-API-Key + HMAC 签名）
    location ^~ /lobster/payment {
        rewrite ^/lobster/payment(/.*)$ $1 break;
        rewrite ^/lobster/payment$ / break;
        proxy_pass http://192.0.2.12:8890;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 管理端 API（前后端分离：API 走后端 8888）
    location ^~ /lobster/admin/api/ {
        rewrite ^/lobster/admin(/.*)$ $1 break;
        proxy_pass http://192.0.2.12:8888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 管理端前端 SPA（Vue，端口 7888）
    location ^~ /lobster/admin/ {
        proxy_pass http://192.0.2.12:7888;
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
        proxy_pass http://192.0.2.12:8889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    # 号池 API
    location ^~ /lobster/api-pool/api/ {
        rewrite ^/lobster/api-pool(/.*)$ $1 break;
        proxy_pass http://192.0.2.12:8889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 号池前端 SPA（Vue，端口 7889）
    location ^~ /lobster/api-pool/ {
        proxy_pass http://192.0.2.12:7889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /lobster {
        default_type application/json;
        return 200 '{"service":"lobster-input","env":"preview","status":"running"}';
    }

    # 官网后端 API（前后端分离：API 走后端 8891，Nginx rewrite 掉 /lobster/site 前缀）
    location ^~ /lobster/site/api/ {
        rewrite ^/lobster/site(/.*)$ $1 break;
        proxy_pass http://192.0.2.12:8891;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # 根路径转发到官网前端 SPA（7891 端口）
    location / {
        proxy_pass http://192.0.2.12:7891/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    access_log  /www/wwwlogs/lobster-input-cn.log;
    error_log   /www/wwwlogs/lobster-input-cn.error.log;
}
```

LangWatch 不在 preview 业务服务器部署，但 preview 后端仍通过独立项目 `lobster-backend-preview` 向 uat 私网地址 `http://192.0.2.11:5560` 上报。`https://langwatch.example.com` 只是运维 Web UI 入口。项目和 API Key 隔离规则见 `langwatch.md`。

## 支付 vhost：payment-lobster-input-cn.conf（新增）

支付中转域名使用独立 vhost，避免未匹配的 `payment.example.net` 请求落到其它默认站点。支付中转页由后端 `lobster-input-backend/backend/app/api/v1/payments.py` 提供，外部路径是：

```text
https://payment.example.net/lobster/api/v1/payments/checkout-intents/{intent_id}
```

配置文件（对齐 `.com` 的 `payment-lobster-input.conf`）：

```text
/www/server/panel/vhost/nginx/payment-lobster-input-cn.conf
```

```nginx
server {
    listen 80;
    server_name payment.example.net;

    location /.well-known/acme-challenge/ {
        root /www/wwwroot/www.example.net;
        try_files $uri =404;
    }

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;
    server_name payment.example.net;

    ssl_certificate     /www/server/panel/vhost/cert/www.example.com/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/www.example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers EECDH+CHACHA20:EECDH+AES128:RSA+AES128:EECDH+AES256:RSA+AES256:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL_CN_PAY:10m;
    ssl_session_timeout 10m;

    client_max_body_size 10m;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;
    proxy_connect_timeout 10s;

    location ^~ /lobster/api/v1/payments/ {
        proxy_pass http://192.0.2.12:8000/api/v1/payments/;
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
        return 200 '{"service":"lobster-payment-checkout","env":"preview","status":"running"}';
    }

    location = /lobster/health {
        proxy_pass http://192.0.2.12:8000/health;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }

    location / {
        default_type application/json;
        return 404 '{"detail":"payment checkout route not found"}';
    }

    access_log  /www/wwwlogs/payment-lobster-input-cn.log;
    error_log   /www/wwwlogs/payment-lobster-input-cn.error.log;
}
```

## DNS 要求

以下记录需解析到网关服务器 `192.0.2.13`：

- `example.net`、`www.example.net`
- `api.example.net`
- `payment.example.net`

## 验证

```bash
nginx -t && nginx -s reload
curl -s https://api.example.net/lobster/health
curl -s https://example.net/lobster          # 期望 {"service":"lobster-input","env":"preview",...}
curl -s https://payment.example.net/lobster  # 期望 {"service":"lobster-payment-checkout","env":"preview",...}
curl -s https://payment.example.net/lobster/health
curl -s https://payment.example.net/lobster/api/v1/payments/checkout-intents/not-exist | head
curl -sL -o /dev/null -w '%{http_code}\n' https://example.net/lobster/admin/login
curl -s https://example.net/lobster/api-pool/health
curl -s https://example.net/lobster/payment/health
curl -sI https://example.net/
```

## 更换业务服务器（抢占式实例被回收后）

只改本文两个 vhost 中的私网 IP，再 `nginx -t && nginx -s reload`。不要动 `.com`（uat）和 prod 的任何配置。完整重建流程见 `docs/operations/server-deploy-preview.md`。
