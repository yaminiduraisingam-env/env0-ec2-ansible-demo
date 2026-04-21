#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/stop-awx.sh
# Gracefully stops ngrok and AWX Docker containers.
# Data volumes are preserved so AWX state survives between sessions.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWX_DIR="$SCRIPT_DIR/../awx-local"

echo "Stopping ngrok..."
pkill -f "ngrok http" 2>/dev/null && echo "✅ ngrok stopped" || echo "  (ngrok was not running)"

echo "Stopping AWX containers (data is preserved)..."
cd "$AWX_DIR"
docker compose stop
echo "✅ AWX stopped"
echo ""
echo "To restart: ./scripts/start-awx.sh"
echo "To wipe all data: docker compose down -v"
