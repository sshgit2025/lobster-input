#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "🦞 Lobster Admin - 启动管理后台..."

# 停止已运行的进程
if [ -f ".pid" ]; then
  OLD_PID=$(cat .pid)
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "停止旧进程 PID=$OLD_PID"
    kill "$OLD_PID"
    sleep 1
  fi
  rm -f .pid
fi

# 检查虚拟环境
if [ ! -d "venv" ]; then
  echo "创建虚拟环境..."
  python3 -m venv venv
fi

source venv/bin/activate

# 安装依赖
echo "安装依赖..."
pip install -r requirements.txt -q

# 启动服务
echo "启动服务..."
mkdir -p logs
nohup python run.py > logs/admin.log 2>&1 &
echo $! > .pid
NEW_PID=$(cat .pid)
ADMIN_PORT="${PORT:-8888}"
for _ in {1..40}; do
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "❌ 管理后台启动失败，进程已退出"
    tail -n 40 logs/admin.log
    exit 1
  fi
  if grep -q "Application startup failed" logs/admin.log; then
    echo "❌ 管理后台启动失败，请查看日志"
    tail -n 40 logs/admin.log
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:${ADMIN_PORT}/login" >/dev/null 2>&1; then
    echo "✅ 管理后台已启动，PID=${NEW_PID}"
    echo "📌 访问地址: http://localhost:${ADMIN_PORT}"
    echo "📋 日志文件: logs/admin.log"
    exit 0
  fi
  sleep 1
done

echo "❌ 管理后台启动超时，请查看日志"
tail -n 40 logs/admin.log
exit 1
