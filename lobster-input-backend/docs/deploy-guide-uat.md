# uat 部署文档索引

uat（公测环境）即历史文档中的 "preview/测试环境"，现已正名：它一直是对外公测的现网环境，域名 `example.com`，业务服务器 `192.0.2.14`（长期实例）。新建的内测环境见 `docs/deploy-guide-preview.md`。

旧版 `deploy-guide-preview.md` 曾混放后端、管理端、号池、支付、官网、网关、备份和客户端配置。现在已拆分到更明确的位置，本文只作为兼容索引保留。

## 服务器整体发布

- 完整一键发布全部服务器服务：`docs/operations/server-deploy-uat.md`
- 共享网关 Nginx（.com vhost）：`docs/operations/gateway-nginx-uat.md`

## 单服务部署

- 后端：`docs/deployment/uat.md`
- 管理端：`../lobster-input-admin/docs/deployment/uat.md`
- 号池管理平台：`../lobster-input-api-manage/docs/deployment/uat.md`
- 支付服务：`../lobster-input-payment/docs/deployment/uat.md`
- 宣传官网：`../lobster-input-landing/docs/deployment/uat.md`

## 客户端发布

- Mac 客户端 Sparkle：`../lobster-input-front/docs/release/sparkle-build-guide.md`
- Windows 在线更新：`../lobster-input-win/docs/windows-online-update-release.md`
- Android 在线更新：`../lobster-input-android/docs/android-online-update-release.md`
- iOS 发布：`../lobster-input-ios/docs/ios-online-update-release.md`

客户端发布不属于服务器一键发布范围。
