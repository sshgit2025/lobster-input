# Sparkle Appcast 版本隔离与配置备份

> 最后更新：2026-07-15
> 适用分支：`feature/standard-new` / `feature/diy-customization`

---

## ⓪ 2026-07 环境正名与通道现状（重要，先读这里）

2026-07 起更新通道按环境重新布局，本文档描述的 **testing / new 渠道全部标记为"历史，已冻结"**：

| 通道 | 现状 |
|------|------|
| `uat/mac/appcast-standard.xml` | **现役**。uat 公测环境（原 "preview" 现网，api.example.com，徽章"正式版"）feed，见 `release/sparkle-build-guide-uat.md` |
| `preview/mac/appcast-standard.xml` | **现役**。preview 内测环境（新建，api.example.net，徽章"内测版"）feed，见 `release/sparkle-build-guide-preview.md` |
| `appcast-standard-testing.xml` | 历史，已冻结为**老用户迁移桥**：发布 uat 版本时同步镜像该版本 item（zip 指向 `uat/mac/`），永不放 preview 内容 |
| `appcast-standard-new.xml` / `appcast-standard.xml` / `appcast-diy.xml` / `appcast-diy-new.xml` | 历史，已冻结，不再追加条目，仅留存（勿删，旧客户端仍会请求） |

以下章节为 2026-03 隔离方案的历史记录，作为台账保留，其中的"新（正式）"渠道均已被上表新布局取代。

---

## 一、背景说明（历史，2026-03）

在 `0.1.16`（Build 17）及之前发布的客户端均属于**内测版本**。
为防止内测用户在未来自动更新到正式版本，对 Sparkle 的 appcast 地址进行隔离：

- 旧内测版客户端 → 指向旧 appcast（永久冻结，不再追加新版本条目）
- 新正式版客户端 → 指向新 appcast（日后正常维护更新）

两套 appcast 互不影响，旧版客户端永远看不到新版更新。

---

## 二、Appcast 配置对照表

### 标准版（standard）

| 状态 | 分支 | SUFeedURL | 说明 |
|------|------|-----------|------|
| 旧（内测，已冻结） | `feature/standard` | `appcast-standard.xml` | 不再追加新版本，内测用户停留在此版本 |
| 新（正式） | `feature/standard-new` | `appcast-standard-new.xml` | 正式版维护此文件 |

### DIY 定制版（diy）

| 状态 | 分支 | SUFeedURL | 说明 |
|------|------|-----------|------|
| 旧（内测，已冻结） | `feature/diy-customization`（历史提交） | `appcast-diy.xml` | 不再追加新版本 |
| 新（正式） | `feature/diy-customization`（当前） | `appcast-diy-new.xml` | 正式版维护此文件 |

> Appcast 文件托管在 Cloudflare R2，基础 URL：
> `https://downloads.example.com/`

---

## 三、旧版内测 Appcast 备份配置

> 以下是旧内测版 `Info.plist` 中的原始 `SUFeedURL`，**备份留存**。
> 若需临时恢复让旧版客户端可以收到新版更新，将对应 SUFeedURL 还原即可。

### 标准版旧配置（feature/standard 分支 Info.plist）

```xml
<key>SUFeedURL</key>
<string>https://downloads.example.com/appcast-standard.xml</string>
```

### DIY 版旧配置（feature/diy-customization 分支 Info.plist）

```xml
<key>SUFeedURL</key>
<string>https://downloads.example.com/appcast-diy.xml</string>
```

---

## 四、如何恢复让旧版客户端下载到新版本

若需要临时恢复旧版内测客户端的自动更新能力（例如内测期间推送关键修复），有两种方式：

### 方式 A：往旧 appcast 追加新版本条目（推荐，不影响新版分支代码）

在对象存储上编辑 `appcast-standard.xml` / `appcast-diy.xml`，按 `release-guide.md` 中的模板追加一个新的 `<item>` 条目，旧版客户端即可检测到并提示更新。

### 方式 B：修改 Info.plist 的 SUFeedURL（需重新打包发布）

将对应分支 `voice-input/Info.plist` 中的 `SUFeedURL` 改回旧地址，重新打包发布，覆盖旧版本。

> ⚠️ 方式 B 需要重新构建和签名，建议优先使用方式 A。

---

## 五、对象存储 Appcast 文件清单

| 文件名 | 用途 | 是否继续维护 |
|--------|------|-------------|
| `uat/mac/appcast-standard.xml` | uat 公测环境（正式版）更新源 | ✅ 现役（2026-07 起） |
| `preview/mac/appcast-standard.xml` | preview 内测环境（内测版）更新源 | ✅ 现役（2026-07 起） |
| `appcast-standard-testing.xml` | 旧 testing 渠道更新源 → 老用户迁移桥 | ⚠️ 冻结，仅随 uat 发布同步镜像（永不放 preview 内容） |
| `appcast-standard.xml` | 旧内测标准版更新源（冻结） | ❌ 不再追加新版本 |
| `appcast-standard-new.xml` | 2026-03 方案的"新正式"标准版更新源（已被 uat 通道取代） | ❌ 冻结 |
| `appcast-diy.xml` | 旧内测 DIY 版更新源（冻结） | ❌ 不再追加新版本 |
| `appcast-diy-new.xml` | 2026-03 方案的"新正式" DIY 版更新源（DIY 分支后续如恢复发版需迁移到 `<env>/mac/` 布局） | ❌ 冻结 |

> ⚠️ `appcast-standard.xml` 和 `appcast-diy.xml` 请**不要删除**，旧版客户端启动时仍会请求这两个地址，删除会导致旧版客户端更新检查报错。

---

## 六、内测版本信息存档

| 字段 | 值 |
|------|----|
| 最后内测版本号 | `0.1.16` |
| 最后内测 Build 号 | `17` |
| 隔离时间 | 2026-03 |
| 标准版冻结 appcast | `appcast-standard.xml` |
| DIY 版冻结 appcast | `appcast-diy.xml` |
| 标准版新 appcast | `appcast-standard-new.xml` |
| DIY 版新 appcast | `appcast-diy-new.xml` |
| 内测版 Git Tag | `v0.1.16-beta`（feature/standard-new 分支） |
