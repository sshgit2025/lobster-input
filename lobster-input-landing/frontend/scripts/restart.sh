#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(dirname "$SCRIPT_DIR")"

cd "$FRONTEND_DIR"

echo "🦞 Lobster Landing Frontend - 构建并启动预览..."

echo "安装依赖..."
npm install

echo "构建前端..."
npm run build

PREVIEW_PORT="${PREVIEW_PORT:-7891}"
PID_FILE=".preview.pid"
mkdir -p logs

if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "停止旧预览进程 PID=$OLD_PID"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

echo "启动 vite preview (port $PREVIEW_PORT)..."
nohup npm run preview > logs/preview.log 2>&1 &
echo $! > "$PID_FILE"

NEW_PID=$(cat "$PID_FILE")
for _ in {1..30}; do
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "❌ 预览服务启动失败"
    tail -n 30 logs/preview.log 2>/dev/null || true
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:${PREVIEW_PORT}/" >/dev/null 2>&1; then
    echo "✅ 前端预览已启动，PID=${NEW_PID}"
    echo "📌 访问地址: http://localhost:${PREVIEW_PORT}/"
    echo "📋 日志文件: logs/preview.log"
    exit 0
  fi
  sleep 1
done

echo "❌ 预览服务启动超时"
tail -n 30 logs/preview.log 2>/dev/null || true
exit 1
