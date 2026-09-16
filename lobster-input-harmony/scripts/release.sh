#!/bin/bash
# 龙虾输入法鸿蒙端 一键发布打包脚本(按环境)
# 用法: scripts/release.sh [uat|preview]   (默认 preview)
#   - uat     = 公测环境(正式版, api.example.com, feed uat/harmony/)
#   - preview = 内测环境(api.example.net, feed preview/harmony/)
# 产物: dist/lobster-input-<版本号>-<env>-signed.app (用于上传 AppGallery Connect)
# 前置: ~/harmonyos/signing/ 下有 lobster.p12 / lobster_re.cer / lobster_re.p7b / PASSWORD.txt
#
# 脚本会在构建前临时修改:
#   1. entry/src/main/ets/core/network/ApiConfig.ets 的 ACTIVE_ENV
#   2. AppScope/app.json5 的 versionName / versionCode(按环境版本映射)
# 构建签名完成或任何一步失败后,均通过 trap 恢复原文件。
set -euo pipefail

ENV="${1:-preview}"
case "$ENV" in
  uat|preview) ;;
  *) echo "用法: scripts/release.sh [uat|preview]"; exit 1 ;;
esac

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
CLT="$HOME/harmonyos/command-line-tools"
SIGN_DIR="$HOME/harmonyos/signing"
TOOL_LIB="$CLT/sdk/default/openharmony/toolchains/lib"
DIST="$PROJ/dist"

API_CONFIG="$PROJ/entry/src/main/ets/core/network/ApiConfig.ets"
APP_JSON="$PROJ/AppScope/app.json5"

# 环境版本映射(versionCode 全局单调递增,跨环境不复用;发新版时更新这里)
# 可用环境变量 VERSION_NAME / VERSION_CODE 覆盖
if [ "$ENV" = "uat" ]; then
  VERSION_NAME="${VERSION_NAME:-0.0.1}"
  VERSION_CODE="${VERSION_CODE:-107}"
else
  VERSION_NAME="${VERSION_NAME:-1.0.103}"
  VERSION_CODE="${VERSION_CODE:-108}"
fi

export DEVECO_SDK_HOME="$CLT/sdk"
export PATH="$CLT/bin:$CLT/tool/node/bin:$PATH"

KEY_ALIAS="lobster"
KEYSTORE="$SIGN_DIR/lobster.p12"
CERT="$SIGN_DIR/lobster_re.cer"
PROFILE="$SIGN_DIR/lobster_re.p7b"
PASSWORD="$(cat "$SIGN_DIR/PASSWORD.txt")"

for f in "$KEYSTORE" "$CERT" "$PROFILE" "$SIGN_DIR/PASSWORD.txt"; do
  [ -f "$f" ] || { echo "缺少签名材料: $f"; exit 1; }
done

# ---------- 备份并注册恢复保护(成功/失败都会恢复原文件) ----------
BACKUP_DIR="$(mktemp -d)"
cp "$API_CONFIG" "$BACKUP_DIR/ApiConfig.ets.bak"
cp "$APP_JSON" "$BACKUP_DIR/app.json5.bak"
restore_files() {
  cp "$BACKUP_DIR/ApiConfig.ets.bak" "$API_CONFIG"
  cp "$BACKUP_DIR/app.json5.bak" "$APP_JSON"
  rm -rf "$BACKUP_DIR"
  echo "==> 已恢复 ApiConfig.ets 与 app.json5 原内容"
}
trap restore_files EXIT

# ---------- 切换环境与版本号 ----------
echo "==> 环境 $ENV,版本 $VERSION_NAME ($VERSION_CODE)"
sed -i '' "s/^export const ACTIVE_ENV: string = '[a-z]*';/export const ACTIVE_ENV: string = '$ENV';/" "$API_CONFIG"
grep -q "^export const ACTIVE_ENV: string = '$ENV';" "$API_CONFIG" || { echo "切换 ACTIVE_ENV 失败,请检查 ApiConfig.ets 格式"; exit 1; }
sed -i '' "s/\"versionCode\": [0-9][0-9]*/\"versionCode\": $VERSION_CODE/" "$APP_JSON"
sed -i '' "s/\"versionName\": \"[^\"]*\"/\"versionName\": \"$VERSION_NAME\"/" "$APP_JSON"
grep -q "\"versionCode\": $VERSION_CODE" "$APP_JSON" || { echo "改写 versionCode 失败"; exit 1; }
grep -q "\"versionName\": \"$VERSION_NAME\"" "$APP_JSON" || { echo "改写 versionName 失败"; exit 1; }

echo "==> 1/2 release 编译(未签名 App Pack)"
cd "$PROJ"
hvigorw clean --no-daemon >/dev/null
hvigorw assembleApp --mode project -p product=default -p buildMode=release --no-daemon

UNSIGNED_APP=$(find "$PROJ/build/outputs" -name "*-unsigned.app" | head -1)
[ -n "$UNSIGNED_APP" ] || { echo "未找到未签名 app 包"; exit 1; }

mkdir -p "$DIST"
APP_OUT="$DIST/lobster-input-$VERSION_NAME-$ENV-signed.app"
rm -f "$APP_OUT"

echo "==> 2/2 hap-sign-tool 对整包签名(AGC 校验的是 .app 整包签名,不能只签内部 hap)"
java -jar "$TOOL_LIB/hap-sign-tool.jar" sign-app \
  -mode localSign \
  -keyAlias "$KEY_ALIAS" \
  -signAlg SHA256withECDSA \
  -appCertFile "$CERT" \
  -profileFile "$PROFILE" \
  -keystoreFile "$KEYSTORE" \
  -keyPwd "$PASSWORD" \
  -keystorePwd "$PASSWORD" \
  -inFile "$UNSIGNED_APP" \
  -outFile "$APP_OUT" \
  -signCode 1

echo "==> 完成($ENV):"
ls -lh "$APP_OUT"
