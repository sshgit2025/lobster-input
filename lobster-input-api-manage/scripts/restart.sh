#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "🔑 API Pool - 启动后端 + 前端..."

echo "==> 启动后端..."
(cd "$PROJECT_DIR/backend" && bash scripts/restart.sh)

echo "==> 启动前端..."
(cd "$PROJECT_DIR/frontend" && bash scripts/restart.sh)

echo "✅ 号池后端与前端均已启动"
