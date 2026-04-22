#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/configure-semaphore.sh
#
# Automates the Semaphore initial configuration via its REST API.
#
# Creates (in order):
#   1. API Token         — for use as TF_VAR_awx_token in env0
#   2. SSH Key Store     — your EC2 private key
#   3. Git Repository    — points to your GitHub repo
#   4. Inventory         — placeholder (host injected at runtime via extra_vars)
#   5. Environment       — empty Ansible environment
#   6. Task Template     — "Deploy Website" linked to the playbook
#
# Usage:
#   chmod +x scripts/configure-semaphore.sh
#   ./scripts/configure-semaphore.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SEMAPHORE_HOST="${SEMAPHORE_HOST:-http://localhost:3000}"
SEMAPHORE_USER="${SEMAPHORE_USER:-admin}"
SEMAPHORE_PASS="${SEMAPHORE_PASS:-changeme123}"
GITHUB_REPO="${GITHUB_REPO:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/env0-demo-key.pem}"

if [ -z "$GITHUB_REPO" ]; then
  read -r -p "Enter your GitHub repo URL (e.g. https://github.com/you/env0-ec2-ansible-demo): " GITHUB_REPO
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Configuring Semaphore at $SEMAPHORE_HOST"
echo "═══════════════════════════════════════════"
echo ""

# ── Helper ────────────────────────────────────────────────────────────────
sem_api() {
  local METHOD="$1"
  local PATH="$2"
  local BODY="${3:-}"
  local COOKIE_JAR="/tmp/semaphore-cookies.txt"

  if [ -n "$BODY" ]; then
    curl -sf -X "$METHOD" \
      "$SEMAPHORE_HOST$PATH" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -d "$BODY"
  else
    curl -sf -X "$METHOD" \
      "$SEMAPHORE_HOST$PATH" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR"
  fi
}

# ── 0. Wait for Semaphore ─────────────────────────────────────────────────
echo "Checking Semaphore is reachable..."
until curl -sf "$SEMAPHORE_HOST/api/ping" > /dev/null 2>&1; do
  printf "."
  sleep 2
done
echo " ✅ Semaphore is up"
echo ""

# ── 1. Get API Token ──────────────────────────────────────────────────────
echo "[1/6] Creating API token..."
TOKEN_RESPONSE=$(curl -sf -X POST \
  "$SEMAPHORE_HOST/api/auth/login" \
  -H "Content-Type: application/json" \
  -c /tmp/semaphore-cookies.txt \
  -d "{\"auth\": \"$SEMAPHORE_USER\", \"password\": \"$SEMAPHORE_PASS\"}")

# Generate a permanent API token
API_TOKEN=$(curl -sf -X POST \
  "$SEMAPHORE_HOST/api/user/tokens" \
  -H "Content-Type: application/json" \
  -b /tmp/semaphore-cookies.txt \
  -c /tmp/semaphore-cookies.txt \
  | jq -r '.id')

echo "      API Token: $API_TOKEN"

# ── 2. Get default project (Semaphore creates one on first run) ───────────
echo "[2/6] Getting project..."
PROJECT_ID=$(curl -sf \
  "$SEMAPHORE_HOST/api/projects" \
  -H "Authorization: Bearer $API_TOKEN" \
  -b /tmp/semaphore-cookies.txt \
  | jq -r '.[0].id // empty')

if [ -z "$PROJECT_ID" ]; then
  # Create a project if none exists
  PROJECT_ID=$(curl -sf -X POST \
    "$SEMAPHORE_HOST/api/projects" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -b /tmp/semaphore-cookies.txt \
    -d '{"name":"env0-demo","alert":false,"alert_chat":"","max_parallel_tasks":0}' \
    | jq -r '.id')
fi
echo "      Project ID: $PROJECT_ID"

# ── 3. Create SSH Key ─────────────────────────────────────────────────────
echo "[3/6] Adding SSH key..."
if [ ! -f "$SSH_KEY_FILE" ]; then
  read -r -p "Enter path to your .pem file: " SSH_KEY_FILE
fi
SSH_KEY_CONTENT=$(cat "$SSH_KEY_FILE")

KEY_ID=$(curl -sf -X POST \
  "$SEMAPHORE_HOST/api/project/$PROJECT_ID/keys" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -b /tmp/semaphore-cookies.txt \
  -d "{
    \"name\": \"EC2 SSH Key\",
    \"type\": \"ssh\",
    \"project_id\": $PROJECT_ID,
    \"ssh\": {
      \"username\": \"ubuntu\",
      \"private_key\": $(echo "$SSH_KEY_CONTENT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
    }
  }" | jq -r '.id')
echo "      Key ID: $KEY_ID"

# ── 4. Create Repository ──────────────────────────────────────────────────
echo "[4/6] Adding GitHub repository..."
REPO_ID=$(curl -sf -X POST \
  "$SEMAPHORE_HOST/api/project/$PROJECT_ID/repositories" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -b /tmp/semaphore-cookies.txt \
  -d "{
    \"name\": \"env0-ansible-demo\",
    \"project_id\": $PROJECT_ID,
    \"git_url\": \"$GITHUB_REPO\",
    \"git_branch\": \"main\",
    \"ssh_key_id\": $KEY_ID
  }" | jq -r '.id')
echo "      Repository ID: $REPO_ID"

# ── 5. Create Inventory ───────────────────────────────────────────────────
echo "[5/6] Creating inventory..."
INV_ID=$(curl -sf -X POST \
  "$SEMAPHORE_HOST/api/project/$PROJECT_ID/inventory" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -b /tmp/semaphore-cookies.txt \
  -d "{
    \"name\": \"EC2 Dynamic\",
    \"project_id\": $PROJECT_ID,
    \"inventory\": \"localhost\",
    \"ssh_key_id\": $KEY_ID,
    \"type\": \"static\"
  }" | jq -r '.id')
echo "      Inventory ID: $INV_ID"

# ── 5b. Create empty Environment ─────────────────────────────────────────
ENV_ID=$(curl -sf -X POST \
  "$SEMAPHORE_HOST/api/project/$PROJECT_ID/environment" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -b /tmp/semaphore-cookies.txt \
  -d "{
    \"name\": \"Default\",
    \"project_id\": $PROJECT_ID,
    \"json\": \"{}\"
  }" | jq -r '.id')

# ── 6. Create Task Template ───────────────────────────────────────────────
echo "[6/6] Creating Task Template..."
TEMPLATE_ID=$(curl -sf -X POST \
  "$SEMAPHORE_HOST/api/project/$PROJECT_ID/templates" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -b /tmp/semaphore-cookies.txt \
  -d "{
    \"project_id\": $PROJECT_ID,
    \"inventory_id\": $INV_ID,
    \"repository_id\": $REPO_ID,
    \"environment_id\": $ENV_ID,
    \"ssh_key_id\": $KEY_ID,
    \"name\": \"Deploy Website\",
    \"playbook\": \"ansible/playbooks/deploy_website.yml\",
    \"description\": \"Installs NGINX and deploys the website on EC2\",
    \"allow_override_args_in_task\": true
  }" | jq -r '.id')
echo "      Template ID: $TEMPLATE_ID"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  Semaphore Configuration Complete!"
echo "═══════════════════════════════════════════"
echo ""
echo "  Add these to env0 Variables:"
echo ""
echo "  TF_VAR_awx_host            = (your ngrok URL, e.g. https://xxx.ngrok-free.app)"
echo "  TF_VAR_awx_token           = $API_TOKEN"
echo "  TF_VAR_awx_job_template_id = $TEMPLATE_ID"
echo ""
echo "  ⚠️  Copy the token now — it won't be shown again."
echo ""
echo "  Semaphore UI : $SEMAPHORE_HOST"
echo "  Project ID   : $PROJECT_ID"
echo "  Template ID  : $TEMPLATE_ID"
echo ""
