# 共享网关 Nginx 配置 - prod

prod 与 uat、preview 三环境共用网关服务器，但必须使用独立的 prod 域名、证书、日志和业务转发目标。官网只有一个，可继续指向 `example.com` 的官网服务。

## prod 域名模板

| 用途 | 域名 |
|---|---|
| prod 主域名 | `<PROD_MAIN_DOMAIN>` |
| prod API / WebSocket | `<PROD_API_DOMAIN>` |
| prod 支付中转 | `<PROD_PAYMENT_DOMAIN>` |
| 官网 | `example.com` |

## prod 转发目标模板

| 服务 | 目标 |
|---|---|
| 后端 API | `http://<PROD_BUSINESS_PRIVATE_IP>:8000` |
| 管理端 | `http://<PROD_BUSINESS_PRIVATE_IP>:8888` |
| 号池管理端 | `http://<PROD_BUSINESS_PRIVATE_IP>:8889` |
| 支付服务 | `http://<PROD_BUSINESS_PRIVATE_IP>:8890` |
| 官网 | `http://<LANDING_PRIVATE_IP_OR_SHARED_TARGET>:9010` |

## Nginx 配置模板

建议 vhost 路径：

```text
/www/server/panel/vhost/nginx/lobster-input-prod.conf
```

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen 443 ssl;
    http2 on;
    server_name <PROD_MAIN_DOMAIN> <PROD_API_DOMAIN> <PROD_PAYMENT_DOMAIN>;

    ssl_certificate     <PROD_SSL_FULLCHAIN_PATH>;
    ssl_certificate_key <PROD_SSL_PRIVKEY_PATH>;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    if ($scheme = http) {
        return 301 https://$host$request_uri;
    }

    client_max_body_size 50m;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;
    proxy_connect_timeout 10s;

    location /.well-known/acme-challenge/ {
        root <PROD_ACME_WEBROOT>;
        try_files $uri =404;
    }

    location ^~ /lobster/api/v1/ {
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:8000/api/v1/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ^~ /lobster/api/v2/ {
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:8000/api/v2/;
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
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:8000/health;
        proxy_set_header Host $host;
    }

    location ^~ /lobster/payment {
        rewrite ^/lobster/payment(/.*)$ $1 break;
        rewrite ^/lobster/payment$ / break;
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:8890;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ^~ /lobster/admin/api/ {
        rewrite ^/lobster/admin(/.*)$ $1 break;
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:8888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ^~ /lobster/admin/ {
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:7888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ^~ /lobster/api-pool/api/v1/pool {
        return 403;
    }

    location = /lobster/api-pool/health {
        rewrite ^/lobster/api-pool(/.*)$ $1 break;
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:8889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    location ^~ /lobster/api-pool/api/ {
        rewrite ^/lobster/api-pool(/.*)$ $1 break;
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:8889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location ^~ /lobster/api-pool/ {
        proxy_pass http://<PROD_BUSINESS_PRIVATE_IP>:7889;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location = /lobster {
        default_type application/json;
        return 200 '{"service":"lobster-input","env":"prod","status":"running"}';
    }

    location / {
        proxy_pass http://<LANDING_PRIVATE_IP_OR_SHARED_TARGET>:9010/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    access_log  /www/wwwlogs/lobster-input-prod.log;
    error_log   /www/wwwlogs/lobster-input-prod.error.log;
}
```

## 验证

```bash
nginx -t && nginx -s reload
curl -s https://<PROD_API_DOMAIN>/lobster/health
curl -sI https://<PROD_MAIN_DOMAIN>/
```
