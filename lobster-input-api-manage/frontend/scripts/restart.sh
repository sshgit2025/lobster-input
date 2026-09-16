#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_DIR="$(dirname "$SCRIPT_DIR")"

cd "$FRONTEND_DIR"

echo "🔑 API Pool Frontend - 构建并启动..."

if [ -f ".pid" ]; then
  OLD_PID=$(cat .pid)
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "停止旧进程 PID=$OLD_PID"
    kill "$OLD_PID"
    sleep 1
  fi
  rm -f .pid
fi

npm install -q
npm run build

mkdir -p logs
nohup npm run preview > logs/frontend.log 2>&1 &
echo $! > .pid

FRONTEND_PORT=7889
for _ in {1..30}; do
  if curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/lobster/api-pool/" >/dev/null 2>&1; then
    echo "✅ 号池前端已启动 PID=$(cat .pid) 端口=${FRONTEND_PORT}"
    exit 0
  fi
  sleep 1
done

echo "❌ 号池前端启动超时"
tail -n 20 logs/frontend.log
exit 1
