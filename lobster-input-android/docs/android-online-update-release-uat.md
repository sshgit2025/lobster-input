# Android 在线更新发布流程 — uat(公测环境)

> 环境体系说明:历史上现网环境曾被称作 "preview/测试环境",实际它一直是对外公测环境,现已正名为 **uat**。真正的 **preview(内测环境)** 是新建环境,发布流程见 `android-online-update-release-preview.md`。两环境的包与清单绝不交叉,本文件只描述 uat。

Android 端使用 App 内“检查更新”入口读取 Cloudflare R2 上的静态 JSON 清单。客户端只内置公开读取地址,不内置 R2 写入密钥。

## 环境概览

| 项 | 值 |
|---|---|
| 环境 | uat(公测,存量老用户所在环境) |
| API 地址 | `https://api.example.com/lobster/` |
| Gradle flavor | `uat` |
| 客户端徽章 | 正式版(Official) |
| R2 前缀 | `uat/android/` |
| 更新源 | `https://downloads.example.com/uat/android/update.json` |
| 当前版本 | versionName `0.0.2` / versionCode `111` |

prod 为未来正式环境占位(`android/prod/` 前缀预留),尚未部署,不在本文范围。

## 构建

uat 包由 `uat` flavor 构建(BASE_URL、更新源、环境徽章均由 `app/build.gradle.kts` 的 productFlavors 注入,禁止手改代码切环境):

```bash
./gradlew assembleUatDebug
# 产物:app/build/outputs/apk/uat/debug/app-uat-debug.apk
```

发布沿用 debug 签名 APK(既有约定,详见下文“签名要求”)。

## 清单格式

`update.json`:

```json
{
  "version_code": 108,
  "version_name": "0.0.1",
  "apk_url": "https://downloads.example.com/uat/android/lobster-input-0.0.1.apk",
  "apk_sha256": "可选，建议填写 APK SHA256",
  "release_notes": "本次更新说明，会显示在 App 更新弹窗中。",
  "force": false,
  "published_at": "2026-07-15T00:00:00Z"
}
```

客户端用 `version_code` 和系统 `PackageManager` 读取到的当前已安装包 versionCode 比较。只有远端更大时才提示更新。不要使用 `BuildConfig.VERSION_CODE` 作为更新判断依据,因为 Android 安装 APK 后当前进程不一定立刻重启,旧进程里的编译期常量可能仍是安装前的版本,容易导致同一个更新反复提示。

## 版本规则

1. **versionCode 全局单调递增,跨环境(uat/preview)绝不复用同一个号**。发新版前先确认另一环境已用到的最大号。
2. **⚠️ uat 首发/迁移桥硬约束:uat 包的 versionCode 必须严格大于「所有历史已发布版本」的最大 versionCode,含旧 preview 通道(R2 旧路径 `android/preview/`)。** 老用户装的旧 preview 包 versionName 虽是 1.0.x,但更新判断只看 versionCode;历史旧 preview 已发到 `versionCode 107`(1.0.103),因此 uat 首发必须 ≥108,否则迁移桥 `update.json` 无法被装了 vc107 的老用户检测为"有新版本"(107 不大于 107)。查历史最高号的方法见本文末尾附录。
3. 每次发布必须递增 `versionCode`,即使 `versionName` 不变也必须递增。
3. `update.json.version_code` 必须和 APK manifest 内的 `versionCode` 完全一致。
4. `update.json.version_name` 必须和 APK manifest 内的 `versionName` 完全一致。
5. `apk_url` 指向的 APK 包名必须和当前客户端包名一致;`apk_url` 必须指向 `uat/android/` 下的包,永不指向 preview(内测环境)的包。
6. 先上传 APK,再上传引用该 APK 的 `update.json`;不要提前发布指向不存在或旧 APK 的清单。
7. 如果发现线上清单误发,优先修正 `update.json`,不要通过客户端兼容错误清单。
8. uat 首发版本为 `0.0.1 / versionCode 108`(versionName 显示回退已被接受,更新判断只看 versionCode;108 高于历史旧 preview 最高的 vc107,保证迁移桥能覆盖所有老用户)。

版本号唯一事实源:`app/build.gradle.kts` 中 `productFlavors { create("uat") { versionCode / versionName } }`;发新版时同步更新 `tools/release/r2_publish.py` 的 `ENV_VERSIONS` 兜底映射。

## Gradle 下载源

发布前如果 Gradle Wrapper 卡在下载 `services.gradle.org`,优先切换国内镜像再构建。当前推荐腾讯云 Gradle 镜像:

```properties
distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-8.7-bin.zip
```

如果腾讯云镜像不可用,可换成其他国内 Gradle 镜像并先用 `HEAD` 请求确认可访问。不要在海外下载源长时间等待,避免发布过程卡死。

## 发布前 APK 反查

发布前必须用本地 APK 反查 manifest,确认清单和 APK 一致:

```bash
APK="app/build/outputs/apk/uat/debug/app-uat-debug.apk"
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
- `apksigner` 输出的证书指纹必须和当前已安装老用户版本一致(见“签名要求”)
- `apk_sha256` 等于 `shasum -a 256` 的输出

## 上传(r2_publish.py)

统一使用参数化发布脚本 `tools/release/r2_publish.py`:

```bash
python3 tools/release/r2_publish.py --env uat --notes "本次更新说明"
```

脚本行为:

1. 自动取 `app/build/outputs/apk/uat/debug/app-uat-debug.apk`(可用 `--apk` 覆盖)。
2. 用 `apkanalyzer` 从 APK 实读版本号(读不到时回退脚本内 env 映射)。
3. 先上传 APK 到 `uat/android/lobster-input-<versionName>.apk`,再上传 `uat/android/update.json`。
4. **额外把同一份 manifest 镜像写到旧路径 `android/preview/update.json`**(老用户迁移桥,见下节)。

Android 发布文档自包含 R2 上传配置。uat/preview/prod 更新文件复用同一个 R2 bucket,通过 `uat/android/`、`preview/android/`(及占位 `android/prod/`)前缀隔离;不要再到 Mac 或 Windows 发布文档查 Android 上传参数。开发阶段为了换机可发布,按团队要求在本文档明文备份;正式上线前必须统一轮换。

```bash
export R2_ACCOUNT_ID="YOUR_CLOUDFLARE_ACCOUNT_ID"
export R2_ENDPOINT="https://YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
export R2_BUCKET="lobster-mac"
export R2_KEY_ID="YOUR_SECRET_FROM_SECRET_STORE"
export R2_SECRET="YOUR_SECRET_FROM_SECRET_STORE"
export PUBLIC_BASE="https://downloads.example.com"
```

## 老用户迁移桥(旧 feed 只镜像 uat)

已发布的存量老用户(1.0.x 时代)客户端内置的旧更新源是:

```
https://downloads.example.com/android/preview/update.json
```

迁移约定:

1. 所有存量老用户全部迁移到 uat(公测环境),不迁 preview。
2. 每次发布 uat 时,`r2_publish.py --env uat` 会把同一份 manifest 同步镜像写入旧路径 `android/preview/update.json`,其中 `apk_url` 指向 `uat/android/` 下的 APK。
3. **旧路径 `android/preview/update.json` 此后只镜像 uat 内容,永不放 preview(内测环境)内容**;旧文件不得删除。
4. 老用户通过旧 feed 升级到 uat 包后,新包内置的 feed 已是 `uat/android/update.json`,后续更新自动走新路径。

## 签名要求

Android 更新安装必须使用与当前已安装应用相同的包名和签名。存量老用户安装的是 debug 签名包,因此 **uat 发布沿用 debug 签名 APK(既有约定,不能改签名)**;更新 APK 必须是同一 debug 签名。

线上稳定链路以 `1.0.29 / versionCode 33` 为基准签名(该签名链随环境改名迁移进入 uat,保持不变),证书指纹如下:

```text
Signer #1 certificate DN: C=US, O=Android, CN=Android Debug
Signer #1 certificate SHA-256 digest: 00ef3d033cbe579ddf498e5cfd9d3e7dde1424c9be8a0b52e29fdbf57d2dc8c4
Signer #1 certificate SHA-1 digest: 2c660b147301d4b06f97051773cd9a6dc7097b6f
```

发布新的 uat APK 前,必须先拿到生成该证书的原始 keystore。APK 里只能读取证书公钥指纹,不能从历史 APK 反推出私钥,也不能用另一台机器的默认 `debug.keystore` 代替。若 `apksigner verify --print-certs` 输出的 SHA-256 指纹不是上面的值,不允许上传 APK 或更新 `update.json`。

当前 debug keystore 备份如下(随环境改名保留,uat/preview 两环境共用同一签名):

| 项目 | 值 |
|------|----|
| 本机路径 | `~/.android/debug.keystore` |
| store password | `android` |
| key alias | `androiddebugkey` |
| key password | `android` |
| 证书 DN | `C=US, O=Android, CN=Android Debug` |
| SHA-256 | `00ef3d033cbe579ddf498e5cfd9d3e7dde1424c9be8a0b52e29fdbf57d2dc8c4` |
| SHA-1 | `2c660b147301d4b06f97051773cd9a6dc7097b6f` |

新机器恢复发布签名:

```bash
mkdir -p ~/.android
cat > /tmp/lobster-debug.keystore.b64 <<'EOF'
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
EOF
base64 -D -i /tmp/lobster-debug.keystore.b64 -o ~/.android/debug.keystore
chmod 600 ~/.android/debug.keystore
keytool -list -v -keystore ~/.android/debug.keystore -storepass android -alias androiddebugkey | egrep 'SHA1:|SHA256:'
```

如果需要更换签名,必须明确这是一次不可覆盖安装的断链发布:旧安装包无法通过在线更新升级,只能卸载重装或换包名。应尽快固定专用发布 keystore,并只在发布机或 CI 中使用这份 keystore。

## 验证

1. 安装旧版本 APK(存量老用户旧包或上一个 uat 包)。
2. 通过 `r2_publish.py --env uat` 上传更高 `version_code` 的 APK 和 `update.json`。
3. 打开 App 设置页,确认“关于”区版本行环境徽章显示 **正式版**,再点击“检查更新”。
4. 确认能看到更新说明、下载 APK,并拉起系统安装器。
5. 系统安装器完成后回到 App,再点一次“检查更新”,必须显示“当前已是最新版本”。这一步用于防止当前进程未重启时仍用旧版本号重复提示更新。
6. 如果第 5 步仍提示同一版本更新,立即检查线上 `update.json.version_code` 和 APK manifest `versionCode` 是否一致。
7. 迁移桥验证:用内置旧 feed(`android/preview/update.json`)的老版本 App 检查更新,必须能升级到本次 uat 包。

## 附录:查历史已发布的最高 versionCode

发 uat 迁移桥包前,必须确认 versionCode 高于所有历史发布(尤其旧 preview 通道)。用 R2 凭证列出旧路径的历史包命名(命名里带 `vcNN`),取最大值:

```bash
python3 - <<'PY'
import boto3
from botocore.config import Config
s3 = boto3.client("s3", endpoint_url="https://YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com",
    aws_access_key_id="YOUR_SECRET_FROM_SECRET_STORE",
    aws_secret_access_key="YOUR_SECRET_FROM_SECRET_STORE",
    region_name="auto", config=Config(signature_version="s3v4"))
import re
mx = 0
for pfx in ["android/preview/", "uat/android/", "preview/android/"]:
    for o in s3.list_objects_v2(Bucket="lobster-mac", Prefix=pfx).get("Contents", []):
        m = re.search(r"vc(\d+)", o["Key"])
        if m: mx = max(mx, int(m.group(1)))
print("历史最高 versionCode(命名可见):", mx)
PY
```

注:早期部分包命名未带 `vcNN`(只有 versionName),对这些包按 `versionName 1.0.N → versionCode N+4` 的历史规律换算(如 1.0.103 → vc107)。取两者最大值 +1 作为下一个包的 versionCode。
