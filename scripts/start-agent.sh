#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/start-agent.sh
#
# Starts the env0 self-hosted agent as a Docker container on your Mac.
# The agent connects to env0 cloud and waits for Terraform jobs to run.
#
# Prerequisites:
#   - Docker Desktop running
#   - An env0 account (https://app.env0.com)
#   - An Agent API key from: Settings → Agents → New Agent
#
# Usage:
#   export ENV0_AGENT_API_KEY="your-key-here"
#   chmod +x scripts/start-agent.sh
#   ./scripts/start-agent.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

AGENT_CONTAINER_NAME="env0-agent"
AGENT_IMAGE="env0/agent:latest"

echo "═══════════════════════════════════════════"
echo "  Starting env0 self-hosted agent"
echo "═══════════════════════════════════════════"
echo ""

# ── Validate prerequisites ────────────────────────────────────────────────
if ! docker info > /dev/null 2>&1; then
  echo "❌ Docker Desktop is not running. Start it first."
  exit 1
fi

if [ -z "${ENV0_AGENT_API_KEY:-}" ]; then
  read -r -s -p "Paste your env0 Agent API Key: " ENV0_AGENT_API_KEY
  echo ""
fi

if [ -z "$ENV0_AGENT_API_KEY" ]; then
  echo "❌ No API key provided. Get one from: app.env0.com → Settings → Agents"
  exit 1
fi

# ── Remove existing agent container if present ────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${AGENT_CONTAINER_NAME}$"; then
  echo "Removing existing agent container..."
  docker rm -f "$AGENT_CONTAINER_NAME" > /dev/null
fi

# ── Pull latest agent image ───────────────────────────────────────────────
echo "Pulling latest env0 agent image..."
docker pull "$AGENT_IMAGE"

# ── Start the agent ───────────────────────────────────────────────────────
echo ""
echo "Starting agent container..."
docker run -d \
  --name "$AGENT_CONTAINER_NAME" \
  --restart unless-stopped \
  -e AGENT_API_KEY="$ENV0_AGENT_API_KEY" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/.aws:/root/.aws:ro" \
  "$AGENT_IMAGE"

# ── Verify it started ─────────────────────────────────────────────────────
sleep 3
if docker ps --format '{{.Names}}' | grep -q "^${AGENT_CONTAINER_NAME}$"; then
  echo ""
  echo "✅ env0 agent is running"
  echo ""
  echo "  Container : $AGENT_CONTAINER_NAME"
  echo "  Image     : $AGENT_IMAGE"
  echo "  Status    : $(docker inspect --format '{{.State.Status}}' $AGENT_CONTAINER_NAME)"
  echo ""
  echo "  Watch logs : docker logs -f $AGENT_CONTAINER_NAME"
  echo "  Stop agent : docker stop $AGENT_CONTAINER_NAME"
  echo ""
  echo "  Go to app.env0.com → Settings → Agents"
  echo "  Your agent should appear as 'Connected' within 30 seconds."
else
  echo "❌ Agent container failed to start."
  docker logs "$AGENT_CONTAINER_NAME" 2>&1 | tail -20
  exit 1
fi
