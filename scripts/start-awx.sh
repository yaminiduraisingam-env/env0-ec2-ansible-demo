#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/start-awx.sh
#
# Starts Ansible Semaphore (Docker Compose) and ngrok, then prints
# the public ngrok URL to update in env0.
#
# Prerequisites:
#   - Docker Desktop running (2 GB RAM is enough for Semaphore)
#   - ngrok installed: brew install ngrok
#   - ngrok authenticated: ngrok config add-authtoken <your-token>
#
# Usage:
#   chmod +x scripts/start-awx.sh
#   ./scripts/start-awx.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWX_DIR="$SCRIPT_DIR/../awx-local"
SEMAPHORE_PORT=3000
NGROK_LOG="$SCRIPT_DIR/../awx-local/ngrok.log"

echo "═══════════════════════════════════════════"
echo "  Starting Semaphore + ngrok"
echo "═══════════════════════════════════════════"

# ── 1. Check Docker Desktop ───────────────────────────────────────────────
if ! docker info > /dev/null 2>&1; then
  echo "❌ Docker Desktop is not running. Start it first."
  exit 1
fi
echo "✅ Docker Desktop is running"

# ── 2. Tear down any previous containers (including broken AWX ones) ──────
echo ""
echo "Cleaning up previous containers..."
cd "$AWX_DIR"
docker compose down --remove-orphans 2>/dev/null || true

# ── 3. Start Semaphore ────────────────────────────────────────────────────
echo "Starting Semaphore containers..."
docker compose up -d

echo ""
echo "Waiting for Semaphore to be ready..."
RETRIES=30
until curl -sf "http://localhost:$SEMAPHORE_PORT/api/ping" > /dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
  printf "."
  sleep 2
  RETRIES=$((RETRIES-1))
done
echo ""

if [ $RETRIES -eq 0 ]; then
  echo "⚠️  Semaphore did not respond. Check logs:"
  echo "   docker compose -f $AWX_DIR/docker-compose.yml logs semaphore"
else
  echo "✅ Semaphore is running at http://localhost:$SEMAPHORE_PORT"
  echo "   Credentials: admin / changeme123"
fi

# ── 4. Start ngrok ────────────────────────────────────────────────────────
echo ""
echo "Starting ngrok on port $SEMAPHORE_PORT..."
pkill -f "ngrok http $SEMAPHORE_PORT" 2>/dev/null || true
sleep 1

nohup ngrok http "$SEMAPHORE_PORT" --log=stdout > "$NGROK_LOG" 2>&1 &
sleep 5

NGROK_URL=""
for i in $(seq 1 10); do
  NGROK_URL=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null \
    | python3 -c "
import sys,json
t=json.load(sys.stdin).get('tunnels',[])
print(next((x['public_url'] for x in t if x['proto']=='https'),''))
" 2>/dev/null || echo "")
  [ -n "$NGROK_URL" ] && break
  sleep 2
done

echo ""
echo "═══════════════════════════════════════════"
if [ -n "$NGROK_URL" ]; then
  echo "✅ ngrok public URL: $NGROK_URL"
  echo ""
  echo "  ➡  Set TF_VAR_awx_host in env0 to:"
  echo "     $NGROK_URL"
  echo ""
  echo "  ⚠️  This URL changes every time you restart ngrok."
  echo "     After updating env0, run your workflow."
else
  echo "⚠️  Could not get ngrok URL. Open http://localhost:4040 to find it."
fi
echo "═══════════════════════════════════════════"
echo ""
echo "Next step: run scripts/configure-semaphore.sh to set up projects"
echo "           and get your API token."
echo ""
echo "To stop everything: ./scripts/stop-awx.sh"
