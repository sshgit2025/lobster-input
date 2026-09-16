# preview 部署文档索引

preview（内测环境）是 2026-07 新建的独立环境，与 uat（公测环境，原 "preview"）完全隔离：

- 域名：`example.net` / `api.example.net` / `payment.example.net`
- 业务服务器：`192.0.2.15`（私网 `192.0.2.12`）——**抢占式实例，随时可能被释放回收**，相关文档均按"可换 IP 从零重建"编写
- 网关服务器 `192.0.2.13` 与 uat/prod 三环境共享，按 `server_name` 分发

uat（公测环境）索引见 `docs/deploy-guide-uat.md`。

## 服务器整体发布

- 完整一键发布全部服务器服务（含从零重建 runbook）：`docs/operations/server-deploy-preview.md`
- 共享网关 Nginx（.cn vhost）：`docs/operations/gateway-nginx-preview.md`

## 单服务部署

- 后端：`docs/deployment/preview.md`
- 管理端：`../lobster-input-admin/docs/deployment/preview.md`
- 号池管理平台：`../lobster-input-api-manage/docs/deployment/preview.md`
- 支付服务：`../lobster-input-payment/docs/deployment/preview.md`
- 宣传官网：`../lobster-input-landing/docs/deployment/preview.md`

## 客户端发布

- Mac 客户端 Sparkle：`../lobster-input-front/docs/release/sparkle-build-guide.md`
- Windows 在线更新：`../lobster-input-win/docs/windows-online-update-release.md`
- Android 在线更新：`../lobster-input-android/docs/android-online-update-release.md`
- iOS 发布：`../lobster-input-ios/docs/ios-online-update-release.md`

客户端发布不属于服务器一键发布范围。preview 环境客户端的在线更新走 R2 `preview/<platform>/` 前缀，与 uat 的 `uat/<platform>/` 严格隔离，绝不交叉。
