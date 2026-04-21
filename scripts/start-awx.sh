#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/start-awx.sh
#
# Starts AWX (Docker Compose) and ngrok in the correct order,
# then prints the ngrok public URL to update in env0.
#
# Prerequisites:
#   - Docker Desktop running
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
AWX_PORT=8052
NGROK_LOG="$SCRIPT_DIR/../awx-local/ngrok.log"

echo "═══════════════════════════════════════════"
echo "  Starting AWX + ngrok"
echo "═══════════════════════════════════════════"

# ── 1. Check Docker Desktop is running ───────────────────────────────────
if ! docker info > /dev/null 2>&1; then
  echo "❌ Docker Desktop is not running."
  echo "   Open Docker Desktop and wait for it to start, then re-run this script."
  exit 1
fi
echo "✅ Docker Desktop is running"

# ── 2. Check available memory ────────────────────────────────────────────
# AWX needs at least 4 GB. Docker on Mac reports total container memory.
DOCKER_MEM_GB=$(docker system info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%.0f", $1/1073741824}' || echo "unknown")
if [ "$DOCKER_MEM_GB" != "unknown" ] && [ "$DOCKER_MEM_GB" -lt 4 ] 2>/dev/null; then
  echo "⚠️  Docker has ${DOCKER_MEM_GB}GB RAM. AWX needs 4GB."
  echo "   Docker Desktop → Settings → Resources → Memory → set to 4096MB"
  echo "   Continuing anyway — AWX may be slow or fail to start."
fi

# ── 3. Start AWX via Docker Compose ──────────────────────────────────────
echo ""
echo "Starting AWX containers..."
cd "$AWX_DIR"
docker compose up -d

echo ""
echo "Waiting for AWX to be ready (this takes 2–3 minutes on first run)..."
RETRIES=40
until curl -sf "http://localhost:$AWX_PORT/api/v2/ping/" > /dev/null 2>&1 || [ $RETRIES -eq 0 ]; do
  printf "."
  sleep 5
  RETRIES=$((RETRIES-1))
done
echo ""

if [ $RETRIES -eq 0 ]; then
  echo "⚠️  AWX did not respond within the timeout."
  echo "   Check logs: docker compose -f $AWX_DIR/docker-compose.yml logs awx_web"
  echo "   AWX may still be initializing — wait a minute and retry."
else
  echo "✅ AWX is running at http://localhost:$AWX_PORT"
  echo "   Credentials: admin / password"
fi

# ── 4. Start ngrok ────────────────────────────────────────────────────────
echo ""
echo "Starting ngrok tunnel on port $AWX_PORT..."

# Kill any existing ngrok for this port
pkill -f "ngrok http $AWX_PORT" 2>/dev/null || true
sleep 1

# Start ngrok in the background
nohup ngrok http "$AWX_PORT" --log=stdout > "$NGROK_LOG" 2>&1 &
NGROK_PID=$!

echo "ngrok PID: $NGROK_PID (log: $NGROK_LOG)"
echo "Waiting for ngrok to establish tunnel..."
sleep 5

# Extract the public URL from the ngrok API
NGROK_URL=""
for i in $(seq 1 10); do
  NGROK_URL=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null \
    | python3 -c "import sys,json; t=json.load(sys.stdin).get('tunnels',[]); print(next((x['public_url'] for x in t if x['proto']=='https'), ''))" 2>/dev/null || echo "")
  if [ -n "$NGROK_URL" ]; then
    break
  fi
  sleep 2
done

echo ""
echo "═══════════════════════════════════════════"
if [ -n "$NGROK_URL" ]; then
  echo "✅ ngrok public URL: $NGROK_URL"
  echo ""
  echo "  ➡  Update TF_VAR_awx_host in env0 to:"
  echo "     $NGROK_URL"
  echo ""
  echo "  Save this URL — it changes every time you restart ngrok."
  echo "  After updating env0, run your env0 workflow."
else
  echo "⚠️  Could not retrieve ngrok URL automatically."
  echo "   Run: curl -s http://localhost:4040/api/tunnels | python3 -m json.tool"
  echo "   Or open: http://localhost:4040 in your browser"
fi
echo "═══════════════════════════════════════════"
echo ""
echo "To stop everything: ./scripts/stop-awx.sh"
