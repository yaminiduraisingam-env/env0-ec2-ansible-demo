<h3 align="left">
  <img width="600" height="128" alt="image" src="https://raw.githubusercontent.com/artemis-env0/Packages/refs/heads/main/Images/Logo%20Pack/01%20Main%20Logo/Digital/SVG/envzero_logomark_fullcolor_rgb.svg" />
</h3>

---

# env0 + AWS EC2 + Ansible Semaphore — Complete Deployment Guide

This guide walks you through every step needed to go from zero to a
live public website provisioned entirely through code. No manual server
configuration. No SSH required. One workflow trigger in env0 does everything.

---

## What you will build

```
You click "Run Workflow" in env0
        │
        ▼
env0 dispatches to your Mac agent
        │
        ▼
Terraform runs on your Mac (inside Docker)
  └─ Creates an AWS Security Group
  └─ Provisions an EC2 t2.micro instance (FREE TIER)
  └─ Attaches an Elastic IP
        │
        ▼ (EC2 first boot)
user_data.sh runs on the instance
  └─ Installs curl + jq
  └─ Waits for Semaphore to respond
  └─ Calls Semaphore REST API: POST /api/project/{id}/tasks
  └─ Schedules auto-stop (4 hours by default)
        │
        ▼
Ansible Semaphore (running in Docker on your Mac, exposed via ngrok)
  └─ Receives the task trigger
  └─ Pulls latest playbook from GitHub
  └─ SSHs into the EC2 instance
  └─ Installs NGINX
  └─ Deploys the website from a Jinja2 template
        │
        ▼
Public website is live at http://<elastic-ip>
```

> **Why Semaphore instead of AWX?**
> AWX version 18+ is designed exclusively for Kubernetes via the AWX Operator
> and cannot run in standalone Docker Compose. Ansible Semaphore is the
> actively maintained open-source Ansible UI that runs perfectly in Docker,
> starts in seconds, and exposes the same REST API concepts
> (task templates, inventories, credentials, tokens).

---

## Repository structure

Every file in this repo and what it does:

```
env0-ec2-ansible-demo/
│
├── .gitignore                          Excludes secrets and Terraform state
├── .github/
│   └── workflows/
│       └── validate.yml                CI: runs terraform validate + ansible-lint on push
│
├── terraform/
│   ├── main.tf                         Core infrastructure: EC2, Security Group, Elastic IP
│   ├── variables.tf                    All input variables with descriptions and validations
│   ├── outputs.tf                      Outputs printed after apply (IP, URL, SSH command)
│   ├── user_data.sh                    Bootstrap script that runs on EC2 first boot
│   └── terraform.tfvars.example        Template for local testing (copy to terraform.tfvars)
│
├── ansible/
│   ├── ansible.cfg                     Ansible settings (SSH, roles path, remote_user)
│   ├── requirements.yml                Ansible Galaxy collections to install
│   ├── inventory/
│   │   └── hosts.ini                   Static inventory placeholder (host injected at runtime)
│   └── playbooks/
│       └── deploy_website.yml          Main playbook — installs NGINX and deploys the site
│   └── roles/
│       └── webserver/
│           ├── defaults/
│           │   └── main.yml            Default variable values for the role
│           ├── handlers/
│           │   └── main.yml            Handlers (reload/restart NGINX on config change)
│           ├── tasks/
│           │   └── main.yml            Task list: install NGINX, configure, deploy content
│           └── templates/
│               ├── nginx.conf.j2       Main NGINX configuration
│               ├── site.conf.j2        NGINX virtual host config
│               └── index.html.j2       The deployed webpage (with Ansible facts injected)
│
├── awx-local/
│   └── docker-compose.yml              Runs Ansible Semaphore + Postgres on your Mac
│
├── env0/
│   └── env0.yml                        Tells env0 about the Terraform template
│
└── scripts/
    ├── setup-aws.sh                    One-time AWS setup (key pair, billing alert)
    ├── start-awx.sh                    Starts Semaphore containers + ngrok tunnel
    ├── stop-awx.sh                     Gracefully stops Semaphore and ngrok
    ├── configure-semaphore.sh          Automates Semaphore setup via REST API
    └── start-agent.sh                  Starts the env0 agent Docker container
```

---

## Prerequisites — install these first

Open Terminal and run each command below to verify you have everything.

### 1. Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Git

```bash
git --version
# If not installed: xcode-select --install
```

### 3. Docker Desktop

Download from https://www.docker.com/products/docker-desktop and install.
After installing, open Docker Desktop and:
- Click the gear icon → Resources → Memory → set to **2048 MB (2 GB) minimum**
- Semaphore is lightweight — 2 GB is plenty. Click "Apply & Restart".

Verify Docker is working:

```bash
docker --version
docker compose version
```

### 4. AWS CLI

```bash
brew install awscli
aws --version
```

### 5. ngrok

```bash
brew install ngrok
```

Sign up for a free ngrok account at https://ngrok.com, then authenticate:

```bash
ngrok config add-authtoken YOUR_NGROK_TOKEN
```

### 6. Terraform (optional — only needed for local CLI testing)

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
terraform --version
```

---

## Part 1 — Create an AWS account

**If you already have an AWS account, skip to Part 2.**

1. Go to https://aws.amazon.com and click **Create an AWS Account**
2. Use your Gmail address as the root email
3. Choose **Personal** account type — enter your name and address
4. Enter a credit card (required, but nothing will be charged for this demo)
5. Verify your phone number
6. Select **Basic support plan** (free)
7. Log in to the AWS Console

### Create an IAM user for Terraform

The root account has unrestricted access. Best practice is to create a
dedicated IAM user for programmatic access.

1. In the AWS Console, search for **IAM** and open it
2. Click **Users** → **Create user**
3. Username: `env0-deployer`
4. Click **Next** → Attach policies directly
5. Search for and select **AdministratorAccess**
6. Click **Next** → **Create user**
7. Click the user → **Security credentials** tab
8. Click **Create access key** → Choose **Command Line Interface (CLI)**
9. Check the confirmation box → click **Next** → **Create access key**
10. **Copy both the Access Key ID and Secret Access Key** — you only see
    the secret once. Paste them somewhere safe temporarily.

### Configure the AWS CLI

```bash
aws configure
# AWS Access Key ID: paste your key
# AWS Secret Access Key: paste your secret
# Default region: us-east-1
# Default output format: json
```

Verify it works:

```bash
aws sts get-caller-identity
# Should print your Account ID and user ARN
```

---

## Part 2 — Create the GitHub repository

1. Go to https://github.com and log in
2. Click the **+** → **New repository**
3. Repository name: `env0-ec2-ansible-demo`
4. Set to **Public** (required for Semaphore to clone without credentials)
5. Click **Create repository** (leave it empty — do not add a README yet)

### Clone it and add all project files

```bash
git clone https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo.git
cd env0-ec2-ansible-demo
cp -r ~/env0-demo-files/* .
git add .
git commit -m "Initial commit: Terraform + Ansible + env0 configuration"
git push origin main
```

---

## Part 3 — One-time AWS setup

```bash
chmod +x scripts/setup-aws.sh
./scripts/setup-aws.sh your@gmail.com
```

This script creates the EC2 Key Pair (`env0-demo-key`), saves the `.pem`
file to `~/.ssh/`, and sets a $1/month billing alert. Save the output —
it lists the values you need to enter into env0.

---

## Part 4 — Start Ansible Semaphore on your Mac

### Step 1: Generate the required encryption key

Semaphore requires a valid 32-byte AES key. Run this once:

```bash
openssl rand -base64 32
# Example: K7gNU3sdo+OL0wNhqoVWhr3g6s1xYv72ol/pe/Unols=
```

### Step 2: Set the key in docker-compose.yml

```bash
# Replace YOUR_KEY with the output from the command above
sed -i '' 's|SEMAPHORE_ACCESS_KEY_ENCRYPTION:.*|SEMAPHORE_ACCESS_KEY_ENCRYPTION: "YOUR_KEY"|' \
  awx-local/docker-compose.yml
```

### Step 3: Start Semaphore and ngrok

```bash
chmod +x scripts/start-awx.sh
./scripts/start-awx.sh
```

Semaphore is ready in about **10 seconds**. When the script finishes it prints:

```
✅ Semaphore is running at http://localhost:3000
   Credentials: admin / changeme123

✅ ngrok public URL: https://abc123def456.ngrok-free.app

  ➡  Set TF_VAR_awx_host in env0 to:
     https://abc123def456.ngrok-free.app
```

**Copy the ngrok URL** — you will need it in Part 6.

> ⚠️ The ngrok URL changes every time you restart it.
> After restarting, always update `TF_VAR_awx_host` in env0.

---

## Part 5 — Configure Semaphore

### Option A: Automated script (recommended)

```bash
chmod +x scripts/configure-semaphore.sh
./scripts/configure-semaphore.sh
# When prompted:
#   GitHub repo URL: https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo
#   SSH key file: ~/.ssh/env0-demo-key.pem  (press Enter for default)
```

At the end it prints:

```
TF_VAR_awx_job_template_id = 1       ← Semaphore Template ID
TF_VAR_awx_token           = abc...  ← copy this NOW (not shown again)
```

### Option B: Manual via Semaphore UI (http://localhost:3000)

**1. Create an API Token**
- Click your username (top-right) → **Your Profile** → **API Tokens** → **Add Token**
- Copy the token — shown only once

**2. Add SSH Key (Key Store)**
- Left sidebar → **Key Store** → **New Key**
- Name: `EC2 SSH Key` | Type: **SSH Key** | Username: `ubuntu`
- Private Key: `cat ~/.ssh/env0-demo-key.pem | pbcopy` then paste
- Click **Save**

**3. Add Repository**
- Left sidebar → **Repositories** → **New Repository**
- Name: `env0-ansible-demo`
- URL: `https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo`
- Branch: `main` | Access Key: **None** (public repo)
- Click **Save**

**4. Add Inventory**
- Left sidebar → **Inventory** → **New Inventory**
- Name: `EC2 Dynamic` | Type: **Static**
- Content: `localhost`
- User Credentials: `EC2 SSH Key`
- Click **Save**

**5. Create Task Template**
- Left sidebar → **Task Templates** → **New Template**
- Name: `Deploy Website`
- Playbook: `ansible/playbooks/deploy_website.yml`
- Inventory: `EC2 Dynamic` | Repository: `env0-ansible-demo`
- Click **Save** — note the Template ID from the URL

---

## Part 6 — Set up env0

### Create account and connect GitHub

1. Sign up at https://app.env0.com
2. **Settings** → **VCS Providers** → **Add** → **GitHub** → authorize

### Create a Template

1. **Templates** → **+ New Template** → **Terraform**
2. Repository: `env0-ec2-ansible-demo` | Branch: `main`
3. Working directory: `terraform/` | Terraform version: `1.7.0`
4. Click **Next**

### Set up the self-hosted agent

1. **Settings** → **Agents** → **New Agent**
2. Name: `local-mac-agent` → **Create Agent** → copy the API key

```bash
export ENV0_AGENT_API_KEY="paste-your-key-here"
chmod +x scripts/start-agent.sh
./scripts/start-agent.sh
```

The agent shows **Connected** in env0 within 30 seconds.

5. In the Template settings → **Agent** → select `local-mac-agent` → **Save**

### Add all variables to env0

In the Template → **Variables**, add each of the following.
Mark sensitive variables accordingly — env0 will never display them again.

| Variable name                | Value                                              | Type        | Sensitive? |
|------------------------------|----------------------------------------------------|-------------|------------|
| `AWS_ACCESS_KEY_ID`          | `aws configure get aws_access_key_id`              | Environment | No         |
| `AWS_SECRET_ACCESS_KEY`      | `aws configure get aws_secret_access_key`          | Environment | **YES**    |
| `TF_VAR_awx_host`            | your ngrok URL (e.g. `https://abc.ngrok-free.app`) | Environment | No         |
| `TF_VAR_awx_token`           | Semaphore API token                                | Environment | **YES**    |
| `TF_VAR_key_name`            | `env0-demo-key`                                    | Terraform   | No         |
| `TF_VAR_awx_job_template_id` | Semaphore Template ID                              | Terraform   | No         |
| `TF_VAR_instance_type`       | `t2.micro`                                         | Terraform   | No         |
| `TF_VAR_auto_stop_hours`     | `4`                                                | Terraform   | No         |
| `TF_VAR_ebs_volume_size_gb`  | `20`                                               | Terraform   | No         |
| `TF_VAR_environment_name`    | `demo`                                             | Terraform   | No         |
| `TF_VAR_project_name`        | `env0-demo`                                        | Terraform   | No         |

### Create the env0 Workflow

1. **Workflows** → **+ New Workflow** → Name: `EC2 + Ansible Deploy`
2. Step 1 — **Plan**: Template → `AWS EC2 + Ansible Semaphore Demo`, Action → **Plan**
3. Step 2 — **Approval**: pauses for your review
4. Step 3 — **Apply**: same template, Action → **Deploy**
5. **Save Workflow**

---

## Part 7 — Run the full deployment

Pre-flight checklist:

```
[ ] Docker Desktop is running
[ ] Semaphore is up:  curl -s http://localhost:3000/api/ping
[ ] ngrok is active:  curl -s http://localhost:4040/api/tunnels | python3 -m json.tool
[ ] env0 agent shows "Connected" in app.env0.com → Settings → Agents
[ ] TF_VAR_awx_host matches the current ngrok URL
[ ] All 11 variables are set in the env0 template
[ ] Key pair exists:  aws ec2 describe-key-pairs --key-names env0-demo-key
```

### Trigger and watch

1. **Workflows** → `EC2 + Ansible Deploy` → **Run Workflow**
2. Review the Plan output — confirm it shows `+aws_instance`, `+aws_security_group`, `+aws_eip`
3. Click **Approve**
4. Apply completes in 1–2 minutes — env0 shows:
   ```
   website_url = "http://1.2.3.4"
   ssh_command = "ssh -i ~/.ssh/env0-demo-key.pem ubuntu@1.2.3.4"
   ```

Watch the EC2 bootstrap live:

```bash
ssh -i ~/.ssh/env0-demo-key.pem ubuntu@YOUR_EC2_IP \
  'sudo tail -f /var/log/user-data.log'
```

Watch Ansible run in Semaphore at http://localhost:3000 → **Task History**.

Once the task completes, open `http://YOUR_EC2_IP` — the deployed website
shows the full pipeline, instance ID, OS version, and deployment timestamp.

---

## Part 8 — Managing the instance (save money)

### Auto-stop

The instance shuts itself down `auto_stop_hours` after first boot (default: 4).
This prevents runaway costs if you forget about it.

### Restart a stopped instance

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ec2 start-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
```

The website returns at the same IP (Elastic IP persists through stop/start).

### Scheduled destroy/redeploy

In env0 → **Workflows** → **Settings** → **Schedule**:
- Destroy: `0 22 * * *` (10 PM nightly)
- Deploy:  `0 8 * * 1-5` (8 AM weekdays)

### Check AWS charges

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY --metrics BlendedCost \
  --query 'ResultsByTime[0].Total.BlendedCost.Amount' --output text
```

---

## Part 9 — Destroy everything (cleanup)

### Via env0 (recommended)
In env0 → your environment → **Destroy**

### Via Terraform CLI
```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Fill in your values, then:
terraform init && terraform destroy
```

### Stop local services
```bash
./scripts/stop-awx.sh
docker stop env0-agent
```

---

## Troubleshooting

| Problem | Steps |
|---|---|
| env0 agent not connecting | `docker logs env0-agent --tail 50` — check `AGENT_API_KEY` |
| Semaphore not starting | `docker compose -f awx-local/docker-compose.yml logs` — check encryption key length (`openssl rand -base64 32`) |
| ngrok URL not working | `curl -s http://localhost:4040/api/tunnels` — restart with `ngrok http 3000` and update `TF_VAR_awx_host` |
| EC2 can't reach Semaphore | `ssh ubuntu@IP 'cat /var/log/user-data.log'` — look for HTTP 000 errors |
| Ansible task UNREACHABLE | Check EC2 security group allows port 22; verify SSH key in Semaphore Key Store |
| Permission denied (publickey) | Re-paste key from `cat ~/.ssh/env0-demo-key.pem` into Semaphore Key Store |
| dpkg lock error | Wait 30 seconds and re-run the Semaphore task |
| Default NGINX page showing | `ssh ubuntu@IP 'cat /var/www/html/index.html'` — re-run the Semaphore task |

### Re-trigger Semaphore manually

```bash
EC2_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

curl -s -X POST "https://YOUR_NGROK_URL/api/project/1/tasks" \
  -H "Authorization: Bearer YOUR_SEMAPHORE_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"template_id\": YOUR_TEMPLATE_ID, \"extra_vars\": \"target_host: $EC2_IP\"}"
```

---

## Free tier cost breakdown

| Resource             | Free tier limit           | Cost if exceeded     |
|----------------------|---------------------------|----------------------|
| EC2 t2.micro         | 750 hrs/month (first yr)  | ~$0.0116/hr          |
| EBS gp3 20 GB        | 30 GB/month (first yr)    | $0.08/GB/month       |
| Elastic IP           | Free while associated     | $0.005/hr if idle    |
| Data transfer out    | 100 GB/month              | $0.09/GB             |

With `auto_stop_hours=4` and 1–2 deployments/week: **$0.00/month** for year 1.

---

## Quick reference

```bash
# ── Daily startup ──────────────────────────────────────────────────────────
./scripts/start-awx.sh                      # Start Semaphore + ngrok
export ENV0_AGENT_API_KEY="..."
./scripts/start-agent.sh                    # Start env0 agent

# ── Get current ngrok URL ──────────────────────────────────────────────────
curl -s http://localhost:4040/api/tunnels | python3 -c "
import sys,json; t=json.load(sys.stdin)['tunnels']
print(next(x['public_url'] for x in t if x['proto']=='https'))"

# ── EC2 management ─────────────────────────────────────────────────────────
# Start stopped instance:
aws ec2 start-instances --instance-ids $(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Get website URL:
aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=env0-demo-eip" \
  --query 'Addresses[0].PublicIp' --output text

# Watch bootstrap log:
ssh -i ~/.ssh/env0-demo-key.pem ubuntu@$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=env0-demo-eip" \
  --query 'Addresses[0].PublicIp' --output text) \
  'sudo tail -f /var/log/user-data.log'

# ── Cleanup ────────────────────────────────────────────────────────────────
./scripts/stop-awx.sh
docker stop env0-agent
```
