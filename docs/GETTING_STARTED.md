# 配置与本地开发

所有部署文档中的 `example.com`、`example.net`、`example.org`、`192.0.2.*`、`YOUR_*` 都是占位信息。不要直接执行未填写配置的部署命令。

## 服务与配置文件

| 服务 | 示例文件 | 本地配置位置 | 默认端口 |
| --- | --- | --- | --- |
| 业务后端 | `lobster-input-backend/backend/.env.example` | 同目录 `.env` | 8000 |
| 管理后台 | `lobster-input-admin/.env.example` | `lobster-input-admin/backend/.env` | 8888 |
| 号池 | `lobster-input-api-manage/.env.example` | `lobster-input-api-manage/backend/.env` | 8889 |
| 支付 | `lobster-input-payment/.env.example` | 同目录 `.env` | 8890 |
| 官网后端 | `lobster-input-landing/backend/.env.example` | 同目录 `.env` | 8891 |

各配置模块通过进程工作目录读取 `.env`；从对应服务目录启动。管理端/号池启动脚本的实际环境加载方式也请参照脚本。不要将示例文件覆盖到已有真实配置上。

后端主要依赖 MongoDB、Redis、管理端 Provider 配置以及号池。按需启用支付、邮件、LangWatch；外部模型调用需要自己的供应商账号。数据库用空库初始化，不从生产环境复制备份或账号。

## 密钥

用以下命令为每个独立用途生成不同的随机值，填写到本地 `.env`，不要将输出提交进 Git：

```bash
python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
```

- 业务后端：`JWT_SECRET_KEY`、`API_KEY`。
- 管理端和号池：各自独立的 `SECRET_KEY`。
- 官网：`SITE_JWT_SECRET`。
- 服务间调用：调用方与被调用方的对应内部密钥必须匹配，例如后端 `API_POOL_INTERNAL_KEY` 与号池 `INTERNAL_API_KEY`。
- ASR/LLM/Search 的供应商密钥通过管理端和号池配置。支付渠道密钥由支付服务配置维护。

数据库示例默认使用本机无认证实例，仅用于隔离的本地开发。实际部署启用认证及网络访问控制，通过环境变量提供连接串。

## 启动

```bash
bash lobster-input-backend/scripts/restart.sh
bash lobster-input-admin/scripts/restart.sh
```

其他服务的启动入口、工作目录及依赖见各子目录脚本和 README。Web 项目先在对应 `frontend` 中运行 `npm ci`，再使用 `package.json` 提供的开发命令。

## 客户端地址与签名

| 平台 | 地址配置入口 |
| --- | --- |
| macOS | `lobster-input-front/voice-input/Core/Network/APIConfig.swift` |
| iOS | `lobster-input-ios/Shared/APIConfig.swift` |
| Android | `lobster-input-android/app/build.gradle.kts` 和 `core/network/ApiConfig.kt` |
| Windows | `lobster-input-win/LobsterInput/Config/ApiConfig.cs` |
| HarmonyOS | `lobster-input-harmony/entry/src/main/ets/core/network/ApiConfig.ets` |

macOS 开发环境可选 `.dev`；iOS/Android/HarmonyOS 真机需能访问开发电脑或自行部署的服务器。更新 feed、官网链接、回调地址也要一并配置。

Apple 项目的开发团队已清空，选择自己的 Team 并配置自己的 Bundle ID、App Group、签名证书和描述文件。macOS 脚本从 `DEVELOPMENT_TEAM` 读取团队 ID；iOS 可在 Xcode Signing & Capabilities 配置。Windows、Android、HarmonyOS 的发布签名也需自行准备。

## 运营服务的协议与隐私说明

`lobster-input-backend/docs/legal/` 提供多语言部署模板，部署者须按实际主体、功能、接收方和数据保留规则填写、审核后，通过管理端发布。模板不是已经生效的服务协议。安装器的开源分发说明不替代运营服务的告知；源码授权以根目录 MIT 及适用第三方许可证为准。

## 远程部署凭据

远程部署优先使用 SSH 密钥或代理，按可信渠道核对主机指纹并预先维护 `known_hosts`。示例启用严格主机密钥检查；不要为省略首次配置而关闭校验。部署文档中的密码登录示例仅为兼容性说明，不应把实际密码写入命令历史、进程参数或公开日志。各环境使用独立凭据，备份与密钥位于源码目录之外。
