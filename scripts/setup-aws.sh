#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/setup-aws.sh
#
# One-time AWS setup script. Run this ONCE before running the env0 workflow.
#
# What it does:
#   1. Checks AWS CLI is installed and configured
#   2. Creates the EC2 Key Pair (saves .pem file to ~/.ssh/)
#   3. Sets correct permissions on the .pem file
#   4. Sets a $1 billing alert so you never get surprise charges
#   5. Prints a summary of what to put in env0 variables
#
# Usage:
#   chmod +x scripts/setup-aws.sh
#   ./scripts/setup-aws.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

KEY_NAME="env0-demo-key"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ALERT_EMAIL="${1:-}"   # Optional: pass your email as $1 for billing alert

echo "═══════════════════════════════════════════"
echo "  AWS one-time setup for env0 demo"
echo "  Region: $REGION"
echo "═══════════════════════════════════════════"
echo ""

# ── 1. Check AWS CLI ─────────────────────────────────────────────────────
if ! command -v aws &>/dev/null; then
  echo "❌ AWS CLI not found. Install it:"
  echo "   brew install awscli"
  echo "   Then configure: aws configure"
  exit 1
fi

# Check credentials work
if ! aws sts get-caller-identity > /dev/null 2>&1; then
  echo "❌ AWS credentials not configured or invalid."
  echo "   Run: aws configure"
  echo "   Enter your IAM user Access Key ID and Secret Access Key."
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IAM_USER=$(aws sts get-caller-identity --query Arn --output text)
echo "✅ AWS credentials valid"
echo "   Account ID : $ACCOUNT_ID"
echo "   Identity   : $IAM_USER"
echo ""

# ── 2. Create EC2 Key Pair ───────────────────────────────────────────────
PEM_FILE="$HOME/.ssh/$KEY_NAME.pem"

if aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" > /dev/null 2>&1; then
  echo "ℹ️  Key pair '$KEY_NAME' already exists in AWS."
  if [ -f "$PEM_FILE" ]; then
    echo "   Local .pem file also found at $PEM_FILE ✅"
  else
    echo "⚠️  Local .pem file NOT found at $PEM_FILE"
    echo "   You need the .pem file to SSH into instances."
    echo "   If you lost it, delete the key pair and re-run:"
    echo "   aws ec2 delete-key-pair --key-name $KEY_NAME --region $REGION"
  fi
else
  echo "Creating EC2 Key Pair '$KEY_NAME' in region $REGION..."
  aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --region "$REGION" \
    --query 'KeyMaterial' \
    --output text > "$PEM_FILE"

  chmod 400 "$PEM_FILE"
  echo "✅ Key pair created"
  echo "   Private key saved to: $PEM_FILE"
  echo "   Permissions set to 400 (read-only by owner)"
fi

echo ""

# ── 3. Check for existing billing alert ─────────────────────────────────
echo "Setting up billing alert..."
EXISTING_BUDGET=$(aws budgets describe-budgets \
  --account-id "$ACCOUNT_ID" \
  --query 'Budgets[?BudgetName==`FreeTierGuard`].BudgetName' \
  --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_BUDGET" ]; then
  echo "ℹ️  Billing alert 'FreeTierGuard' already exists."
else
  if [ -z "$ALERT_EMAIL" ]; then
    read -r -p "Enter your email for billing alerts (or press Enter to skip): " ALERT_EMAIL
  fi

  if [ -n "$ALERT_EMAIL" ]; then
    aws budgets create-budget \
      --account-id "$ACCOUNT_ID" \
      --budget "{
        \"BudgetName\": \"FreeTierGuard\",
        \"BudgetLimit\": {\"Amount\": \"1\", \"Unit\": \"USD\"},
        \"TimeUnit\": \"MONTHLY\",
        \"BudgetType\": \"COST\"
      }" \
      --notifications-with-subscribers "[{
        \"Notification\": {
          \"NotificationType\": \"ACTUAL\",
          \"ComparisonOperator\": \"GREATER_THAN\",
          \"Threshold\": 80,
          \"ThresholdType\": \"PERCENTAGE\"
        },
        \"Subscribers\": [{
          \"SubscriptionType\": \"EMAIL\",
          \"Address\": \"$ALERT_EMAIL\"
        }]
      }]"
    echo "✅ Billing alert created — you'll be emailed if charges exceed \$0.80/month"
  else
    echo "⚠️  Skipped billing alert. Recommended to set one in the AWS Console."
  fi
fi

echo ""
echo "═══════════════════════════════════════════"
echo "  Setup complete! Add these to env0:"
echo "═══════════════════════════════════════════"
echo ""
echo "  Variable               │ Value"
echo "  ───────────────────────┼─────────────────────────────────────"
echo "  AWS_ACCESS_KEY_ID      │ (from: aws configure get aws_access_key_id)"
echo "  AWS_SECRET_ACCESS_KEY  │ (from: aws configure get aws_secret_access_key)"
echo "  TF_VAR_key_name        │ $KEY_NAME"
echo "  TF_VAR_awx_host        │ (run scripts/start-awx.sh to get ngrok URL)"
echo "  TF_VAR_awx_token       │ (generate in AWX UI: User → Tokens → Add)"
echo "  TF_VAR_awx_job_template_id │ (from AWX UI after creating job template)"
echo ""
echo "  AWS Access Key ID  : $(aws configure get aws_access_key_id 2>/dev/null || echo 'not set')"
echo "  Key Pair Name      : $KEY_NAME"
echo "  Key Pair File      : $PEM_FILE"
echo "  Region             : $REGION"
echo "  Account ID         : $ACCOUNT_ID"
echo ""
