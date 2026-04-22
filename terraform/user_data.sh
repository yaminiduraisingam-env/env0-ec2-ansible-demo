#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# user_data.sh
# Runs ONCE on EC2 first boot as root.
#
# This file is a Terraform templatefile() template — variables in ${...}
# are substituted by Terraform before being sent to the EC2 instance.
#
# What this script does:
#   1. Redirect output to /var/log/user-data.log for debugging
#   2. Install curl and jq
#   3. Retrieve instance public IP via IMDSv2
#   4. Wait until Semaphore is reachable (retry loop, 5-minute timeout)
#   5. Authenticate with Semaphore and get a session cookie
#   6. Trigger the Semaphore Task Template via REST API
#   7. Schedule auto-stop
#
# Variables injected by Terraform:
#   awx_host            - e.g. https://abc123.ngrok-free.app  (Semaphore URL)
#   awx_token           - Semaphore API token
#   awx_job_template_id - Semaphore Template ID to trigger
#   auto_stop_hours     - hours until auto-shutdown (0 = disabled)
#   project_name        - for log messages
#   environment_name    - for log messages
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

echo "============================================="
echo " ${project_name} (${environment_name}) bootstrap"
echo " Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "============================================="

# ── 1. Install dependencies ────────────────────────────────────────────────
echo "[1/5] Installing curl and jq..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q curl jq

# ── 2. Get public IP via IMDSv2 ───────────────────────────────────────────
echo "[2/5] Retrieving instance metadata via IMDSv2..."
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

INSTANCE_IP=$(curl -s \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

INSTANCE_ID=$(curl -s \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "      Instance ID : $INSTANCE_ID"
echo "      Public IP   : $INSTANCE_IP"

# ── 3. Wait for Semaphore ─────────────────────────────────────────────────
SEMAPHORE_HOST="${awx_host}"
SEMAPHORE_TOKEN="${awx_token}"
TEMPLATE_ID="${awx_job_template_id}"

echo "[3/5] Waiting for Semaphore at $SEMAPHORE_HOST ..."
MAX_RETRIES=20
RETRY=0
READY=false

while [ $RETRY -lt $MAX_RETRIES ]; do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%%{http_code}" \
    "$SEMAPHORE_HOST/api/ping" || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    READY=true
    echo "      Semaphore responded 200 OK after $((RETRY * 15)) seconds"
    break
  fi

  RETRY=$((RETRY + 1))
  echo "      Attempt $RETRY/$MAX_RETRIES — HTTP $HTTP_CODE — retrying in 15s..."
  sleep 15
done

if [ "$READY" = "false" ]; then
  echo "ERROR: Semaphore did not become reachable after $((MAX_RETRIES * 15)) seconds."
  echo "       Check that:"
  echo "       - Semaphore containers are running (docker compose ps)"
  echo "       - ngrok tunnel is active (ngrok http 3000)"
  echo "       - TF_VAR_awx_host matches the current ngrok URL"
  exit 1
fi

# ── 4. Trigger the Semaphore Task Template ────────────────────────────────
# Semaphore API: POST /api/project/{project_id}/tasks
# The template_id links to the Task Template configured in the UI.
# extra_vars overrides Ansible variables for this specific run.
echo "[4/5] Triggering Semaphore Template ID $TEMPLATE_ID ..."

# The project_id is embedded in the template — we derive it from the template
PROJECT_ID=$(curl -sk \
  -H "Authorization: Bearer $SEMAPHORE_TOKEN" \
  -H "Content-Type: application/json" \
  "$SEMAPHORE_HOST/api/project/1/templates/$TEMPLATE_ID" \
  | jq -r '.project_id // "1"')

LAUNCH_RESPONSE=$(curl -sk -X POST \
  "$SEMAPHORE_HOST/api/project/$${PROJECT_ID}/tasks" \
  -H "Authorization: Bearer $SEMAPHORE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"template_id\": $TEMPLATE_ID,
    \"extra_vars\": \"target_host: $INSTANCE_IP\ninstance_id: $INSTANCE_ID\nproject_name: ${project_name}\nenvironment_name: ${environment_name}\"
  }")

TASK_ID=$(echo "$LAUNCH_RESPONSE" | jq -r '.id // "null"')

if [ "$TASK_ID" = "null" ] || [ -z "$TASK_ID" ]; then
  echo "ERROR: Semaphore task launch failed. Response:"
  echo "$LAUNCH_RESPONSE" | jq . || echo "$LAUNCH_RESPONSE"
  exit 1
fi

echo "      Semaphore Task ID  : $TASK_ID"
echo "      Monitor at         : $SEMAPHORE_HOST/project/$${PROJECT_ID}/history"

cat > /var/log/semaphore-trigger.json << EOF
{
  "triggered_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "instance_id": "$INSTANCE_ID",
  "instance_ip": "$INSTANCE_IP",
  "semaphore_host": "$SEMAPHORE_HOST",
  "template_id": "$TEMPLATE_ID",
  "task_id": "$TASK_ID"
}
EOF

# ── 5. Auto-stop scheduling ────────────────────────────────────────────────
AUTO_STOP_HOURS="${auto_stop_hours}"
echo "[5/5] Auto-stop configuration..."

if [ "$AUTO_STOP_HOURS" -gt 0 ]; then
  STOP_MINS=$((AUTO_STOP_HOURS * 60))
  echo "      Scheduling auto-stop in $AUTO_STOP_HOURS hour(s)"

  cat > /usr/local/bin/auto-stop.sh << 'STOPSCRIPT'
#!/bin/bash
echo "$(date -u) Auto-stop triggered" >> /var/log/auto-stop.log
shutdown -h now "env0 auto-stop"
STOPSCRIPT
  chmod +x /usr/local/bin/auto-stop.sh

  apt-get install -y -q at
  systemctl enable --now atd
  echo "/usr/local/bin/auto-stop.sh" | at now + "$AUTO_STOP_HOURS" hours
  echo "      Auto-stop queued (at now + $AUTO_STOP_HOURS hours)"
else
  echo "      Auto-stop disabled"
fi

echo "============================================="
echo " Bootstrap complete: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " Website will be live once Semaphore task $TASK_ID finishes."
echo "============================================="
