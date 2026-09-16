# Android 在线更新发布流程 — preview(内测环境)

> 环境体系说明:**preview 是新建的内测环境**(api.example.net,业务服务器 192.0.2.15),与历史上曾被叫作 "preview" 的现网公测环境无关——那套环境已正名为 **uat**,发布流程见 `android-online-update-release-uat.md`。两环境的包与清单绝不交叉,本文件只描述 preview。

Android 端使用 App 内“检查更新”入口读取 Cloudflare R2 上的静态 JSON 清单。客户端只内置公开读取地址,不内置 R2 写入密钥。

## 环境概览

| 项 | 值 |
|---|---|
| 环境 | preview(内测,日常开发/内测用户) |
| API 地址 | `https://api.example.net/lobster/` |
| Gradle flavor | `preview` |
| 客户端徽章 | 内测版(Beta) |
| R2 前缀 | `preview/android/` |
| 更新源 | `https://downloads.example.com/preview/android/update.json` |
| 当前版本 | versionName `1.0.105` / versionCode `110` |

prod 为未来正式环境占位(`android/prod/` 前缀预留),尚未部署,不在本文范围。

**重要:旧路径 `android/preview/update.json` 不属于本环境。** 它是存量老用户的迁移桥,只镜像 uat 内容,永远不要往里面写 preview(内测环境)的包或清单,详见 uat 文档“老用户迁移桥”章节。

## 构建

preview 包由 `preview` flavor 构建(BASE_URL、更新源、环境徽章均由 `app/build.gradle.kts` 的 productFlavors 注入,禁止手改代码切环境):

```bash
./gradlew assemblePreviewDebug
# 产物:app/build/outputs/apk/preview/debug/app-preview-debug.apk
```

发布沿用 debug 签名 APK(既有约定,详见下文“签名要求”)。

## 清单格式

`update.json`:

```json
{
  "version_code": 109,
  "version_name": "1.0.104",
  "apk_url": "https://downloads.example.com/preview/android/lobster-input-1.0.104.apk",
  "apk_sha256": "可选，建议填写 APK SHA256",
  "release_notes": "本次更新说明，会显示在 App 更新弹窗中。",
  "force": false,
  "published_at": "2026-07-15T00:00:00Z"
}
```

客户端用 `version_code` 和系统 `PackageManager` 读取到的当前已安装包 versionCode 比较。只有远端更大时才提示更新。不要使用 `BuildConfig.VERSION_CODE` 作为更新判断依据,因为 Android 安装 APK 后当前进程不一定立刻重启,旧进程里的编译期常量可能仍是安装前的版本,容易导致同一个更新反复提示。

## 版本规则

1. **versionCode 全局单调递增,跨环境(uat/preview)绝不复用同一个号**。发新版前先确认另一环境已用到的最大号。
2. 每次发布必须递增 `versionCode`,即使 `versionName` 不变也必须递增。
3. `update.json.version_code` 必须和 APK manifest 内的 `versionCode` 完全一致。
4. `update.json.version_name` 必须和 APK manifest 内的 `versionName` 完全一致。
5. `apk_url` 指向的 APK 包名必须和当前客户端包名一致;`apk_url` 必须指向 `preview/android/` 下的包,永不指向 uat(公测环境)的包。
6. 先上传 APK,再上传引用该 APK 的 `update.json`;不要提前发布指向不存在或旧 APK 的清单。
7. 如果发现线上清单误发,优先修正 `update.json`,不要通过客户端兼容错误清单。
8. preview 首发版本为 `1.0.104 / versionCode 109`(当前 `1.0.105/110`)(延续原版本名序列;versionCode 全局递增,高于 uat 的 108 与历史旧 preview 的 107)。

版本号唯一事实源:`app/build.gradle.kts` 中 `productFlavors { create("preview") { versionCode / versionName } }`;发新版时同步更新 `tools/release/r2_publish.py` 的 `ENV_VERSIONS` 兜底映射。

## Gradle 下载源

发布前如果 Gradle Wrapper 卡在下载 `services.gradle.org`,优先切换国内镜像再构建。当前推荐腾讯云 Gradle 镜像:

```properties
distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-8.7-bin.zip
```

如果腾讯云镜像不可用,可换成其他国内 Gradle 镜像并先用 `HEAD` 请求确认可访问。不要在海外下载源长时间等待,避免发布过程卡死。

## 发布前 APK 反查

发布前必须用本地 APK 反查 manifest,确认清单和 APK 一致:

```bash
APK="app/build/outputs/apk/preview/debug/app-preview-debug.apk"
apkanalyzer manifest application-id "$APK"
apkanalyzer manifest version-code "$APK"
apkanalyzer manifest version-name "$APK"
apksigner verify --print-certs "$APK"
shasum -a 256 "$APK"
```

预期:

- `application-id` 为 `com.lobster.input`(两环境同包名,不可改)
- `version-code` 等于即将写入 `update.json.version_code`
- `version-name` 等于即将写入 `update.json.version_name`
- `apksigner` 输出的证书指纹必须和内测机上已安装版本一致(见“签名要求”)
- `apk_sha256` 等于 `shasum -a 256` 的输出

## 上传(r2_publish.py)

统一使用参数化发布脚本 `tools/release/r2_publish.py`:

```bash
python3 tools/release/r2_publish.py --env preview --notes "本次更新说明"
```

脚本行为:

1. 自动取 `app/build/outputs/apk/preview/debug/app-preview-debug.apk`(可用 `--apk` 覆盖)。
2. 用 `apkanalyzer` 从 APK 实读版本号(读不到时回退脚本内 env 映射)。
3. 先上传 APK 到 `preview/android/lobster-input-<versionName>.apk`,再上传 `preview/android/update.json`。
4. `--env preview` **不会**写任何旧路径(`android/preview/update.json` 是 uat 迁移桥,与本环境无关)。

Android 发布文档自包含 R2 上传配置。uat/preview/prod 更新文件复用同一个 R2 bucket,通过 `uat/android/`、`preview/android/`(及占位 `android/prod/`)前缀隔离;不要再到 Mac 或 Windows 发布文档查 Android 上传参数。开发阶段为了换机可发布,按团队要求在本文档明文备份;正式上线前必须统一轮换。

```bash
export R2_ACCOUNT_ID="YOUR_CLOUDFLARE_ACCOUNT_ID"
export R2_ENDPOINT="https://YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
export R2_BUCKET="lobster-mac"
export R2_KEY_ID="YOUR_SECRET_FROM_SECRET_STORE"
export R2_SECRET="YOUR_SECRET_FROM_SECRET_STORE"
export PUBLIC_BASE="https://downloads.example.com"
```

## 签名要求

Android 更新安装必须使用与当前已安装应用相同的包名和签名。preview 与 uat 共用同一 debug 签名(既有约定,不能改签名;两环境同包名同签名,靠 R2 前缀与内置 feed 区分),证书指纹如下:

```text
Signer #1 certificate DN: C=US, O=Android, CN=Android Debug
Signer #1 certificate SHA-256 digest: 00ef3d033cbe579ddf498e5cfd9d3e7dde1424c9be8a0b52e29fdbf57d2dc8c4
Signer #1 certificate SHA-1 digest: 2c660b147301d4b06f97051773cd9a6dc7097b6f
```

发布新的 preview APK 前,必须先拿到生成该证书的原始 keystore。APK 里只能读取证书公钥指纹,不能从历史 APK 反推出私钥,也不能用另一台机器的默认 `debug.keystore` 代替。若 `apksigner verify --print-certs` 输出的 SHA-256 指纹不是上面的值,不允许上传 APK 或更新 `update.json`。

debug keystore 备份要点(路径 `~/.android/debug.keystore`,store/key password 均为 `android`,alias `androiddebugkey`);完整的 keystore base64 备份与新机器恢复命令随环境改名保留在 `android-online-update-release-uat.md` 的“签名要求”章节,两环境共用同一份,不在此重复副本以免两处失同步。

如果需要更换签名,必须明确这是一次不可覆盖安装的断链发布:旧安装包无法通过在线更新升级,只能卸载重装或换包名。应尽快固定专用发布 keystore,并只在发布机或 CI 中使用这份 keystore。

## 验证

1. 内测机安装上一个 preview 版本 APK(`assemblePreviewDebug` 产物)。
2. 通过 `r2_publish.py --env preview` 上传更高 `version_code` 的 APK 和 `update.json`。
3. 打开 App 设置页,确认“关于”区版本行环境徽章显示 **内测版**,再点击“检查更新”。
4. 确认能看到更新说明、下载 APK,并拉起系统安装器。
5. 系统安装器完成后回到 App,再点一次“检查更新”,必须显示“当前已是最新版本”。这一步用于防止当前进程未重启时仍用旧版本号重复提示更新。
6. 如果第 5 步仍提示同一版本更新,立即检查线上 `update.json.version_code` 和 APK manifest `versionCode` 是否一致。
7. 隔离验证:确认本次发布没有触碰 `uat/android/` 与旧路径 `android/preview/update.json`;preview 包内检查更新拉到的 `apk_url` 必须在 `preview/android/` 下。
