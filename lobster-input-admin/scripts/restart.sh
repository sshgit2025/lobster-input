#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN_DIR="$(dirname "$SCRIPT_DIR")"

echo "🦞 Lobster Admin - 启动后端 + 前端..."

echo "==> 启动后端..."
(cd "$ADMIN_DIR/backend" && bash scripts/restart.sh)

echo "==> 启动前端..."
(cd "$ADMIN_DIR/frontend" && mkdir -p logs && bash scripts/restart.sh)

echo "✅ 管理后台后端与前端均已启动"
