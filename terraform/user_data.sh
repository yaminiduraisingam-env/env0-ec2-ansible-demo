#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# user_data.sh
# Runs ONCE on EC2 first boot as root.
#
# This file is a Terraform templatefile() template — variables in ${...}
# are substituted by Terraform before the script is base64-encoded and
# sent to the EC2 instance as user_data.
#
# What this script does, in order:
#   1.  Redirect all output to /var/log/user-data.log for debugging
#   2.  Install curl and jq
#   3.  Retrieve the instance's own public IP via IMDSv2
#   4.  Wait until AWX is reachable (retry loop, 5-minute timeout)
#   5.  Call the AWX REST API to launch the Job Template
#   6.  Log the AWX job ID for traceability
#   7.  Optionally schedule an auto-stop cron job
#
# Variables injected by Terraform:
#   awx_host            - e.g. https://abc123.ngrok-free.app
#   awx_token           - AWX personal access token
#   awx_job_template_id - numeric ID of the AWX Job Template
#   auto_stop_hours     - hours until auto-shutdown (0 = disabled)
#   project_name        - for log messages
#   environment_name    - for log messages
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── 1. Logging ─────────────────────────────────────────────────────────────
# Redirect stdout and stderr to a log file AND to the system console.
# You can watch progress in real time by SSH-ing in and running:
#   sudo tail -f /var/log/user-data.log
exec > >(tee /var/log/user-data.log | logger -t user-data) 2>&1

echo "============================================="
echo " ${project_name} (${environment_name}) bootstrap"
echo " Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "============================================="

# ── 2. Install dependencies ────────────────────────────────────────────────
echo "[1/5] Installing curl and jq..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -q
apt-get install -y -q curl jq
echo "      curl $(curl --version | head -1)"
echo "      jq   $(jq --version)"

# ── 3. Get the instance's public IP via IMDSv2 ────────────────────────────
# IMDSv2 requires a token — plain curl to 169.254.169.254 will fail
# because we set http_tokens = "required" in main.tf.
echo "[2/5] Retrieving instance metadata via IMDSv2..."
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

INSTANCE_IP=$(curl -s \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)

INSTANCE_ID=$(curl -s \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

REGION=$(curl -s \
  -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

echo "      Instance ID : $INSTANCE_ID"
echo "      Public IP   : $INSTANCE_IP"
echo "      Region      : $REGION"

# ── 4. Wait for AWX ────────────────────────────────────────────────────────
# AWX may still be starting up, or ngrok may take a moment to be ready.
# We retry every 15 seconds for up to 5 minutes (20 attempts).
AWX_HOST="${awx_host}"
AWX_TOKEN="${awx_token}"
JOB_TEMPLATE_ID="${awx_job_template_id}"

echo "[3/5] Waiting for AWX at $AWX_HOST ..."
MAX_RETRIES=20
RETRY=0
AWX_READY=false

while [ $RETRY -lt $MAX_RETRIES ]; do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%%{http_code}" \
    "$AWX_HOST/api/v2/ping/" \
    -H "Authorization: Bearer $AWX_TOKEN" || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    AWX_READY=true
    echo "      AWX responded 200 OK after $((RETRY * 15)) seconds"
    break
  fi

  RETRY=$((RETRY + 1))
  echo "      Attempt $RETRY/$MAX_RETRIES — HTTP $HTTP_CODE — retrying in 15s..."
  sleep 15
done

if [ "$AWX_READY" = "false" ]; then
  echo "ERROR: AWX did not become reachable after $((MAX_RETRIES * 15)) seconds."
  echo "       Check that:"
  echo "       - AWX containers are running on your Mac (docker compose ps)"
  echo "       - ngrok tunnel is active (ngrok http 8052)"
  echo "       - TF_VAR_awx_host matches the current ngrok URL"
  exit 1
fi

# ── 5. Launch the AWX Job Template ────────────────────────────────────────
# We pass the instance's public IP as an Ansible extra_var so the
# playbook knows which host to configure.
echo "[4/5] Triggering AWX Job Template ID $JOB_TEMPLATE_ID ..."

LAUNCH_RESPONSE=$(curl -sk -X POST \
  "$AWX_HOST/api/v2/job_templates/$JOB_TEMPLATE_ID/launch/" \
  -H "Authorization: Bearer $AWX_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"extra_vars\": {
      \"target_host\": \"$INSTANCE_IP\",
      \"instance_id\": \"$INSTANCE_ID\",
      \"project_name\": \"${project_name}\",
      \"environment_name\": \"${environment_name}\"
    }
  }")

# Extract the job ID from the response
AWX_JOB_ID=$(echo "$LAUNCH_RESPONSE" | jq -r '.id // "null"')
AWX_JOB_URL=$(echo "$LAUNCH_RESPONSE" | jq -r '.url // "null"')
AWX_JOB_STATUS=$(echo "$LAUNCH_RESPONSE" | jq -r '.status // "unknown"')

if [ "$AWX_JOB_ID" = "null" ] || [ -z "$AWX_JOB_ID" ]; then
  echo "ERROR: AWX job launch failed. Response:"
  echo "$LAUNCH_RESPONSE" | jq . || echo "$LAUNCH_RESPONSE"
  exit 1
fi

echo "      AWX Job ID     : $AWX_JOB_ID"
echo "      AWX Job Status : $AWX_JOB_STATUS"
echo "      AWX Job URL    : $AWX_HOST$AWX_JOB_URL"

# Write a status file so you can check what happened later
cat > /var/log/awx-trigger.json << EOF
{
  "triggered_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "instance_id": "$INSTANCE_ID",
  "instance_ip": "$INSTANCE_IP",
  "awx_host": "$AWX_HOST",
  "job_template_id": "$JOB_TEMPLATE_ID",
  "awx_job_id": "$AWX_JOB_ID",
  "awx_job_status": "$AWX_JOB_STATUS"
}
EOF

# ── 6. Auto-stop scheduling ────────────────────────────────────────────────
AUTO_STOP_HOURS="${auto_stop_hours}"
echo "[5/5] Auto-stop configuration..."

if [ "$AUTO_STOP_HOURS" -gt 0 ]; then
  STOP_MINS=$((AUTO_STOP_HOURS * 60))
  STOP_AT=$(date -u -d "$STOP_MINS minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -v+"$${STOP_MINS}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || echo "unknown")

  echo "      Scheduling auto-stop in $AUTO_STOP_HOURS hour(s) (at approx $STOP_AT UTC)"

  # Write a dedicated stop script
  cat > /usr/local/bin/auto-stop.sh << 'STOPSCRIPT'
#!/bin/bash
echo "$(date -u) Auto-stop triggered" >> /var/log/auto-stop.log
shutdown -h now "env0 auto-stop — instance was idle for configured duration"
STOPSCRIPT
  chmod +x /usr/local/bin/auto-stop.sh

  # Use 'at' command for a one-shot delayed execution
  apt-get install -y -q at
  systemctl enable --now atd

  echo "/usr/local/bin/auto-stop.sh" | at now + "$AUTO_STOP_HOURS" hours
  echo "      Auto-stop at command queued (at now + $AUTO_STOP_HOURS hours)"
else
  echo "      Auto-stop is disabled (auto_stop_hours=0)"
fi

echo "============================================="
echo " Bootstrap complete: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " Website will be live once AWX job $AWX_JOB_ID finishes."
echo " Monitor: $AWX_HOST/#/jobs/playbook/$AWX_JOB_ID"
echo "============================================="
