# 客户端发布指南

> 最后更新：2026-07-15
> 适用分支：`feature/standard`

---

## 一、发布架构概述

2026-07 起按环境拆分更新通道（环境定义见 uat/preview 发布文档）：

```
客户端（macOS App）
    ↓ 启动时自动检查 / 用户点击"检查更新..."
对象存储（Cloudflare R2，bucket=lobster-mac）
    ├── uat/mac/
    │   ├── appcast-standard.xml                ← uat 公测环境（正式版）feed
    │   └── voice-input-<ver>-b<build>.zip      ← uat 安装包
    ├── preview/mac/
    │   ├── appcast-standard.xml                ← preview 内测环境（内测版）feed
    │   └── voice-input-<ver>-b<build>.zip      ← preview 安装包
    ├── appcast-standard-testing.xml            ← 【历史·迁移桥】旧 testing feed，只镜像 uat 内容
    ├── appcast-standard.xml / appcast-standard-new.xml / appcast-diy*.xml ← 历史渠道，已冻结
    └── standard/voice-input-x.x.x.zip          ← 历史安装包，勿删
```

- **环境模型（2026-07 正名）**：原 "preview/测试环境" 现网即 **uat（公测环境，api.example.com，徽章"正式版"）**；新建 **preview（内测环境，api.example.net，徽章"内测版"）**。两环境的包与 feed 绝不交叉。
- **旧 testing / new 渠道（appcast-standard-testing.xml、appcast-standard-new.xml 等）为历史渠道，已冻结**：其中 `appcast-standard-testing.xml` 作为老用户迁移桥，发布 uat 版本时同步镜像 uat 内容（永不放 preview 内容），其余仅留存不再维护。
- **后端代码无需参与**，更新流程完全基于静态文件托管
- 两个分支（standard/diy）独立维护各自的 appcast，互不影响发版节奏
- Sparkle 框架负责检查、下载、校验签名、替换安装、重启

---

## 二、密钥管理

### EdDSA 签名密钥

| 项目 | 说明 |
|------|------|
| Keychain 账户 | `lobster-input-standard-testing-2026` |
| 私钥位置 | 本机 macOS **Keychain**（钥匙串），同时在本文档明文备份 |
| 查看方式 | 打开「钥匙串访问」App，搜索 `Sparkle` 或账户名 `lobster-input-standard-testing-2026` |
| 公钥 | `6X7gC+sKhX85momJC5G+a/2PDL88krQSLBlalWRRtnc=` |
| 私钥明文 | `YOUR_SECRET_FROM_SECRET_STORE` |
| 公钥位置 | `voice-input/Info.plist` 的 `SUPublicEDKey` |
| Sparkle 工具路径 | `~/Library/Developer/Xcode/DerivedData/voice-input-*/SourcePackages/artifacts/sparkle/Sparkle/bin/` |

> ⚠️ **2026-05-07 起使用上表新密钥**。旧版本使用的 Sparkle 私钥已丢失，旧版本不再维护更新；后续测试版从新 build 开始使用新公钥和新私钥签名。
>
> ⚠️ 本文档按团队要求明文备份私钥，避免再次丢失。若仓库外发或开源，必须先移除私钥。

---

## 三、发布流程（每次发新版本执行）

### 步骤 1：确认版本号

命令行发布脚本会自动修改 `CURRENT_PROJECT_VERSION`。正式发布新功能时，再手动调整 `MARKETING_VERSION`；QA 内测包只递增 Build。

| 字段 | 说明 | 示例 |
|------|------|------|
| Version（MARKETING_VERSION） | 用户可见版本号 | `1.1.0` |
| Build（CURRENT_PROJECT_VERSION） | 内部构建号，纯数字递增，Sparkle 用此比较新旧 | `2` |

> ⚠️ Build 号必须严格递增，否则 Sparkle 不认为是新版本

### 步骤 2：命令行自动 Archive、Developer ID 导出和发布

完整命令按环境分别维护在本仓库 Sparkle 发布文档（先确认要发的是哪个环境）：

```
docs/release/sparkle-build-guide-uat.md      ← uat 公测环境（正式版），含老用户迁移桥
docs/release/sparkle-build-guide-preview.md  ← preview 内测环境（内测版）
```

该命令会自动完成：

- 修改 Build 号
- `xcodebuild archive`
- `xcodebuild -exportArchive` 使用 Developer ID 导出发布产物
- `codesign` / `spctl` 校验
- `ditto` 生成 Sparkle zip
- `sign_update` 生成 Sparkle EdDSA 签名
- 生成并校验 appcast
- 上传 zip 和 appcast 到 R2
- 用公开 URL 验证发布结果

> ⚠️ Sparkle 发布必须使用命令行导出的 Developer ID App。不要再使用 Xcode Organizer 手工导出作为标准流程。
>
> ⚠️ 必须用 `ditto -c -k --sequesterRsrc --keepParent` 生成 zip，不能用 Finder 右键压缩，否则 Sparkle 校验可能失败。

---

## 四、升级策略控制

### 4.1 普通可选升级（默认）

用户可以选择"稍后提醒"或"跳过此版本"，appcast.xml 无需额外标记。

### 4.2 强制升级

在 appcast.xml 的 `<item>` 里加一行：

```xml
<sparkle:criticalUpdate/>
```

效果：用户无法跳过，必须更新才能继续使用。

### 4.3 最低系统版本限制

```xml
<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
```

低于此系统版本的用户不会收到更新提示。

### 4.4 灰度发布（分批推送）

```xml
<!-- 按天分批，86400 秒 = 1 天，Sparkle 会在 N 天内逐步推送给所有用户 -->
<sparkle:phasedRolloutInterval>86400</sparkle:phasedRolloutInterval>
```

---

## 五、客户端更新行为说明

| 场景 | 菜单显示 | 是否可点击 |
|------|---------|-----------|
| 默认状态 | 检查更新... | ✅ |
| 点击后检查中 | 检查中... | ❌ |
| 找到新版本，下载中 | 下载中... | ❌ |
| 下载完成，等待安装 | 下载中... | ❌（Sparkle 接管） |
| 无新版本 / 检查失败 / 下载失败 | 检查更新... | ✅（静默恢复） |

---

## 六、appcast URL 配置位置

客户端中所有 URL 集中在 `APIConfig.swift`，appcast URL 由当前激活环境 `APIConfig.environment` 派生：

```swift
// voice-input/Core/Network/APIConfig.swift
static let environment: AppEnvironment = .preview   // 日常开发默认 preview；发 uat 包时切 .uat

enum Sparkle {
    // uat     → https://downloads.example.com/uat/mac/appcast-standard.xml
    // preview → https://downloads.example.com/preview/mac/appcast-standard.xml
    static let appcastURL: String? = { ... }()
}
```

同时 `Info.plist` 的 `SUFeedURL`（Sparkle 运行时实际读取处）必须与当前环境的 appcast URL 保持一致；切换命令见各环境发布文档第〇节。

---

## 七、发版 Checklist

```
□ 确认目标环境（uat 或 preview），并按对应发布文档切换/确认 APIConfig.environment 与 Info.plist SUFeedURL
□ 修改 Version（MARKETING_VERSION）
□ 递增 Build（CURRENT_PROJECT_VERSION，uat/preview 全局共享号段，跨环境不复用）
□ 执行对应环境发布文档中的全自动发布命令
  （uat: docs/release/sparkle-build-guide-uat.md；preview: docs/release/sparkle-build-guide-preview.md）
□ 确认 Developer ID 签名校验通过
□ 确认 zip length 与 sign_update 输出一致
□ 确认 appcast XML 校验通过
□ 确认公开 appcast URL 和 zip URL 返回正常（uat 还需确认迁移桥 appcast-standard-testing.xml 已同步且指向 uat 包）
□ 验证：用旧版 App 点击"检查更新..."是否收到提示，并确认更新弹窗中可见更新说明
□ uat 发布后：把环境切回 .preview + preview SUFeedURL 再继续日常开发
```
