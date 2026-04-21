#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/configure-awx.sh
#
# Automates the AWX initial configuration via its REST API so you don't
# have to click through the UI manually.
#
# Creates (in order):
#   1. Organisation   — "env0 Demo Org"
#   2. Credential     — SSH key for the EC2 instance
#   3. Project        — points to your GitHub repo
#   4. Inventory      — placeholder inventory (host injected at job launch)
#   5. Job Template   — "Deploy Website" wired to the playbook
#   6. Personal Token — printed at the end for use as TF_VAR_awx_token
#
# Usage:
#   chmod +x scripts/configure-awx.sh
#   ./scripts/configure-awx.sh
#
# Inputs (prompted if not set as env vars):
#   AWX_HOST       - e.g. http://localhost:8052
#   AWX_ADMIN_PASS - AWX admin password (default: password)
#   GITHUB_REPO    - e.g. https://github.com/youruser/env0-ec2-ansible-demo
#   SSH_KEY_FILE   - path to .pem file, e.g. ~/.ssh/env0-demo-key.pem
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Defaults / prompts ────────────────────────────────────────────────────
AWX_HOST="${AWX_HOST:-http://localhost:8052}"
AWX_ADMIN_PASS="${AWX_ADMIN_PASS:-password}"
GITHUB_REPO="${GITHUB_REPO:-}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/env0-demo-key.pem}"

if [ -z "$GITHUB_REPO" ]; then
  read -r -p "Enter your GitHub repo URL (e.g. https://github.com/you/env0-ec2-ansible-demo): " GITHUB_REPO
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Configuring AWX at $AWX_HOST"
echo "═══════════════════════════════════════════"
echo ""

# ── Helper: AWX API call ──────────────────────────────────────────────────
# Usage: awx_api GET|POST|PATCH <path> [json_body]
awx_api() {
  local METHOD="$1"
  local PATH="$2"
  local BODY="${3:-}"
  local RESPONSE

  if [ -n "$BODY" ]; then
    RESPONSE=$(curl -sf -X "$METHOD" \
      "$AWX_HOST/api/v2$PATH" \
      -u "admin:$AWX_ADMIN_PASS" \
      -H "Content-Type: application/json" \
      -d "$BODY")
  else
    RESPONSE=$(curl -sf -X "$METHOD" \
      "$AWX_HOST/api/v2$PATH" \
      -u "admin:$AWX_ADMIN_PASS" \
      -H "Content-Type: application/json")
  fi
  echo "$RESPONSE"
}

# ── 0. Wait for AWX to be ready ───────────────────────────────────────────
echo "Checking AWX is reachable..."
until curl -sf "$AWX_HOST/api/v2/ping/" > /dev/null 2>&1; do
  printf "."
  sleep 3
done
echo " ✅ AWX is up"
echo ""

# ── 1. Get the default Organization ID ───────────────────────────────────
echo "[1/6] Getting default organization..."
ORG_ID=$(awx_api GET "/organizations/" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = data.get('results', [])
if results:
    print(results[0]['id'])
")
echo "      Organization ID: $ORG_ID"

# ── 2. Create SSH Machine Credential ─────────────────────────────────────
echo "[2/6] Creating SSH machine credential..."

if [ ! -f "$SSH_KEY_FILE" ]; then
  echo "⚠️  SSH key file not found at $SSH_KEY_FILE"
  read -r -p "Enter path to your .pem file: " SSH_KEY_FILE
fi

SSH_KEY_CONTENT=$(cat "$SSH_KEY_FILE")

CRED_RESPONSE=$(awx_api POST "/credentials/" "{
  \"name\": \"EC2 SSH Key\",
  \"description\": \"Private key for the env0-demo-key EC2 key pair\",
  \"organization\": $ORG_ID,
  \"credential_type\": 1,
  \"inputs\": {
    \"username\": \"ubuntu\",
    \"ssh_key_data\": $(echo "$SSH_KEY_CONTENT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
  }
}")
CRED_ID=$(echo "$CRED_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "      Credential ID: $CRED_ID"

# ── 3. Create Project (linked to GitHub repo) ─────────────────────────────
echo "[3/6] Creating project linked to GitHub..."
PROJ_RESPONSE=$(awx_api POST "/projects/" "{
  \"name\": \"env0-ansible-demo\",
  \"description\": \"Ansible playbooks for env0 EC2 demo\",
  \"organization\": $ORG_ID,
  \"scm_type\": \"git\",
  \"scm_url\": \"$GITHUB_REPO\",
  \"scm_branch\": \"main\",
  \"scm_update_on_launch\": true,
  \"scm_clean\": true
}")
PROJ_ID=$(echo "$PROJ_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "      Project ID: $PROJ_ID"

# Wait for the project to sync from GitHub
echo "      Waiting for project sync..."
for i in $(seq 1 20); do
  STATUS=$(awx_api GET "/projects/$PROJ_ID/" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
  if [ "$STATUS" = "successful" ]; then
    echo "      ✅ Project synced from GitHub"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "      ❌ Project sync failed. Check your repo URL: $GITHUB_REPO"
    exit 1
  fi
  printf "      Status: $STATUS (attempt $i/20)...\r"
  sleep 5
done
echo ""

# ── 4. Create Inventory ───────────────────────────────────────────────────
echo "[4/6] Creating inventory..."
INV_RESPONSE=$(awx_api POST "/inventories/" "{
  \"name\": \"EC2 Dynamic Inventory\",
  \"description\": \"Target host is injected at job launch time via extra_vars\",
  \"organization\": $ORG_ID
}")
INV_ID=$(echo "$INV_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "      Inventory ID: $INV_ID"

# ── 5. Create Job Template ────────────────────────────────────────────────
echo "[5/6] Creating job template..."
JT_RESPONSE=$(awx_api POST "/job_templates/" "{
  \"name\": \"Deploy Website\",
  \"description\": \"Installs NGINX and deploys the website on a newly provisioned EC2 instance\",
  \"job_type\": \"run\",
  \"inventory\": $INV_ID,
  \"project\": $PROJ_ID,
  \"playbook\": \"ansible/playbooks/deploy_website.yml\",
  \"ask_variables_on_launch\": true,
  \"extra_vars\": \"---\\ntarget_host: localhost\\nproject_name: env0-demo\\nenvironment_name: demo\\ninstance_id: unknown\",
  \"verbosity\": 1
}")
JT_ID=$(echo "$JT_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "      Job Template ID: $JT_ID"

# Associate the SSH credential with the job template
awx_api POST "/job_templates/$JT_ID/credentials/" "{\"id\": $CRED_ID}" > /dev/null
echo "      SSH credential attached ✅"

# ── 6. Create Personal Access Token ──────────────────────────────────────
echo "[6/6] Creating AWX personal access token..."
TOKEN_RESPONSE=$(awx_api POST "/users/1/tokens/" "{
  \"description\": \"env0 Terraform integration token\",
  \"application\": null,
  \"scope\": \"write\"
}")
AWX_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
echo "      ✅ Token created"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo "  AWX Configuration Complete!"
echo "═══════════════════════════════════════════"
echo ""
echo "  Add these variables to env0:"
echo ""
echo "  TF_VAR_awx_job_template_id = $JT_ID"
echo "  TF_VAR_awx_token           = $AWX_TOKEN"
echo ""
echo "  ⚠️  Copy the token now — it won't be shown again."
echo ""
echo "  AWX UI: $AWX_HOST"
echo "    Org ID         : $ORG_ID"
echo "    Credential ID  : $CRED_ID"
echo "    Project ID     : $PROJ_ID"
echo "    Inventory ID   : $INV_ID"
echo "    Job Template ID: $JT_ID"
echo ""
