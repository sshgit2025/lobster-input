#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "🔑 API Pool Manager - 启动号池管理平台..."

if [ -f ".pid" ]; then
  OLD_PID=$(cat .pid)
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "停止旧进程 PID=$OLD_PID"
    kill "$OLD_PID"
    sleep 1
  fi
  rm -f .pid
fi

if [ ! -d "venv" ]; then
  echo "创建虚拟环境..."
  python3 -m venv venv
fi

source venv/bin/activate

echo "安装依赖..."
pip install -r requirements.txt -q

mkdir -p logs

echo "启动服务..."
nohup python run.py > logs/api-manage.log 2>&1 &
echo $! > .pid

echo "✅ 号池管理平台已启动，PID=$(cat .pid)"
echo "📌 访问地址: http://localhost:8889"
echo "📋 日志文件: logs/api-manage.log"
