#!/usr/bin/env bash
# =============================================================================
# restart.sh — 客户端编译启动脚本
#
# 使用 Apple 开发者证书自动签名（TeamID: YOUR_TEAM_ID）
# cdhash 每次编译保持稳定，已授权权限无需重复授权
#
# ⚠️ 注意签名：
#    编译后脚本会自动用开发者证书对整个 bundle 重签名（--force --deep）。
#    这是必要的，因为 Xcode 会在签名完成后额外注入调试文件（__preview.dylib 等），
#    导致 bundle sealed resource 校验失败，macOS TCC 无法注册辅助功能权限。
#    重签名使用开发者证书（非 ad-hoc），TeamID/cdhash 不变，已授权权限不受影响。
#    ❌ 禁止使用 codesign --sign -（ad-hoc）：会改变 cdhash，导致所有权限失效。
#
# 使用方式：
#   bash scripts/restart.sh          # 仅重启（不重新编译）
#   bash scripts/restart.sh --build  # 先编译再重启
#
# 注意：编译环境（dev/prod）由 APIConfig.swift 中的 current 字段决定，
#       与本脚本无关，切换环境请修改 APIConfig.swift。
# =============================================================================

BUNDLE_ID="ssh2026.voice-input"
TEAM_ID="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM_ID" ]]; then
    echo "请设置 DEVELOPMENT_TEAM 为自己的 Apple Developer Team ID。" >&2
    exit 1
fi
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_APP=""
latest_app_mtime=0

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${GREEN}▶ $*${NC}"; }

# ── 检查 Apple 开发者证书 ─────────────────────────────────────────────────────
APPLE_CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1)
if [[ -n "$APPLE_CERT" ]]; then
    info "✓ Apple 开发者证书就绪（TeamID: $TEAM_ID）"
    info "  cdhash 稳定，已授权权限无需重新授权"
else
    warn "未找到 Apple Development 证书"
    warn "请在 Xcode → Settings → Accounts 中登录开发者账号并创建证书"
    exit 1
fi

# ── 1. 可选：重新编译 ─────────────────────────────────────────────────────────
if [[ "$1" == "--build" ]]; then
    section "清空编译缓存（避免分支切换后残留旧产物）..."
    cd "$PROJECT_ROOT"
    xcodebuild \
        -project voice-input.xcodeproj \
        -scheme voice-input \
        -configuration Debug \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        clean \
        2>&1 | grep -E "error:|CLEAN (SUCCEEDED|FAILED)"

    section "编译项目（自动签名）..."
    BUILD_LOG=$(xcodebuild \
        -project voice-input.xcodeproj \
        -scheme voice-input \
        -configuration Debug \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        build \
        2>&1)
    BUILD_EXIT=$?
    echo "$BUILD_LOG" | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

    if [[ $BUILD_EXIT -ne 0 ]]; then
        error "编译失败，请检查错误信息"
        exit 1
    fi

    BUILD_SETTINGS=$(xcodebuild \
        -project voice-input.xcodeproj \
        -scheme voice-input \
        -configuration Debug \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        -showBuildSettings 2>/dev/null)
    BUILT_PRODUCTS_DIR=$(echo "$BUILD_SETTINGS" | awk -F'= ' '/^[[:space:]]*BUILT_PRODUCTS_DIR = / {print $2; exit}')
    WRAPPER_NAME=$(echo "$BUILD_SETTINGS" | awk -F'= ' '/^[[:space:]]*WRAPPER_NAME = / {print $2; exit}')
    DERIVED_DATA_APP="$BUILT_PRODUCTS_DIR/$WRAPPER_NAME"

    # ── 编译后补签名 ───────────────────────────────────────────────────────────
    # xcodebuild 完成签名后，Xcode 会额外注入 __preview.dylib（SwiftUI Preview）
    # 和 *.debug.dylib（Swift 调试运行时），这些文件在签名之后注入，导致
    # bundle sealed resource 校验失败，macOS TCC 拒绝将 App 注册到辅助功能列表。
    # 用开发者证书对整个 bundle 重签名（--force --deep），将注入文件纳入签名。
    # 注意：使用开发者证书（非 ad-hoc），TeamID 不变，cdhash 稳定，已授权权限不受影响。
    ENTITLEMENTS="$PROJECT_ROOT/voice-input/voice-input.entitlements"
    # 取证书 SHA-1 哈希作为签名身份(第二列),比解析引号内名字可靠
    CERT_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Apple Development" | head -1 | awk '{print $2}')
    section "补签名（纳入调试注入文件，修复 TCC 辅助功能注册）..."
    codesign --force --deep --sign "$CERT_IDENTITY" \
        --entitlements "$ENTITLEMENTS" \
        "$DERIVED_DATA_APP" 2>&1
    if codesign --verify --deep "$DERIVED_DATA_APP" 2>/dev/null; then
        info "✓ 重签名完成，TCC 辅助功能注册可正常工作"
    else
        warn "签名校验仍有警告（通常是 Xcode 调试文件导致，不影响运行）"
    fi
fi

# ── 2. 检查 App 是否存在 ──────────────────────────────────────────────────────
if [[ -z "$DERIVED_DATA_APP" ]]; then
    while IFS= read -r app_path; do
        [[ "$app_path" == *".dSYM"* || "$app_path" == *"Updater"* || "$app_path" == *"Autoupdate"* ]] && continue
        app_mtime=$(stat -f "%m" "$app_path" 2>/dev/null || echo 0)
        if [[ -z "$DERIVED_DATA_APP" || "$app_mtime" -gt "$latest_app_mtime" ]]; then
            DERIVED_DATA_APP="$app_path"
            latest_app_mtime="$app_mtime"
        fi
    done < <(find ~/Library/Developer/Xcode/DerivedData/voice-input-*/Build/Products/Debug \
        -name "*.app" -maxdepth 1 2>/dev/null)
fi
if [[ -z "$DERIVED_DATA_APP" || ! -d "$DERIVED_DATA_APP" ]]; then
    error "找不到编译产物，请先使用 --build 参数"
    exit 1
fi
info "App 路径: $DERIVED_DATA_APP"

# ── 验证签名中的 TeamID ──────────────────────────────────────────────────────
SIGNED_TEAM=$(codesign -dv "$DERIVED_DATA_APP" 2>&1 | grep TeamIdentifier | awk -F= '{print $2}')
if [[ "$SIGNED_TEAM" == "$TEAM_ID" ]]; then
    info "✓ 签名 TeamIdentifier = $SIGNED_TEAM"
else
    warn "签名 TeamIdentifier = ${SIGNED_TEAM:-未设置}（期望 $TEAM_ID）"
    warn "输入监控权限可能需要重新授权"
fi

# ── 3. 停止旧客户端 ───────────────────────────────────────────────────────────
section "停止客户端..."
# 注意：macOS pgrep 不支持 \| 作为 OR，需用多次 pgrep 或 -E 扩展模式
APP_PID=$(pgrep -f "龙虾输入法" 2>/dev/null || true)
if [[ -z "$APP_PID" ]]; then
    APP_PID=$(pgrep -f "voice-input" 2>/dev/null || true)
fi
if [[ -n "$APP_PID" ]]; then
    kill $APP_PID 2>/dev/null || true
    sleep 2
    # 确认进程已退出
    if pgrep -f "龙虾输入法" &>/dev/null || pgrep -f "voice-input" &>/dev/null; then
        warn "进程未退出，尝试强制终止..."
        kill -9 $APP_PID 2>/dev/null || true
        sleep 1
    fi
    info "已终止旧进程 (PID: $APP_PID)"
else
    info "无正在运行的进程"
fi

# ── 4. 重置输入监控权限 ───────────────────────────────────────────────────────
# Apple 开发者证书签名下，cdhash 稳定，只需在首次安装/首次授权时重置一次
# 此后每次编译重启均不需要重置（TeamID 不变，系统认为是同一个 App）
# 注释掉下行可跳过重置（适合日常开发迭代）
# tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null

section "权限状态（Apple 开发者证书，cdhash 稳定）..."
info "✓ 已有权限授权继续有效，无需重新授权"
info "  如需重置输入监控授权，手动执行："
info "  tccutil reset ListenEvent $BUNDLE_ID"

# ── 5. 启动客户端 ─────────────────────────────────────────────────────────────
section "启动客户端..."
# 直接执行 binary 而不用 open，避免 macOS 因 bundle ID 相同而复用旧进程
APP_BINARY=$(find "$DERIVED_DATA_APP/Contents/MacOS" -type f -perm +111 | grep -v "\.dylib\|\.so" | head -1)
if [[ -z "$APP_BINARY" ]]; then
    error "找不到可执行文件，尝试用 open 启动..."
    open "$DERIVED_DATA_APP"
else
    info "启动: $DERIVED_DATA_APP"
    # 使用 LaunchServices 启动 App bundle，确保 LSUIElement/签名/TCC 上下文与真实安装运行一致。
    # -n 避免复用可能残留的同 Bundle ID 进程。
    open -n "$DERIVED_DATA_APP"
fi
sleep 2

if ! pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
    error "客户端启动失败：未找到运行中的进程"
    exit 1
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ 客户端已启动，使用 Apple 开发者证书，权限稳定${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""

info "完成！"
