# iOS 打包、发布与在线更新流程

> 最后更新：2026-07-15
> 适用工程：`lobster-input-ios`

## 环境与域名

iOS 端与其它端共用同一套环境体系（历史上现网环境曾叫 "preview"，已正名为 **uat**）。环境常量定义在 `Shared/APIConfig.swift`：

| 环境 | API 地址 | 徽章 | 说明 |
| --- | --- | --- | --- |
| dev | `http://localhost:8000` | 无 | 本地开发 |
| uat | `https://api.example.com/lobster` | 正式版（Official） | 公测环境（原 "preview" 改名） |
| preview | `https://api.example.net/lobster` | 内测版（Beta） | 内测环境（新建） |
| prod | 占位 | 无 | 未来正式环境，尚未部署 |

切换方法：修改 `APIConfig.environment`（例如 `static let environment: Environment = .uat`），`current` 与全部端点 URL 由它派生，不要直接改 `current`。日常开发/内测默认 `.preview`。

**打包前必须确认环境**：打 TestFlight / Ad Hoc 包之前检查 `APIConfig.environment` 指向目标环境——面向公测用户的包必须切到 `.uat`，内测包用 `.preview`。两环境后端数据互不相通，发错环境用户将无法登录原账号。

徽章行为：App 设置页「关于 → 版本」行的徽章由 `APIConfig.environment` 动态派生：preview → 内测版（Beta），uat → 正式版（Official），dev/prod 不显示。以此可在装机后直接肉眼核对包所属环境。

iOS 无在线更新（见下文结论），因此没有按环境拆分的更新 feed；环境差异只体现在 API 域名与徽章。

## 结论

iOS 端不要接 Sparkle。Sparkle 是 macOS 应用更新框架，当前 Mac 端的 appcast、EdDSA 签名和 R2 静态更新包流程不能迁移到 iOS。iOS 的可用发布和更新路径由 Apple 控制：

- 内测：TestFlight。
- 正式：App Store，或审核通过后的 Unlisted App。
- 小范围真机包：Ad Hoc / release-testing，只能安装到已注册 UDID 的设备。
- 企业内部分发：Apple Developer Enterprise Program + MDM / 内部分发，仅限企业内部使用。

因此，iOS 的“在线更新”不是客户端下载 IPA 自更新，而是：

- TestFlight 用户由 TestFlight 推送更新。
- App Store 用户由 App Store 自动更新或用户手动更新。
- App 内最多提供“检查更新”提示，并跳转 TestFlight 或 App Store 页面。

参考：

- Apple：Distributing your app for beta testing and releases
  https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/
- Apple：Upload builds
  https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- Apple：Enterprise Program
  https://developer.apple.com/programs/enterprise/
- Sparkle 官方首页明确定位为 macOS 更新框架
  https://sparkle-project.org/

## 当前本机状态

本机已经能参与 iOS 自动签名，但还没有完整确认 TestFlight / App Store 上传链路。

已确认：

- Xcode：`26.4.1 (17E202)`。
- Team ID：`YOUR_TEAM_ID`。
- 钥匙串有 `Apple Development: YOUR_DEVELOPER_NAME (YOUR_TEAM_ID)`。
- 钥匙串有 `Developer ID Application: YOUR_DEVELOPER_NAME (YOUR_TEAM_ID)`，这是 macOS 站外分发用，不是 iOS 分发证书。
- Xcode 已拉到 iOS development profile 和 Ad Hoc profile：
  - `ssh2026.lobster-input-ios`
  - `ssh2026.lobster-input-ios.LobsterKeyboard`

仍需确认：

- App Store Connect 中是否已经创建 App 记录，Bundle ID 为 `ssh2026.lobster-input-ios`。
- 是否有可用于 App Store Connect 上传的 Apple Distribution 证书，或 Xcode Cloud Signing 是否可自动创建。
- 是否有 App Store Connect API Key，便于命令行无 UI 上传。

## Bundle 与能力

主 App：

```text
ssh2026.lobster-input-ios
```

键盘扩展：

```text
ssh2026.lobster-input-ios.LobsterKeyboard
```

App Group：

```text
group.ssh2026.lobster-input
```

发布前必须在 Apple Developer 后台确认两个 App ID 都具备对应能力，尤其是 App Group。键盘扩展需要 `RequestsOpenAccess=true`，否则网络请求、App Group 共享登录态和语音能力都会受限。

## 版本规则

每次上传 TestFlight / App Store 都必须递增 build 号。

| 字段 | Xcode 设置 | 规则 |
| --- | --- | --- |
| 用户可见版本 | `MARKETING_VERSION` | 正式功能版本变化时递增，例如 `1.0.0` |
| 构建号 | `CURRENT_PROJECT_VERSION` | 每次上传必须递增，不能复用 |

检查当前值：

```bash
cd /Users/your-user/workspace/swiftProjects/lobster-input/lobster-input-ios
xcodebuild -project lobster-input-ios.xcodeproj \
  -scheme lobster-input-ios \
  -configuration Release \
  -sdk iphoneos \
  -showBuildSettings \
  | rg 'MARKETING_VERSION|CURRENT_PROJECT_VERSION|PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM'
```

## 推荐发布路径：TestFlight

TestFlight 是 iOS 端最接近 Mac/Windows/Android 在线更新渠道（uat/preview）的官方方案。上传前按「环境与域名」一节确认 `APIConfig.environment`。

### 1. 准备 App Store Connect

1. 进入 App Store Connect。
2. 创建 App，Bundle ID 选择 `ssh2026.lobster-input-ios`。
3. 配置 App 信息、隐私、出口合规、年龄分级等。
4. 添加内部测试员。
5. 确认账号角色至少具备上传构建权限。

### 2. 归档

```bash
cd /Users/your-user/workspace/swiftProjects/lobster-input/lobster-input-ios

VERSION="1.0"
BUILD="2"
ARCHIVE="$PWD/build/ios/lobster-input-ios-${VERSION}-b${BUILD}.xcarchive"

perl -0pi -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${VERSION};/g" lobster-input-ios.xcodeproj/project.pbxproj
perl -0pi -e "s/CURRENT_PROJECT_VERSION = \\d+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" lobster-input-ios.xcodeproj/project.pbxproj

rm -rf "$ARCHIVE"
xcodebuild archive \
  -project lobster-input-ios.xcodeproj \
  -scheme lobster-input-ios \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates
```

说明：

- `generic/platform=iOS` 不需要连接真机。
- 如果只是上传 TestFlight，也不需要本地 simulator runtime 可运行。
- 如果 `archive` 阶段卡在 Xcode 验证 simulator runtime，按本文后面的故障处理先清理 Xcode runtime 状态。

### 3. 导出并上传到 App Store Connect

`ExportOptions-app-store-connect.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>upload</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
```

上传：

```bash
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions-app-store-connect.plist \
  -allowProvisioningUpdates
```

如果要使用 App Store Connect API Key，追加：

```bash
  -authenticationKeyPath /path/to/AuthKey_XXXXXXXXXX.p8 \
  -authenticationKeyID XXXXXXXXXX \
  -authenticationKeyIssuerID xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

上传成功后，App Store Connect 需要处理构建。处理完成后会出现在 TestFlight 页面。

## 本地导出 IPA

如果只想导出 IPA，然后用 Transporter 或 Xcode Organizer 上传：

`ExportOptions-app-store-connect-export.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
```

```bash
EXPORT_DIR="$PWD/build/ios/export-${VERSION}-b${BUILD}"
rm -rf "$EXPORT_DIR"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions-app-store-connect-export.plist \
  -allowProvisioningUpdates
```

导出的 `.ipa` 只能上传到 App Store Connect，不能作为普通网页下载更新给用户。

## Ad Hoc / 注册设备内测

Ad Hoc 适合少量已注册设备，不适合作为公开在线更新机制。

`ExportOptions-release-testing.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>release-testing</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
```

```bash
EXPORT_DIR="$PWD/build/ios/release-testing-${VERSION}-b${BUILD}"
rm -rf "$EXPORT_DIR"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist ExportOptions-release-testing.plist \
  -allowProvisioningUpdates
```

安装方式：

- Xcode Devices and Simulators。
- Apple Configurator。
- MDM。
- 仅限已加入 provisioning profile 的设备。

不要把 Ad Hoc IPA 当作 Android APK 一样直接给所有用户下载。

## 正式发布

正式发布流程：

1. 先用 TestFlight 完成真机验证。
2. App Store Connect 里选择同一个 build 提交审核。
3. 审核通过后发布到 App Store，或申请 Unlisted App 用直链分发。
4. 用户更新由 App Store 托管。

如果需要应用内“检查更新”，只做版本提示和跳转：

- TestFlight 内测版：跳转 TestFlight。
- App Store 正式版：跳转 App Store。

## Xcode 卡在“正在验证 iOS xx.simruntime”

这不是因为没有连接真机。它是在验证 simulator runtime，和真机调试是两套路径。

先检查命令行是否已经能看到 runtime：

```bash
xcrun simctl list runtimes
```

如果能正常输出，通常可以直接重试 archive。归档使用 `generic/platform=iOS`，不需要启动模拟器。

如果弹窗超过 10 分钟不动，按下面顺序处理：

```bash
killall Xcode 2>/dev/null || true
pkill -f xcodebuild 2>/dev/null || true
pkill -f SWBBuildService 2>/dev/null || true
xcrun simctl shutdown all 2>/dev/null || true
killall com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true

sudo xcodebuild -runFirstLaunch
xcrun simctl list runtimes
```

如果仍卡住：

1. 打开 Xcode。
2. 进入 Settings -> Platforms。
3. 删除异常或重复的 iOS runtime。
4. 重新下载当前 Xcode 推荐的 iOS runtime。

当前这台机器能看到多个 iOS runtime，其中包含两个 iOS 26.4 条目。重复 runtime 本身不一定有问题，但如果 Xcode UI 一直卡验证，优先删除旧的 26.4 runtime，仅保留和当前 Xcode 匹配的 26.4.1 runtime。

## 发布前 Checklist

```text
□ App Store Connect 已创建 App：ssh2026.lobster-input-ios
□ 主 App 和键盘扩展 Bundle ID 已注册
□ 主 App 和键盘扩展都启用了 App Group
□ App Group 为 group.ssh2026.lobster-input
□ MARKETING_VERSION 符合本次发布
□ CURRENT_PROJECT_VERSION 已递增
□ Release archive 成功
□ App Store Connect export/upload 成功
□ TestFlight 处理完成
□ 真机安装后开启键盘和 Allow Full Access
□ 测试录音、插入、改写、快捷操作、人格、符号、撤销、输入法切换
```

## 我能自动完成到哪一步

在本机现有条件下，我可以自动完成：

- 修改版本号和 build 号。
- Release archive。
- Ad Hoc / release-testing 导出尝试。
- 如果 Xcode 账号或 API Key 具备权限，上传 App Store Connect。
- 编写和维护发布文档。

我不能绕过 Apple 的账号和签名限制：

- 没有 App Store Connect App 记录，不能上传 TestFlight。
- 没有 Distribution / Cloud Signing 权限，不能导出 App Store Connect IPA。
- 没有 API Key 或已登录的 Xcode 账号权限，命令行不能无交互上传。
- 没有 Enterprise Program，不能做企业 OTA 自更新。

如果需要我全自动上传，请准备 App Store Connect API Key：


App Store Connect 的 Key ID、Issuer ID 和私钥请通过本机密钥管理器配置，勿写入仓库。
