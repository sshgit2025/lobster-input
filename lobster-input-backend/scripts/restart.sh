#!/usr/bin/env bash
# =============================================================================
# restart.sh — 后端启动脚本
#
# 使用方式：
#   bash scripts/restart.sh
#
# 依赖管理：使用 uv（https://docs.astral.sh/uv/）
#   - pyproject.toml  声明直接依赖（宽松版本约束）
#   - uv.lock         精确锁定所有依赖版本（含传递依赖），提交到 git
#   - .venv           本地虚拟环境，由 uv sync 自动创建和维护
#
# 首次部署 / 环境初始化：
#   cd backend && uv sync
# =============================================================================

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
section() { echo -e "\n${GREEN}▶ $*${NC}"; }

# ── 停止旧后端 ────────────────────────────────────────────────────────────────
section "停止旧后端服务..."
BACKEND_PID=$(lsof -ti:8000 2>/dev/null | xargs)
if [[ -n "$BACKEND_PID" ]]; then
    kill $BACKEND_PID 2>/dev/null || true
    sleep 1
    info "已终止旧后端进程 (PID: $BACKEND_PID)"
else
    info "无旧后端进程"
fi

# ── 同步依赖（uv sync 根据 uv.lock 精确安装，首次自动创建 .venv）────────────
section "同步依赖环境..."
cd "$PROJECT_ROOT/backend"
if command -v uv &>/dev/null; then
    uv sync --frozen 2>&1 | grep -v "^Resolved\|^Audited\|^Using" || true
    info "✓ 依赖已同步（uv sync --frozen）"
else
    warn "未找到 uv，回退到 pip（建议安装 uv: curl -LsSf https://astral.sh/uv/install.sh | sh）"
    source .venv/bin/activate
    pip install -r requirements.txt -q
fi

# ── 启动后端 ──────────────────────────────────────────────────────────────────
section "启动后端服务..."
cd "$PROJECT_ROOT/backend"
nohup .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload \
    --log-level debug \
    >> /tmp/backend.log 2>&1 &
BACKEND_NEW_PID=$!
info "后端已启动 (PID: $BACKEND_NEW_PID)，等待就绪..."

for i in $(seq 1 20); do
    sleep 1
    if curl -s --max-time 1 http://localhost:8000/health 2>/dev/null | grep -q '"ok"'; then
        info "✓ 后端就绪 (${i}s)"
        break
    fi
    if [[ $i -eq 20 ]]; then
        warn "后端启动超时，可能仍在启动中，请稍后检查 /tmp/backend.log"
    fi
done

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  ✓ 后端服务已启动，监听端口 8000${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""

info "完成！"
