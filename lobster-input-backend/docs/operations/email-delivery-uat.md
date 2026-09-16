# UAT 验证码邮件发送与故障排查

## 当前链路（2026-08-27）

| 环节 | 地址 / 配置 |
|---|---|
| App 发码入口 | `POST https://api.example.com/lobster/api/v1/auth/send-code` |
| UAT 后端 | `192.0.2.11:8000`，服务 `lobster-backend` |
| 后端邮件出口 | `AOKSEND_API_URL=http://192.0.2.16/index/api/send_email` |
| 共享网关私网转发 | `/www/server/panel/vhost/nginx/lobster-mail-relay.conf` |
| 网关到外部供应商 | `https://apiv2.aoksend.com/index/api/send_email`，校验 TLS 证书和域名 |

服务器之间只使用私网地址；网关访问第三方供应商属于必要的外部 HTTPS 调用。Web 客户端不应直接访问邮件出口。网关 vhost 仅允许 UAT 私网源 `192.0.2.11`，只有固定路径的 POST 被转发，不支持任意目标代理。公网请求即使伪造私网 Host 或 `X-Forwarded-For`，也返回 403。

当前仅 UAT 使用该出口。Preview、production 保持各自原配置，默认直连官方 HTTPS API，不自动共用 UAT 私网白名单。

## 密钥与配置

正式 `AOKSEND_API_KEY`、`AOKSEND_TEMPLATE_ID` 位于 UAT `/opt/lobster-backend/.env`，权限 `root:root 600`。本次修复没有更换 Key、模板、验证码算法或测试邮箱白名单。网关配置不保存 Key，也不记录请求体、查询参数、邮箱、验证码。

```env
AOKSEND_API_URL=http://192.0.2.16/index/api/send_email
AOKSEND_API_KEY=<现有 AokSend API Key>
YOUR_AOKSEND_API_KEY<现有验证码邮件模板 ID>
```

Key 轮换时，在供应商控制台确认新 Key 与现有模板所属账号一致，先备份服务器 `.env`，只更新 UAT 对应配置，重启后端后向团队测试邮箱验证，确认供应商接受及邮箱收到再完成旧 Key 作废。不要将 Key、验证码或完整上游响应贴入日志/工单。

## 部署与验证

1. 从后端仓库根目录上传 `docker/nginx/lobster-mail-relay.conf` 到共享网关上述路径；本地运维 SSH 可用公网，网关到业务服务器的服务调用必须走私网。
2. 在共享网关运行 `/www/server/nginx/sbin/nginx -t && /www/server/nginx/sbin/nginx -s reload`。不修改现有 `.com/.cn` vhost，不新增开放端口。
3. 在 UAT 保留 Key 和模板，只配置上述 `AOKSEND_API_URL`。后端必须包含读取该配置的 `app/core/config.py` 和 `app/services/account/email_service.py`，再执行 `systemctl restart lobster-backend`。
4. 从 UAT 执行无密钥、无收件人的空参数探测（不会发送邮件）：

```bash
curl -sS --connect-timeout 5 --max-time 15 -X POST -d '' \
  http://192.0.2.16/index/api/send_email
# 预期 HTTP 200，JSON code=40001（API 密钥不能为空）
```

该探测验证私网、DNS、供应商 TLS/API 可达，不证明 Key、余额、模板有效，也不证明邮件进入收件箱。完整验证需要在 App 向团队测试邮箱请求一次验证码，并检查供应商受理日志与邮箱收件情况；不要批量向真实用户发测试邮件。

```bash
# UAT 后端日志；-a 避免稀疏历史日志被 grep 判为二进制
tail -n 200 /var/log/lobster-backend.log | grep -aE 'AokSend|send-code|EMAIL_SERVICE_UNAVAILABLE'
# 共享网关日志，只含源 IP、方法、路径、状态及耗时
tail -n 30 /www/wwwlogs/lobster-mail-relay.log
tail -n 30 /www/wwwlogs/lobster-mail-relay.error.log
```

正常结果：发码接口 HTTP 200、`cooldown_seconds=60`，后端记录 `AokSend accepted verification email`，网关记录源 `192.0.2.11`、`status=200 upstream_status=200`。供应商返回成功只表示已受理，最终收件仍以邮箱为准。

## 超时、重试与告警

- 后端每次请求总超时 15 秒、连接超时 5 秒、读取超时 10 秒；仅连接建立失败时间隔 250ms 重试一次。
- TLS 证书异常、业务拒绝、HTTP 错误、非 JSON、断连或发送后的超时都不自动重放邮件；网关同样设置 `proxy_next_upstream off`，避免不确定结果导致重复发信。
- 后端关闭自动重定向，网关固定上游域名并启用 `proxy_ssl_verify on`；不得用跳过 TLS 校验、明文公网 API、固定 Cloudflare IP 等方式修复连接问题。
- 失败时返回 HTTP 503 / `EMAIL_SERVICE_UNAVAILABLE`，客户端提示 60 秒后重试。原有冷却和 IP 发码限额仍保留，失败也可能占用一次限流额度，不应因上游故障绕过防刷。
- 建议监控发码接口 5xx、供应商拒绝码和转发耗时，并对上述不发邮件探测设置告警；普通 `/health` 仅证明后端存活。此处为运维要求，本次未新增外部告警通道或定时任务。
- 若网关出口也不可达，应确认供应商/网络状态并恢复受控出口；不要盲目重试真实发信或切回被官方标记为即将下线的旧 API。

## 2026-08-27 故障记录

- 16:32 日志显示 UAT 调用 AokSend 时出现 `Connection reset by peer`，未处理异常导致 `/auth/send-code` 返回 500；18 秒后重试被原有冷却拦截为 429。
- 18:06 排查：后端、MongoDB、管理服务均 active，磁盘和内存充足，公网 `/health` 为 200。UAT 可建立目标 TCP 连接，但 TLS ClientHello 后被重置；两个 DNS 返回地址、TLS 1.2 都可复现。
- 共享网关对同一供应商域名、同一 DNS 地址访问成功，证明故障局限于 UAT 直连出网链路。仅凭这些证据不能确定具体中间设备或供应商封禁策略，不归因为 API Key 失效或接口政策变更。
- 官方文档仍推荐 `https://apiv2.aoksend.com/index/api/send_email`，没有改用旧版或未经确认的第三方域名。
- 修复：UAT 经共享网关私网专用 vhost 转发，增加后端超时、有限连接重试和结构化失败提示。新端口试验未打通后复用了已通的 80 端口，`8003` 临时规则已撤回。
- 18:11 正式公网发码测试 HTTP 200，约 1.6 秒；供应商成功受理，网关日志确认 UAT 私网源。未代替用户完成登录、未消费验证码，也未改变登录会话。
- 本地邮件发送/验证码/登录会话/限流相关回归测试共 23 项通过。

### 备份与回滚

UAT 变更前文件保存在 `/opt/lobster-backend/email-fix-backup-20260827-wPQt6w/`（目录 700），含 `config.py`、`email_service.py`、`env`（600）。若需回滚代码，在 UAT 从该目录恢复对应文件到 `app/core/config.py`、`app/services/account/email_service.py` 和 `.env`，恢复 `root:root 600` 的 `.env` 权限后重启 `lobster-backend`。回滚会恢复当时不可达的直连地址，必须先确认出网已恢复，否则发码会再次失败。

如不再使用转发，将网关配置移为不以 `.conf` 结尾的备份文件，执行 Nginx 配置检查并 reload；无需清除任何业务数据，也没有需保留的 `8003` 防火墙规则。

参考：[AokSend 官方 API 文档](https://www.aoksend.com/api.html)、[Nginx HTTPS 上游代理](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)、[aiohttp 超时与客户端异常](https://docs.aiohttp.org/en/stable/client_reference.html)。
