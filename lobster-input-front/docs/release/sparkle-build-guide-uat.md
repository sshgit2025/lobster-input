# Sparkle 构建与上传指南 — uat（公测环境 · 正式版）

> 最后更新：2026-07-15
> 本文档只覆盖 **uat 环境**（原 "preview" 现网环境，域名 example.com，徽章"正式版"）。
> preview（内测环境，example.net）的发布流程见 `sparkle-build-guide-preview.md`，两环境内容绝不混用。

---

## 〇、环境定位

| 项 | 值 |
|------|-----|
| 环境名 | uat（公测环境，历史上曾叫 "preview/测试环境"，2026-07 正名） |
| API 域名 | `https://api.example.com/lobster` |
| 客户端徽章 | 正式版（Official） |
| APIConfig.environment | `.uat` |
| SUFeedURL / appcast | `https://downloads.example.com/uat/mac/appcast-standard.xml` |
| R2 包路径 | `uat/mac/voice-input-<ver>-b<build>.zip` |
| 老用户迁移桥 | 旧 feed 根路径 `appcast-standard-testing.xml` 同步镜像 uat（见第六节） |

### 环境切换步骤（发布 uat 包前必做）

日常开发代码默认停留在 preview 环境。打 uat 包前，先切换两处配置：

```bash
FRONT="/Users/your-user/workspace/swiftProjects/lobster-input/lobster-input-front"

# 1. APIConfig 当前激活环境 → .uat
perl -pi -e 's/static let environment: AppEnvironment = \.\w+/static let environment: AppEnvironment = .uat/' \
  "$FRONT/voice-input/Core/Network/APIConfig.swift"

# 2. Info.plist 的 SUFeedURL → uat 通道
/usr/libexec/PlistBuddy -c \
  'Set :SUFeedURL https://downloads.example.com/uat/mac/appcast-standard.xml' \
  "$FRONT/voice-input/Info.plist"

# 3. 确认两处已切换
grep 'static let environment' "$FRONT/voice-input/Core/Network/APIConfig.swift"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$FRONT/voice-input/Info.plist"
```

> ⚠️ 两处必须一起切换：`APIConfig.environment` 决定后端域名与徽章文案，`SUFeedURL` 决定 Sparkle 更新通道。只切一处会造成"正式版客户端收内测更新"或反之。
>
> ⚠️ 发布完成后按同样方式**切回 `.preview`** 和 preview 的 SUFeedURL（见 4.3 节），保证日常开发默认 preview。

---

## 一、账户与密钥信息

### Cloudflare R2

| 项目 | 值 |
|------|-----|
| 账户 ID | `YOUR_CLOUDFLARE_ACCOUNT_ID` |
| 桶名称 | `lobster-mac` |
| S3 端点 | `https://YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com` |
| S3 访问密钥 ID | `YOUR_SECRET_FROM_SECRET_STORE` |
| S3 机密访问密钥 | `YOUR_SECRET_FROM_SECRET_STORE` |
| API 令牌 | `YOUR_CLOUDFLARE_API_TOKEN` |
| 公开访问 URL 前缀 | `https://downloads.example.com` |

### Sparkle EdDSA 签名密钥

| 项目 | 值 |
|------|-----|
| Keychain 账户 | `lobster-input-standard-testing-2026` |
| 公钥（SUPublicEDKey） | `6X7gC+sKhX85momJC5G+a/2PDL88krQSLBlalWRRtnc=` |
| 私钥明文备份 | `YOUR_SECRET_FROM_SECRET_STORE` |
| 私钥存储位置 | 本机 macOS Keychain，同时在本文档明文备份，避免换机后私钥丢失 |
| sign_update 工具 | `~/Library/Developer/Xcode/DerivedData/voice-input-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update` |

> ⚠️ 2026-05-07 起使用上表新密钥，必须保证 `voice-input/Info.plist` 的 `SUPublicEDKey` 与这里的公钥一致。uat 与 preview 共用同一把 EdDSA 密钥。
>
> ⚠️ 本文档按团队要求明文备份 Sparkle 私钥。仓库如需外发、开源或交给第三方审计，必须先移除或轮换该私钥。

### Apple Developer

| 项目 | 值 |
|------|-----|
| Apple ID | 见本机 1Password |
| Team ID | `YOUR_TEAM_ID` |
| App 专用密码（notarytool） | 见本机 1Password，在 appleid.apple.com 生成 |

### Developer ID 证书与云托管签名（2026-07-12 补充,重要）

- `xcodebuild archive` 成功只说明 **Apple Development** 证书可用,**不代表**能完成发布——
  发布产物由 `xcodebuild -exportArchive`(method=developer-id)签名,需要 **Developer ID Application: YOUR_DEVELOPER_NAME (YOUR_TEAM_ID)
- 本机钥匙串损坏/重置后,`security find-identity -v -p codesigning` 里**看不到 Developer ID 身份属于正常情况**:
  该证书走 **Xcode 云托管签名**(Xcode 14+),export 时由 Apple 服务端签名,不落本机钥匙串。
- 若 export 报 `The request timed out` 且随后 `No signing certificate "Developer ID Application" found`:
  这是访问苹果云签名服务**网络超时的连带报错**,不是证书真的丢了。
  **处理方式:直接重试 `xcodebuild -exportArchive`(archive 无需重跑,产物可复用)**,通常第二次即成功。
- 只有当重试多次仍失败、且开发者账号里确无 Developer ID 证书时,才需要到
  developer.apple.com / Xcode → Settings → Accounts → Manage Certificates 重新签发。

---

## 二、版本号管理规范（uat）

| 字段 | uat 规则 |
|------|----------|
| `MARKETING_VERSION` | uat 正式版从 **0.0.1** 首发（版本号体系重置；Sparkle 按 build 号比较新旧，0.0.1 的显示回退已被用户接受）。此后按语义化版本升级：新功能升 Minor，bug 修复升 Patch |
| `CURRENT_PROJECT_VERSION`（Build） | **全局单调递增，跨环境（uat/preview）绝不复用同一个号**。uat 首发为 **220**；后续任何环境的下一个包都从两环境已用的最大 build 号 +1 |

```
Major.Minor.Patch

Major — 重大架构变化（很少动）
Minor — 交付给用户的新功能上线
Patch — 对用户可见的 bug 修复
```

> ⚠️ Build 号只升不降、跨环境不复用。历史 testing 渠道已用到 b219，故 uat 首发 = b220，preview 首发 = b221，后续继续全局递增。
> 打包前先查看本文档和 `sparkle-build-guide-preview.md` 的版本台账，取两者最大 build 号 +1。

---

## 三、R2 桶目录结构（uat 通道）

```
lobster-mac/
├── uat/
│   └── mac/
│       ├── appcast-standard.xml            ← uat 正式版 feed
│       └── voice-input-<ver>-b<build>.zip  ← uat 安装包
├── preview/mac/...                          ← preview 内测通道（见 preview 文档，勿混用）
├── appcast-standard-testing.xml             ← 【历史·迁移桥】旧 feed，只镜像 uat 内容（见第六节）
├── appcast-standard-new.xml / appcast-standard.xml / appcast-diy*.xml ← 历史文件，已冻结，勿删
└── standard/voice-input-*.zip               ← 历史包，勿删（旧 feed 的历史条目仍指向这里）
```

**硬性要求：uat 与 preview 的包和清单绝不交叉；uat feed 里的 enclosure URL 永远只指向 `uat/mac/` 下的包。**

---

## 四、发版完整流程（uat）

### 4.1 全自动发布命令

> 前提：本机已登录 Apple Developer 账号，钥匙串里有 `Developer ID Application: YOUR_DEVELOPER_NAME (YOUR_TEAM_ID)` 证书，且能访问 R2。
> **执行前必须先完成第〇节的环境切换（`.uat` + uat SUFeedURL）。**
>
> 命令行 `archive` 阶段可能仍显示 Apple Development 签名，这是 Xcode 自动签名的中间结果；**只有 `xcodebuild -exportArchive` 导出的 App 才是 Sparkle 发布产物**，必须通过下面的 Developer ID 校验后才能上传。

```bash
set -euo pipefail

ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
FRONT="$ROOT/lobster-input-front"

# uat 首发 0.0.1 / b220；后续发布按第二节规范取号
VERSION="0.0.1"
BUILD="220"
APPCAST_KEY="uat/mac/appcast-standard.xml"                 # R2 对象 key
LEGACY_APPCAST_KEY="appcast-standard-testing.xml"          # 老用户迁移桥（根路径旧 feed）
APPCAST_TITLE="龙虾输入法 Standard UAT Updates"
APPCAST_DESCRIPTION="龙虾输入法 standard 正式版更新（uat 公测环境）"
RELEASE_HEADING="${VERSION} 更新内容 (Build ${BUILD})"
ZIP_NAME="voice-input-${VERSION}-b${BUILD}.zip"
PUBLIC_BASE="https://downloads.example.com"
ZIP_URL="${PUBLIC_BASE}/uat/mac/${ZIP_NAME}"

RELEASE_NOTES_HTML='<ul>
  <li>本次更新内容。</li>
</ul>'

ARCHIVE="$ROOT/build/mac/龙虾输入法-${VERSION}-b${BUILD}.xcarchive"
EXPORT_DIR="$ROOT/build/mac/export-b${BUILD}"
EXPORT_OPTIONS="$ROOT/build/mac/ExportOptions-b${BUILD}.plist"
APP="$EXPORT_DIR/龙虾输入法.app"
ZIP="$ROOT/$ZIP_NAME"
APPCAST_FRONT="$FRONT/build/appcast-standard-uat.xml"
APPCAST_DOCS="$FRONT/docs/release/appcast-standard-uat.xml"

cd "$FRONT"

# 环境守门：确认已切到 uat，防止把 preview 配置打进正式版包
grep -q 'static let environment: AppEnvironment = .uat' voice-input/Core/Network/APIConfig.swift
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' voice-input/Info.plist | grep -q 'uat/mac/appcast-standard.xml'

perl -0pi -e "s/CURRENT_PROJECT_VERSION = \\d+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" voice-input.xcodeproj/project.pbxproj
perl -0pi -e "s/MARKETING_VERSION = [0-9.]+;/MARKETING_VERSION = ${VERSION};/g" voice-input.xcodeproj/project.pbxproj

rm -rf "$ARCHIVE" "$EXPORT_DIR"
mkdir -p "$ROOT/build/mac" "$FRONT/build"
cat > "$EXPORT_OPTIONS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

xcodebuild archive \
  -project "$FRONT/voice-input.xcodeproj" \
  -scheme voice-input \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

plutil -p "$APP/Contents/Info.plist" | egrep 'CFBundleShortVersionString|CFBundleVersion|SUFeedURL|SUPublicEDKey'
# 产物必须指向 uat feed
plutil -p "$APP/Contents/Info.plist" | grep 'uat/mac/appcast-standard.xml'
codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO=$(codesign -dv --verbose=4 "$APP" 2>&1)
printf '%s\n' "$SIGN_INFO" | egrep 'Authority|TeamIdentifier|Runtime|Identifier'
printf '%s\n' "$SIGN_INFO" | grep 'Authority=Developer ID Application: YOUR_DEVELOPER_NAME (YOUR_TEAM_ID)
printf '%s\n' "$SIGN_INFO" | grep 'TeamIdentifier=YOUR_TEAM_ID'
spctl --assess --type execute --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SPARKLE_BIN=$(ls -d ~/Library/Developer/Xcode/DerivedData/voice-input-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)
SIGN_OUTPUT=$(printf '%s' 'YOUR_SECRET_FROM_SECRET_STORE' \
  | "$SPARKLE_BIN/sign_update" --ed-key-file - "$ZIP")
echo "$SIGN_OUTPUT"
ED_SIGNATURE=$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
ZIP_LENGTH=$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.* length="\([0-9]*\)".*/\1/p')
test "$ZIP_LENGTH" = "$(stat -f '%z' "$ZIP")"

export VERSION BUILD APPCAST_KEY APPCAST_TITLE APPCAST_DESCRIPTION RELEASE_HEADING ZIP_URL ED_SIGNATURE ZIP_LENGTH RELEASE_NOTES_HTML APPCAST_FRONT APPCAST_DOCS PUBLIC_BASE
python3 - <<'PY'
import email.utils
import os
from pathlib import Path

version = os.environ["VERSION"]
build = os.environ["BUILD"]
zip_url = os.environ["ZIP_URL"]
signature = os.environ["ED_SIGNATURE"]
length = os.environ["ZIP_LENGTH"]
notes = os.environ["RELEASE_NOTES_HTML"]
pub_date = email.utils.formatdate(localtime=True)

appcast = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>{os.environ["APPCAST_TITLE"]}</title>
        <link>{os.environ["PUBLIC_BASE"]}/{os.environ["APPCAST_KEY"]}</link>
        <description>{os.environ["APPCAST_DESCRIPTION"]}</description>
        <language>zh-CN</language>
        <item>
            <title>版本 {version} (Build {build})</title>
            <pubDate>{pub_date}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <description><![CDATA[
                <h3>{os.environ["RELEASE_HEADING"]}</h3>
                {notes}
            ]]></description>
            <enclosure
                url="{zip_url}"
                sparkle:edSignature="{signature}"
                length="{length}"
                type="application/octet-stream"/>
        </item>
    </channel>
</rss>
'''
for target in (Path(os.environ["APPCAST_FRONT"]), Path(os.environ["APPCAST_DOCS"])):
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(appcast, encoding="utf-8")
PY

xmllint --noout "$APPCAST_FRONT"
xmllint --noout "$APPCAST_DOCS"

export R2_ENDPOINT="https://YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
export R2_BUCKET="lobster-mac"
export R2_KEY_ID="YOUR_SECRET_FROM_SECRET_STORE"
export R2_SECRET="YOUR_SECRET_FROM_SECRET_STORE"
export ZIP APPCAST_FRONT APPCAST_KEY LEGACY_APPCAST_KEY ZIP_NAME
python3 - <<'PY'
import os
import boto3
from botocore.config import Config

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["R2_ENDPOINT"],
    aws_access_key_id=os.environ["R2_KEY_ID"],
    aws_secret_access_key=os.environ["R2_SECRET"],
    region_name="auto",
    config=Config(signature_version="s3v4"),
)
bucket = os.environ["R2_BUCKET"]
# 1) 安装包 → uat/mac/
s3.upload_file(os.environ["ZIP"], bucket, f"uat/mac/{os.environ['ZIP_NAME']}",
               ExtraArgs={"ContentType": "application/octet-stream"})
# 2) uat feed
s3.upload_file(os.environ["APPCAST_FRONT"], bucket, os.environ["APPCAST_KEY"],
               ExtraArgs={"ContentType": "application/xml; charset=utf-8"})
# 3) 老用户迁移桥：旧 feed 根路径同步镜像 uat（zip 指向 uat/mac/，见第六节）
s3.upload_file(os.environ["APPCAST_FRONT"], bucket, os.environ["LEGACY_APPCAST_KEY"],
               ExtraArgs={"ContentType": "application/xml; charset=utf-8"})
PY

# 发布后验证：uat feed、迁移桥 feed、zip 三者都要通
curl -sS "$PUBLIC_BASE/$APPCAST_KEY" | egrep 'sparkle:version|sparkle:shortVersionString|enclosure'
curl -sS "$PUBLIC_BASE/$LEGACY_APPCAST_KEY" | egrep 'sparkle:version|sparkle:shortVersionString|enclosure'
curl -sS "$PUBLIC_BASE/$LEGACY_APPCAST_KEY" | grep "uat/mac/${ZIP_NAME}"   # 迁移桥必须指向 uat 包
curl -sSIL "$ZIP_URL" | egrep -i 'HTTP/|content-length|content-type|etag|last-modified'
```

### 4.2 发布后验证

1. 上面脚本末尾几条 `curl` 全部返回正常（两个 feed 均能拉到新 item、zip HTTP 200 且 content-length 与 sign_update 输出一致）。
2. 用一台装有旧 testing 渠道版本（feed=根路径 `appcast-standard-testing.xml`）的机器点击"检查更新..."，应收到 uat 新版本提示并能完成安装（验证迁移桥）。
3. 更新后的 App：主窗口徽章显示**正式版**；设置页版本行显示 `v<ver> (Build <build>) · 正式版`；登录/转写请求走 `api.example.com`。
4. 新装的 uat 包再次"检查更新"应提示已是最新（feed=`uat/mac/appcast-standard.xml`）。

### 4.3 发布后提交与环境复位

```bash
FRONT="/Users/your-user/workspace/swiftProjects/lobster-input/lobster-input-front"

# 1) 切回日常开发默认的 preview 环境
perl -pi -e 's/static let environment: AppEnvironment = \.\w+/static let environment: AppEnvironment = .preview/' \
  "$FRONT/voice-input/Core/Network/APIConfig.swift"
/usr/libexec/PlistBuddy -c \
  'Set :SUFeedURL https://downloads.example.com/preview/mac/appcast-standard.xml' \
  "$FRONT/voice-input/Info.plist"

# 2) 提交版本号与 appcast 备份（.uat 的临时环境切换不进仓库）
git -C "$FRONT" add voice-input.xcodeproj/project.pbxproj
git -C "$FRONT" add docs/release/appcast-standard-uat.xml
git -C "$FRONT" commit -m "Publish Mac standard uat build ${BUILD}"
git -C "$FRONT" push origin feature/standard
```

---

## 五、当前版本状态（uat 台账）

> Build 号全局递增（与 preview 共享号段）。发布 uat 新版本后在此追加一行。

| 版本 | Build | 渠道 | zip | 发布时间 | 说明 |
|------|-------|------|-----|----------|------|
| 0.0.1 | 220 | uat | `uat/mac/voice-input-0.0.1-b220.zip` | 待发布 | uat 正式版首发（版本号体系重置；同步写入迁移桥） |

### 历史台账（旧 testing 渠道，2026-07 环境正名前，已冻结）

<details>
<summary>展开旧 testing 渠道发布记录（根路径 appcast-standard-testing.xml + standard/ 目录，b33–b219）</summary>

| 版本 | Build | 渠道 | zip | 发布时间 | 说明 |
|------|-------|------|-----|----------|------|
| 0.3.5 | 33 | 正式 | `standard/龙虾输入法-0.3.5.zip` | 2026-04-15 | 修复录音崩溃 + 识别为空 |
| 0.3.5 | 38 | testing | `standard/voice-input-0.3.5-b38.zip` | 2026-04-22 | 现网环境（现 uat）切换为域名 HTTPS |
| 0.3.5 | 39 | testing | `standard/voice-input-0.3.5-b39.zip` | 2026-04-24 | 修复选中超长文本时处理逻辑中丢弃文本的 bug |
| 0.3.5 | 40 | testing | `standard/voice-input-0.3.5-b40.zip` | 2026-04-24 | 优化选中文本读取流程，改为并行读取以提升响应速度 |
| 0.3.5 | 41 | testing | `standard/voice-input-0.3.5-b41.zip` | 2026-04-24 | 调整客户端请求超时时间 |
| 0.3.5 | 42 | testing | `standard/voice-input-0.3.5-b42.zip` | 2026-04-24 | 更新词典功能 |
| 0.3.5 | 43 | testing | `standard/voice-input-0.3.5-b43.zip` | 2026-04-27 | 修复教程页面交互 bug、调整词典功能、优化崩溃日志上报 |
| 0.3.5 | 44 | testing | `standard/voice-input-0.3.5-b44.zip` | 2026-04-27 | 新增急速模式 |
| 0.3.5 | 45 | testing | `standard/voice-input-0.3.5-b45.zip` | 2026-04-27 | 套餐定制化 |
| 0.3.5 | 46 | testing | `standard/voice-input-0.3.5-b46.zip` | 2026-04-27 | 优化账户积分展示交互 |
| 0.3.5 | 47 | testing | `standard/voice-input-0.3.5-b47.zip` | 2026-04-27 | QA 测试版验证包（text fill strategy pipeline） |
| 0.3.5 | 48 | testing | `standard/voice-input-0.3.5-b48.zip` | 2026-04-27 | 新增弱音频识别增强策略 |
| 0.3.5 | 49 | testing | `standard/voice-input-0.3.5-b49.zip` | 2026-04-27 | 新增回填事务防重复填充策略 |
| 0.3.5 | 50 | testing | `standard/voice-input-0.3.5-b50.zip` | 2026-04-27 | 修复回填策略不生效的 bug |
| 0.3.5 | 186 | testing | `standard/voice-input-0.3.5-b186.zip` | 2026-06-11 | 重构填充/浮窗决策（快探+盲填确认），判定耗时秒级→毫秒级 |
| 0.3.5 | 187 | testing | `standard/voice-input-0.3.5-b187.zip` | 2026-06-11 | 修复 rewrite 选中文本后既不替换也不弹浮窗的问题（移除 AX 原位替换，统一走 Cmd+V） |
| 0.3.5 | 188 | testing | `standard/voice-input-0.3.5-b188.zip` | 2026-06-11 | 安全/性能加固 + 历史记录重构 |
| 0.3.5 | 189 | testing | `standard/voice-input-0.3.5-b189.zip` | 2026-06-11 | 移除 token/历史迁移兼容代码，改为清旧数据+登出 |
| 0.3.5 | 190 | testing | `standard/voice-input-0.3.5-b190.zip` | 2026-06-11 | 修复浏览器 AX 树未激活时网页输入框（如 Jira 搜索栏）被误判浮窗的问题（noValue 改走盲填确认） |
| 0.3.5 | 191 | testing | `standard/voice-input-0.3.5-b191.zip` | 2026-06-11 | 修复"既填充又浮窗"：录音期用 AXEnhancedUserInterface 预热 Chrome AX 树 + 盲填超时二次复查兜底 |
| 0.3.5 | 192 | testing | `standard/voice-input-0.3.5-b192.zip` | 2026-06-17 | 无需确认截图模式新增滚动截长图（设置中开启，仅同屏，跨屏仍单帧） |
| 0.3.5 | 193 | testing | `standard/voice-input-0.3.5-b193.zip` | 2026-06-17 | 长图模式：修复上下颠倒/接缝错位，改密集采帧（不再要求匀速慢滚）；改名「长图模式」并与二次确认互斥 |
| 0.3.5 | 194 | testing | `standard/voice-input-0.3.5-b194.zip` | 2026-06-17 | 长图模式：每屏独立覆盖层+跟踪鼠标所在屏，发起屏=鼠标屏（对齐二次确认） |
| 0.3.5 | 195 | testing | `standard/voice-input-0.3.5-b195.zip` | 2026-06-17 | 长图模式：拼接改用 Apple Vision 图像配准，修复正常速度滚动失配/只截首屏；预览节流 |
| 0.3.5 | 196 | testing | `standard/voice-input-0.3.5-b196.zip` | 2026-06-17 | 长图模式：亚像素对齐消接缝细线、快滚失配自动重锚恢复（不再卡死）、采集限频控 CPU、超长图预览降频 |
| 0.3.5 | 197 | testing | `standard/voice-input-0.3.5-b197.zip` | 2026-06-17 | 长图模式：消除接缝青色横线（边框入镜）；绝对位置跟踪根治来回滚动内容重复 |
| 0.3.5 | 198 | testing | `standard/voice-input-0.3.5-b198.zip` | 2026-06-17 | 长图模式：底部基准锚定+NCC 互相关校验，彻底根治来回滚动重复（挡住白底误配） |
| 0.3.5 | 199 | testing | `standard/voice-input-0.3.5-b199.zip` | 2026-06-17 | 长图模式：相邻帧跟踪+宽松校验（回归：正向滚动失效，已废弃） |
| 0.3.5 | 200 | testing | `standard/voice-input-0.3.5-b200.zip` | 2026-06-17 | 长图模式：底部基准+ShareX匹配像素占比校验+重叠≥40%门限，命中率高且来回滚动不重复；预览后台缩略图 |
| 0.3.5 | 201 | testing | `standard/voice-input-0.3.5-b201.zip` | 2026-06-17 | 长图模式：失配自动重锚(阈值8)修复"滚几下卡死"+双档校验接受较快滚动；补详细诊断日志 |
| 0.3.5 | 210 | testing | `standard/voice-input-0.3.5-b210.zip` | 2026-07-08 | 登录态改造：配合后端 15 天滑动续期；任意业务请求 401 统一强制登出；退出登录先调服务端 logout 销毁会话 |
| 0.3.5 | 211 | testing | `standard/voice-input-0.3.5-b211.zip` | 2026-07-12 | 套餐补差价升级（月付可升同套餐年付/更高等级，仅付差价）；菜单栏/主菜单人设快捷切换入口 |
| 0.3.5 | 212 | testing | `standard/voice-input-0.3.5-b212.zip` | 2026-07-13 | 套餐升级按钮文案精简为「升级」 |
| 0.3.5 | 214 | testing | `standard/voice-input-0.3.5-b214.zip` | 2026-07-14 | 教程页体验步骤支持跳过（授权页除外）；设置页新增「重新观看教程」入口 |
| 0.3.5 | 215 | testing | `standard/voice-input-0.3.5-b215.zip` | 2026-07-14 | 套餐文案国际化（套餐名改后端多语言下发） |
| 0.3.5 | 216 | testing | `standard/voice-input-0.3.5-b216.zip` | 2026-07-15 | 修复教程「改写·翻译不可编辑文本」步骤浮窗永不出现（skipSystemPaste 改按步骤同步）；fillSelfApp 只读 NSTextView 误判修复 |
| 0.3.5 | 217 | testing | `standard/voice-input-0.3.5-b217.zip` | 2026-07-15 | 修复教程「改写·替换输入框文本」步骤选中内容不被替换（rewriteEditable 移出跳过名单，走真实 Cmd+V 覆盖选区） |
| 0.3.5 | 218 | testing | `standard/voice-input-0.3.5-b218.zip` | 2026-07-15 | 语音快捷键默认值改为 Fn（转写=Fn 单键/改写=Fn+S/智能体=Fn+W）；吞 179 拦系统 Globe 行为；tap 独立线程+看门狗；快捷键冲突检测 |
| 0.3.5 | 219 | testing | `standard/voice-input-0.3.5-b219.zip` | 2026-07-15 | 更新语音快捷键默认值（转写=Fn 单键/改写=Fn+⇧/智能体=Fn+Space）；修复 Fn+修饰键录制丢 Fn 与连环触发 |

</details>

---

## 六、老用户迁移桥（旧 feed → uat，重要）

历史上已发布的用户（旧 testing 渠道，SUFeedURL 指向根路径 `appcast-standard-testing.xml`）全部迁移到 uat 正式版：

- **发布 uat 版本时**（首发 0.0.1/b220 起，之后每次 uat 发布同理），把该版本的 `<item>` **同步写入旧 feed 根路径 `appcast-standard-testing.xml`**，enclosure 的 zip URL 指向 `uat/mac/` 下的包（4.1 脚本第 3 步上传已内置）。
- 旧 feed 此后**只镜像 uat 内容，永不放 preview 内容**——否则老用户会被更新到内测版。
- 旧 feed 文件与 `standard/` 目录下的历史包**不得删除**，否则未升级的旧客户端检查更新会报错。
- 待确认旧渠道用户基本升级完毕后方可停止镜像（届时在本文档记录停止日期）。
