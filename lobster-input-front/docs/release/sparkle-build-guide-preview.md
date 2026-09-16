# Sparkle 构建与上传指南 — preview（内测环境 · 内测版）

> 最后更新：2026-07-15
> 本文档只覆盖 **preview 环境**（2026-07 新建的内测环境，域名 example.net，徽章"内测版"）。
> uat（公测环境，example.com）的发布流程见 `sparkle-build-guide-uat.md`，两环境内容绝不混用。
> **preview 与旧 feed（根路径 appcast-standard-testing.xml）无任何关系**：旧 feed 是老用户迁移桥，只镜像 uat 内容，preview 发布流程不碰它。

---

## 〇、环境定位

| 项 | 值 |
|------|-----|
| 环境名 | preview（内测环境，2026-07 新建；注意与历史上叫 "preview" 的现网环境区分，后者已正名为 uat） |
| API 域名 | `https://api.example.net/lobster`（业务服务器 192.0.2.15） |
| 客户端徽章 | 内测版（Beta） |
| APIConfig.environment | `.preview`（日常开发默认值） |
| SUFeedURL / appcast | `https://downloads.example.com/preview/mac/appcast-standard.xml` |
| R2 包路径 | `preview/mac/voice-input-<ver>-b<build>.zip` |
| 旧 feed | 无关。preview 内容**永不**写入根路径 `appcast-standard-testing.xml` |

### 环境确认步骤（发布 preview 包前必做）

仓库日常状态就是 preview 环境，一般无需切换；但若刚发过 uat 包，务必确认已复位：

```bash
FRONT="/Users/your-user/workspace/swiftProjects/lobster-input/lobster-input-front"

# 若当前不是 preview，用以下命令切换
perl -pi -e 's/static let environment: AppEnvironment = \.\w+/static let environment: AppEnvironment = .preview/' \
  "$FRONT/voice-input/Core/Network/APIConfig.swift"
/usr/libexec/PlistBuddy -c \
  'Set :SUFeedURL https://downloads.example.com/preview/mac/appcast-standard.xml' \
  "$FRONT/voice-input/Info.plist"

# 确认两处一致
grep 'static let environment' "$FRONT/voice-input/Core/Network/APIConfig.swift"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$FRONT/voice-input/Info.plist"
```

> ⚠️ 两处必须一致：`APIConfig.environment` 决定后端域名与徽章文案，`SUFeedURL` 决定 Sparkle 更新通道。不一致会造成"内测客户端收正式更新"或反之。

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

> ⚠️ 2026-05-07 起使用上表新密钥，必须保证 `voice-input/Info.plist` 的 `SUPublicEDKey` 与这里的公钥一致。preview 与 uat 共用同一把 EdDSA 密钥。
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

## 二、版本号管理规范（preview）

| 字段 | preview 规则 |
|------|----------|
| `MARKETING_VERSION` | preview 内测版首发 **0.3.6**（延续旧 testing 渠道 0.3.5 的语义版本线）。内测迭代期间保持不变，只在功能对内可交付时按语义升级 |
| `CURRENT_PROJECT_VERSION`（Build） | **全局单调递增，跨环境（uat/preview）绝不复用同一个号**。preview 首发为 **221**（uat 首发占 220）；后续任何环境的下一个包都从两环境已用的最大 build 号 +1 |

```
Major.Minor.Patch

Major — 重大架构变化（很少动）
Minor — 交付给用户的新功能上线
Patch — 对用户可见的 bug 修复
```

> ⚠️ Build 号只升不降、跨环境不复用。历史 testing 渠道已用到 b219，uat 首发 = b220，preview 首发 = b221，后续继续全局递增。
> 打包前先查看本文档和 `sparkle-build-guide-uat.md` 的版本台账，取两者最大 build 号 +1。

---

## 三、R2 桶目录结构（preview 通道）

```
lobster-mac/
├── preview/
│   └── mac/
│       ├── appcast-standard.xml            ← preview 内测版 feed
│       └── voice-input-<ver>-b<build>.zip  ← preview 安装包
├── uat/mac/...                              ← uat 公测通道（见 uat 文档，勿混用）
├── appcast-standard-testing.xml             ← 旧 feed（uat 迁移桥），preview 发布流程不碰
└── standard/、appcast-*-new.xml 等          ← 历史文件，已冻结，勿删
```

**硬性要求：preview 与 uat 的包和清单绝不交叉；preview feed 里的 enclosure URL 永远只指向 `preview/mac/` 下的包；preview 内容永不写入旧 feed。**

---

## 四、发版完整流程（preview）

### 4.1 全自动发布命令

> 前提：本机已登录 Apple Developer 账号，钥匙串里有 `Developer ID Application: YOUR_DEVELOPER_NAME (YOUR_TEAM_ID)` 证书，且能访问 R2。
> **执行前必须先完成第〇节的环境确认（`.preview` + preview SUFeedURL）。**
>
> 命令行 `archive` 阶段可能仍显示 Apple Development 签名，这是 Xcode 自动签名的中间结果；**只有 `xcodebuild -exportArchive` 导出的 App 才是 Sparkle 发布产物**，必须通过下面的 Developer ID 校验后才能上传。

内测迭代保持 `MARKETING_VERSION` 不变，只递增 `BUILD`。

```bash
set -euo pipefail

ROOT="/Users/your-user/workspace/swiftProjects/lobster-input"
FRONT="$ROOT/lobster-input-front"

# preview 首发 0.3.6 / b221；后续发布按第二节规范取号
VERSION="0.3.6"
BUILD="221"
APPCAST_KEY="preview/mac/appcast-standard.xml"             # R2 对象 key
APPCAST_TITLE="龙虾输入法 Standard Preview Updates"
APPCAST_DESCRIPTION="龙虾输入法 standard 内测版更新（preview 内测环境）"
RELEASE_HEADING="${VERSION} 内测更新 (Build ${BUILD})"
ZIP_NAME="voice-input-${VERSION}-b${BUILD}.zip"
PUBLIC_BASE="https://downloads.example.com"
ZIP_URL="${PUBLIC_BASE}/preview/mac/${ZIP_NAME}"

RELEASE_NOTES_HTML='<ul>
  <li>修复本次内测发现的问题。</li>
</ul>'

ARCHIVE="$ROOT/build/mac/龙虾输入法-${VERSION}-b${BUILD}.xcarchive"
EXPORT_DIR="$ROOT/build/mac/export-b${BUILD}"
EXPORT_OPTIONS="$ROOT/build/mac/ExportOptions-b${BUILD}.plist"
APP="$EXPORT_DIR/龙虾输入法.app"
ZIP="$ROOT/$ZIP_NAME"
APPCAST_FRONT="$FRONT/build/appcast-standard-preview.xml"
APPCAST_DOCS="$FRONT/docs/release/appcast-standard-preview.xml"

cd "$FRONT"

# 环境守门：确认是 preview，防止把 uat 配置打进内测包
grep -q 'static let environment: AppEnvironment = .preview' voice-input/Core/Network/APIConfig.swift
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' voice-input/Info.plist | grep -q 'preview/mac/appcast-standard.xml'

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
# 产物必须指向 preview feed
plutil -p "$APP/Contents/Info.plist" | grep 'preview/mac/appcast-standard.xml'
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
export ZIP APPCAST_FRONT APPCAST_KEY ZIP_NAME
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
# 1) 安装包 → preview/mac/
s3.upload_file(os.environ["ZIP"], bucket, f"preview/mac/{os.environ['ZIP_NAME']}",
               ExtraArgs={"ContentType": "application/octet-stream"})
# 2) preview feed（注意：绝不上传到根路径旧 feed appcast-standard-testing.xml）
s3.upload_file(os.environ["APPCAST_FRONT"], bucket, os.environ["APPCAST_KEY"],
               ExtraArgs={"ContentType": "application/xml; charset=utf-8"})
PY

# 发布后验证
curl -sS "$PUBLIC_BASE/$APPCAST_KEY" | egrep 'sparkle:version|sparkle:shortVersionString|enclosure'
curl -sSIL "$ZIP_URL" | egrep -i 'HTTP/|content-length|content-type|etag|last-modified'
```

### 4.2 发布后验证

1. 上面脚本末尾两条 `curl` 返回正常（feed 能拉到新 item、zip HTTP 200 且 content-length 与 sign_update 输出一致）。
2. 用装有上一个 preview 版本的机器点击"检查更新..."，应收到新版本提示并能完成安装。
3. 更新后的 App：主窗口徽章显示**内测版**；设置页版本行显示 `v<ver> (Build <build>) · 内测版`；登录/转写请求走 `api.example.net`。
4. 根路径旧 feed `appcast-standard-testing.xml` 内容未被本次发布改动（它只属于 uat 迁移桥）。

### 4.3 发布后提交

preview 是日常开发默认环境，发布后无需环境复位，直接提交：

```bash
FRONT="/Users/your-user/workspace/swiftProjects/lobster-input/lobster-input-front"
git -C "$FRONT" add voice-input.xcodeproj/project.pbxproj
git -C "$FRONT" add docs/release/appcast-standard-preview.xml
git -C "$FRONT" commit -m "Publish Mac standard preview build ${BUILD}"
git -C "$FRONT" push origin feature/standard
```

---

## 五、当前版本状态（preview 台账）

> Build 号全局递增（与 uat 共享号段）。发布 preview 新版本后在此追加一行。
> b219 及之前的历史发布记录见 `sparkle-build-guide-uat.md` 的历史台账（旧 testing 渠道）。

| 版本 | Build | 渠道 | zip | 发布时间 | 说明 |
|------|-------|------|-----|----------|------|
| 0.3.6 | 221 | preview | `preview/mac/voice-input-0.3.6-b221.zip` | 待发布 | preview 内测通道首发 |
