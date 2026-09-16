# prod 部署文档索引

旧版 `deploy-guide-prod.md` 包含过期生产服务器信息和客户端 Sparkle 内容。现在 prod 文档按端拆分，IP、域名、中间件连接和证书路径均保留占位符，等 prod 服务器确定后再填写。

## 服务器整体发布

- 完整一键发布全部服务器服务：`docs/operations/server-deploy-prod.md`
- 共享网关 Nginx：`docs/operations/gateway-nginx-prod.md`

## 单服务部署

- 后端：`docs/deployment/prod.md`
- 管理端：`../lobster-input-admin/docs/deployment/prod.md`
- 号池管理平台：`../lobster-input-api-manage/docs/deployment/prod.md`
- 支付服务：`../lobster-input-payment/docs/deployment/prod.md`
- 宣传官网：`../lobster-input-landing/docs/deployment/prod.md`

## 客户端发布

- Mac 客户端 Sparkle：`../lobster-input-front/docs/release/sparkle-build-guide.md`
- Windows 在线更新：`../lobster-input-win/docs/windows-online-update-release.md`
- Android 在线更新：`../lobster-input-android/docs/android-online-update-release.md`
- iOS 发布：`../lobster-input-ios/docs/ios-online-update-release.md`

客户端发布不属于服务器一键发布范围。
