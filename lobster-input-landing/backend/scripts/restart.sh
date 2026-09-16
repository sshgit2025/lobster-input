#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"

cd "$BACKEND_DIR"

echo "🦞 Lobster Landing API - 启动后端..."

# 选择 python 解释器：优先 venv
if [ -x "$BACKEND_DIR/venv/bin/python" ]; then
  PY="$BACKEND_DIR/venv/bin/python"
else
  PY="$(command -v python3.12 || command -v python3)"
fi
echo "使用解释器: $PY"

mkdir -p logs
PID_FILE=".pid"
PORT="${PORT:-8891}"

if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "停止旧进程 PID=$OLD_PID"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

echo "启动 uvicorn (port $PORT)..."
nohup "$PY" run.py > logs/backend.log 2>&1 &
echo $! > "$PID_FILE"

NEW_PID=$(cat "$PID_FILE")
for _ in {1..30}; do
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    echo "❌ 后端启动失败"
    tail -n 40 logs/backend.log 2>/dev/null || true
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    echo "✅ 官网后端已启动，PID=${NEW_PID}"
    echo "📋 日志: logs/backend.log"
    exit 0
  fi
  sleep 1
done

echo "❌ 后端启动超时"
tail -n 40 logs/backend.log 2>/dev/null || true
exit 1
