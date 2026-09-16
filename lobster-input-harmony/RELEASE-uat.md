# 鸿蒙端发布文档 — uat(公测环境,正式版)

每次发 uat 版本照本文档从上往下执行。preview(内测环境)发布见 `RELEASE-preview.md`,两环境内容不混用。

## 〇、环境信息

| 项 | 值 |
|---|---|
| 环境标识 | `uat`(历史上曾叫 "preview",已正名) |
| API 地址 | `https://api.example.com/lobster/` |
| 更新 feed | `https://downloads.example.com/uat/harmony/update.json` |
| 客户端徽章 | 正式版(Official),由 `ApiConfig.ENVIRONMENT` 派生 |
| 包名 | `com.lobster.input`(与 preview 相同,靠 versionCode 区分) |

## 一、本机环境与材料路径(固定,勿移动)

| 材料 | 路径 | 说明 |
|---|---|---|
| 鸿蒙命令行工具链 | `~/harmonyos/command-line-tools/` | hvigor 6.21.1 + HarmonyOS 6.0.1 SDK(API 21),免安装解压版,无需 sudo |
| 签名密钥库 | `~/harmonyos/signing/lobster.p12` | ECC P-256,别名 `lobster`。**丢失无法找回,建议异地备份** |
| 密钥库密码 | `~/harmonyos/signing/PASSWORD.txt` | 明文单行,权限 600。**不进 git** |
| 证书请求文件 | `~/harmonyos/signing/lobster.csr` | 由 p12 生成,AGC 申请新证书时上传它 |
| 发布证书 | `~/harmonyos/signing/lobster_re.cer` | AGC「证书」页签发(个人账号限 1 个发布证书) |
| 发布 Profile | `~/harmonyos/signing/lobster_re.p7b` | AGC「Profile」页签发,类型=发布,绑定包名 `com.lobster.input` |

注意:hvigor 集成签名只认 DevEco 加密密文密码,命令行明文不被支持——所以本项目签名走 `scripts/release.sh` 里的 `hap-sign-tool` 手动签名,`build-profile.json5` 的 `signingConfigs` 保持为空,不要往里填明文密码。

## 二、版本号规范

- `versionCode` **全局单调递增,跨环境(uat/preview)不复用同一个号**,AGC 按它判断升级。
- 本轮 uat 版本映射:`versionName = 0.0.1`,`versionCode = 107`(preview 为 1.0.103/108)。
- 版本映射维护在 `scripts/release.sh` 顶部,发新版时更新脚本里的映射(或用环境变量 `VERSION_NAME`/`VERSION_CODE` 覆盖);仓库里 `AppScope/app.json5` 由脚本临时改写并自动恢复,不需要手改。

## 三、发新版本流程

1. **确认版本映射**:检查 `scripts/release.sh` 中 uat 的 `VERSION_NAME`/`VERSION_CODE` 是本次要发的号(versionCode 必须比两环境线上任何已用号都大)。
2. **一键打包**:
   ```bash
   scripts/release.sh uat
   ```
   脚本自动完成:临时把 `ApiConfig.ets` 的 `ACTIVE_ENV` 切到 `uat`、临时改 `AppScope/app.json5` 版本号 → release 编译未签名 App Pack → `hap-sign-tool` 对 **.app 整包**签名 → 恢复被临时修改的源文件(失败也会恢复)。
   产物:`dist/lobster-input-<版本号>-uat-signed.app`。
   注意:AGC 校验的是 .app 整包签名;只签内部 hap 再手工组包会报**错误码 991(非法软件包)**,别改回那种做法。
3. **上传 AGC**:[AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html) → 我的应用 → 龙虾输入法 → 版本信息 → 上传 `.app` 包 → 填更新说明 → 提交审核。
   - **同一 bundleName 两环境包并存**:uat 与 preview 包名相同,仅 versionCode 不同;把哪个环境的包投到哪个通道(正式发布 / 邀请测试)由发布人自行选择,勿把 preview(内测)包提交正式上架。
   - **邀请测试**(灰度):左侧「测试」→ 邀请测试 → 维护测试用户华为账号名单 → 提交测试审核,通过后测试用户收到链接安装。
   - **正式发布**:版本信息页直接提交上架审核。
4. **更新 feed**:发布后更新 `uat/harmony/update.json`(R2,bucket=lobster-mac),内容为本次 versionName/versionCode;**此 feed 永不指向 preview 的包/清单**。
   - **老用户迁移桥**:已发布老用户的旧 feed `android/preview/update.json` 在发布 uat 时同步镜像本次清单(此旧文件此后只镜像 uat,永不放 preview 内容,且不得删除)。
5. **提交代码**:版本映射等变更 commit 并 push 到 `origin master`(https://example.com/your-organization/lobster-input-huawei.git)。

## 四、证书过期/更换流程

发布证书有效期 3 年,Profile 有效期以 AGC 签发为准(通常 1 年,过期只需重新签发 Profile,不用换证书):

1. 只换 Profile:AGC → Profile → 用原证书新增发布 Profile → 下载覆盖 `~/harmonyos/signing/lobster_re.p7b`。
2. 换证书:AGC 吊销旧证书 → 用 `lobster.csr` 重新申请 → 下载覆盖 `lobster_re.cer`,并按 1 重签 Profile。
3. p12 丢失才需要重造密钥(会连带换证书和 Profile):
   ```bash
   TOOL=~/harmonyos/command-line-tools/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar
   java -jar $TOOL generate-keypair -keyAlias lobster -keyAlg ECC -keySize NIST-P-256 \
     -keystoreFile ~/harmonyos/signing/lobster.p12 -keyPwd <密码> -keystorePwd <密码>
   java -jar $TOOL generate-csr -keyAlias lobster -signAlg SHA256withECDSA \
     -subject "C=CN,O=lobster,OU=mobile,CN=lobster-input" \
     -keystoreFile ~/harmonyos/signing/lobster.p12 -keyPwd <密码> -keystorePwd <密码> \
     -outFile ~/harmonyos/signing/lobster.csr
   ```

## 五、遗留注意事项

- **后端平台标识**:2026-07 起后端已支持 `harmony` 独立平台,客户端 `X-Client-Platform: harmony`、音频走 `api/v*/audio/harmony/*`、快捷改写走 `text/harmony/quick-action`;登录态按平台隔离(与安卓设备互不踢线)。头与路径必须配套,混用会被 403 CLIENT_PLATFORM_MISMATCH 拦截。
- 测试设备要求:**纯血鸿蒙(HarmonyOS NEXT / 5.0+)**;鸿蒙 4.x 及以下装安卓 APK。
