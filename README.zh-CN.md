# 龙虾输入法 · Lobster Input

[English](README.md) · [简体中文](README.zh-CN.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

> **官方网站：[lobster-input.com](https://lobster-input.com)** · **交流 QQ 群：925395991**
>
> 欢迎访问官网、反馈问题、交流使用体验与参与开发。

跨平台语音输入与中文键盘项目，包含 macOS、Windows、iOS、Android、HarmonyOS 客户端，以及共享后端、管理后台、API Key 号池、支付服务和官网。

支持语音识别、文本处理、用户词典、输入历史、实时音频交互及多端账号服务。移动端还包含本地拼音键盘。各端成熟度不同，具体能力以对应实现和文档为准；笔记与用户中心目前是项目骨架。

本仓库供自行部署和开发使用。云端地址已经替换成 `example.com` 等示例域名，服务器地址使用 `192.0.2.0/24` 文档网段；这些地址不可直接用于运行。仓库不提供运营环境、账号、数据库内容或第三方 API 额度。

## 管理端展示

[![管理端展示](docs/images/admin/01-dashboard.png)](docs/admin-showcase.zh-CN.md)

**[查看全部 25 个管理页面 →](docs/admin-showcase.zh-CN.md)**

## 作者与联系

由 **shaohua.sun、yaqiong.xu** 共同开发并开源。

| shaohua.sun | yaqiong.xu |
| :---: | :---: |
| <img src="docs/images/authors/shaohua-sun.png" width="104" alt="shaohua.sun"> | <img src="docs/images/authors/yaqiong-xu.png" width="104" alt="yaqiong.xu"> |
| [shaohua.sun.main@gmail.com](mailto:shaohua.sun.main@gmail.com) | [simpleeve007@gmail.com](mailto:simpleeve007@gmail.com) |

**QQ 交流群：925395991**。欢迎加群或通过邮箱交流使用体验、问题反馈与合作建议。可复现的问题和功能建议也欢迎提交 GitHub Issue；安全问题请按 [安全策略](SECURITY.md) 私下联系。

## AI 辅助开发

本项目 **99.9%** 使用 **Claude 4.6** 和 **GPT-5.5** 开发。其中，Claude 承担约 **95%** 的开发工作，GPT-5.5 主要负责大模型提示词编写。**人工调整占比不足 0.1%。**

## 目录

| 目录 | 用途 | 技术 |
| --- | --- | --- |
| [lobster-input-front](lobster-input-front/README.md) | macOS 客户端（standard 版本） | Swift、SwiftUI、Sparkle |
| [lobster-input-win](lobster-input-win/) | Windows 客户端 | C#、WPF、.NET |
| [lobster-input-ios](lobster-input-ios/) | iOS 应用和键盘扩展 | Swift、SwiftUI、UIKit |
| [lobster-input-android](lobster-input-android/README.md) | Android 应用和输入法 | Kotlin、Compose |
| [lobster-input-harmony](lobster-input-harmony/PORTING_GUIDE.md) | HarmonyOS 应用和输入法 | ArkTS |
| [lobster-input-backend](lobster-input-backend/README.md) | 共享业务后端 | Python、FastAPI、MongoDB、Redis |
| [lobster-input-admin](lobster-input-admin/README.md) | 管理后台 | FastAPI、Vue |
| [lobster-input-api-manage](lobster-input-api-manage/) | API Key 号池管理平台 | FastAPI、Vue |
| [lobster-input-payment](lobster-input-payment/README.md) | 支付服务 | Python、FastAPI |
| [lobster-input-landing](lobster-input-landing/) | 宣传官网 | Vue、FastAPI |
| [lobster-ucenter](lobster-ucenter/README.md) | 用户中心骨架 | FastAPI |
| [lobster-note](lobster-note/README.md) | 笔记项目骨架 | FastAPI、Vue |

## 本地开发

1. 安装目标端工具链：后端使用 Python 3.12+ 和 uv；Web 前端使用 Node.js（版本要求见各端 `package.json`）；Apple 客户端使用 Xcode；Android 使用 JDK 17 和 Android SDK；Windows 使用对应项目文件要求的 .NET SDK；HarmonyOS 使用 DevEco 工具链。
2. 阅读 [配置与开发指南](docs/GETTING_STARTED.md)，将所需端的 `.env.example` 复制为 `.env`，填入自行生成的鉴权密钥和自己的服务配置。
3. 启动本地 MongoDB、Redis，再依次配置号池、管理端、支付服务和业务后端。云端 ASR/LLM 功能需要在号池和管理端录入自己的供应商配置。
4. 将目标客户端的 API 地址改为自己的后端；真机不能用 `localhost` 访问开发电脑。

后端一键启动：

```bash
cp lobster-input-backend/backend/.env.example lobster-input-backend/backend/.env
# 先编辑 .env 中的密钥及服务地址
bash lobster-input-backend/scripts/restart.sh
```

macOS 一键编译启动：

```bash
export DEVELOPMENT_TEAM="你的 Apple Team ID"
bash lobster-input-front/scripts/restart.sh --build
```

iOS 的 App Group、Bundle ID、开发团队，以及各平台发布签名和更新源必须改成自己的配置。详见 [发布指南](docs/RELEASING.md)。

根目录 README 提供四种语言；各端文档和开发指南目前主要使用中文。

## 词库与资源

基础拼音资源保留在各移动端中；约 39 MB 的可选扩展 `custom_dict.txt` 已替换为小型示例，扩展候选覆盖会减少。运行时仍可读取基础词库。扩展构建工具位于 Android 的 `tools/keyboard-verify`。参见 [第三方资源说明](THIRD_PARTY_NOTICES.md)，分发时需保留第三方许可证。

数据库备份、用户录音、生产数据、密钥、构建产物、安装包和本地依赖不属于源码发布内容。

## 参与贡献

请阅读 [贡献指南](CONTRIBUTING.md)、[行为准则](CODE_OF_CONDUCT.md) 和 [安全策略](SECURITY.md)。提交前执行：

```bash
python3 scripts/check_public_repo.py
```

## 许可证

项目原创代码按 [MIT License](LICENSE) 授权。第三方依赖、字体、词库及其他资源遵循各自许可证；MIT 不替代这些许可，也不授予项目商标或第三方服务使用权。
