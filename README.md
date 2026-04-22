<h3 align="left">
  <img width="600" height="128" alt="image" src="https://raw.githubusercontent.com/artemis-env0/Packages/refs/heads/main/Images/Logo%20Pack/01%20Main%20Logo/Digital/SVG/envzero_logomark_fullcolor_rgb.svg" />
</h3>

---

# env0 + AWS EC2 + Ansible (Semaphore) — Complete Deployment Guide

## What you will build

```
You click "Run Workflow" in env0
        │
        ▼
env0 dispatches to your Mac agent (Docker)
        │
        ▼
Terraform runs on your Mac
  └─ Creates AWS Security Group
  └─ Provisions EC2 t2.micro (FREE TIER)
  └─ Attaches Elastic IP
        │
        ▼  (EC2 first boot)
user_data.sh runs on the instance
  └─ Installs curl + jq
  └─ Waits for Semaphore to respond
  └─ Calls Semaphore REST API: POST /api/project/1/tasks
  └─ Schedules auto-stop (4 hours by default)
        │
        ▼
Semaphore (running in Docker on your Mac, exposed via ngrok)
  └─ Receives the job trigger
  └─ Pulls latest playbook from GitHub
  └─ SSHs into the EC2 instance
  └─ Installs NGINX
  └─ Deploys the website from a Jinja2 template
        │
        ▼
Public website is live at http://<elastic-ip>
```

---

## Repository structure

```
env0-ec2-ansible-demo/
│
├── ansible.cfg                            Root-level Ansible config (roles_path, SSH settings)
├── .gitignore
├── .github/
│   └── workflows/
│       └── validate.yml                   CI: terraform validate + ansible-lint on push
│
├── terraform/
│   ├── main.tf                            EC2, Security Group, Elastic IP
│   ├── variables.tf                       All input variables with descriptions and validations
│   ├── outputs.tf                         Outputs after apply (IP, URL, SSH command)
│   ├── user_data.sh                       Bootstrap script — calls Semaphore API on first boot
│   └── terraform.tfvars.example           Copy to terraform.tfvars for local testing
│
├── ansible/
│   ├── ansible.cfg                        Ansible config inside the ansible/ folder (backup)
│   ├── requirements.yml                   Ansible Galaxy collections
│   ├── inventory/
│   │   └── hosts.ini                      Static inventory placeholder
│   └── playbooks/
│       └── deploy_website.yml             Main playbook — installs NGINX, deploys site
│   └── roles/
│       └── webserver/
│           ├── defaults/main.yml          Default variable values
│           ├── handlers/main.yml          NGINX reload/restart handlers
│           ├── tasks/main.yml             Install NGINX, configure, deploy content
│           └── templates/
│               ├── nginx.conf.j2          Main NGINX config
│               ├── site.conf.j2           NGINX virtual host
│               └── index.html.j2          Deployed webpage (Ansible facts injected)
│
├── awx-local/
│   ├── Dockerfile                         Extends Semaphore image with Ansible installed
│   └── docker-compose.yml                 Runs Semaphore + Postgres on your Mac
│
├── env0/
│   └── env0.yml                           env0 template configuration
│
└── scripts/
    ├── setup-aws.sh                       One-time AWS setup (key pair, billing alert)
    ├── start-awx.sh                       Starts Semaphore containers + ngrok tunnel
    ├── stop-awx.sh                        Gracefully stops Semaphore and ngrok
    ├── configure-semaphore.sh             Automates Semaphore setup via REST API
    └── start-agent.sh                     Starts the env0 agent Docker container
```

---

## Prerequisites

```bash
# 1. Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Docker Desktop — download from https://www.docker.com/products/docker-desktop
# After installing: Docker Desktop → Settings → Resources → Memory → 4096 MB

# 3. AWS CLI
brew install awscli

# 4. ngrok
brew install ngrok
ngrok config add-authtoken YOUR_NGROK_TOKEN   # sign up free at https://ngrok.com

# 5. Terraform (optional — for local CLI testing)
brew tap hashicorp/tap && brew install hashicorp/tap/terraform

# 6. Git
git --version   # install via: xcode-select --install
```

---

## Part 1 — Create an AWS account

1. Go to https://aws.amazon.com → **Create an AWS Account**
2. Use your Gmail as root email, choose **Personal**, enter billing info
3. Select **Basic support plan** (free)
4. In the AWS Console → **IAM → Users → Create user**
   - Username: `env0-deployer`
   - Attach: **AdministratorAccess**
5. Create **Access Keys** → type: **CLI** → copy both keys

```bash
aws configure
# AWS Access Key ID: paste key
# AWS Secret Access Key: paste secret
# Default region: us-east-1
# Default output: json

aws sts get-caller-identity   # verify it works
```

---

## Part 2 — Create the GitHub repository

1. Go to https://github.com → **New repository**
2. Name: `env0-ec2-ansible-demo`, set to **Public**
3. Clone it and push all project files:

```bash
git clone https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo.git
cd env0-ec2-ansible-demo
cp -r ~/path-to-these-files/* .
git add .
git commit -m "Initial commit"
git push origin main
```

---

## Part 3 — One-time AWS setup

```bash
chmod +x scripts/setup-aws.sh
./scripts/setup-aws.sh your@gmail.com
```

This creates the EC2 key pair (`~/.ssh/env0-demo-key.pem`) and a $1/month billing alert.

---

## Part 4 — Start Semaphore on your Mac

> **Note**: This project uses **Ansible Semaphore** (not AWX).
> AWX 18+ only runs on Kubernetes and cannot run in plain Docker Compose.
> Semaphore is the correct open-source Ansible UI for Docker-based setups.

```bash
chmod +x scripts/start-awx.sh
./scripts/start-awx.sh
```

This script:
1. Builds the Semaphore image with Ansible installed (from `awx-local/Dockerfile`)
2. Starts Semaphore + Postgres via Docker Compose
3. Starts ngrok to expose port 3000 publicly
4. Prints the ngrok URL to use as `TF_VAR_awx_host`

**Access Semaphore at: http://localhost:3000**
Credentials: `admin` / `changeme123`

### Important: encryption key

The `awx-local/docker-compose.yml` requires a valid 32-byte base64 key.
If Semaphore crashes with `access_key_encryption has invalid decoded length`, run:

```bash
KEY=$(openssl rand -base64 32)
sed -i '' "s|SEMAPHORE_ACCESS_KEY_ENCRYPTION:.*|SEMAPHORE_ACCESS_KEY_ENCRYPTION: \"$KEY\"|" awx-local/docker-compose.yml
docker compose -f awx-local/docker-compose.yml down -v
docker compose -f awx-local/docker-compose.yml up -d
```

---

## Part 5 — Configure Semaphore

### Option A: Automated script

```bash
chmod +x scripts/configure-semaphore.sh
./scripts/configure-semaphore.sh
# When prompted:
#   GitHub repo URL: https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo
#   SSH key file: ~/.ssh/env0-demo-key.pem (press Enter for default)
```

At the end it prints your `TF_VAR_awx_token` and `TF_VAR_awx_job_template_id`. **Copy the token immediately.**

### Option B: Manual via UI

Do these steps in order in the Semaphore UI:

**1 — Key Store** (sidebar → Key Store → +)
- Name: `EC2 SSH Key`, Type: SSH Key, Username: `ubuntu`
- Private Key: `cat ~/.ssh/env0-demo-key.pem | pbcopy` then paste

**2 — Repositories** (sidebar → Repositories → +)
- Name: `env0-ansible-demo`
- URL: `https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo`
- Branch: `main`, Access Key: `EC2 SSH Key`

**3 — Inventory** (sidebar → Inventory → +)
- Name: `EC2 Dynamic`, Type: Static
- Content: `localhost`, Credentials: `EC2 SSH Key`

**4 — Task Templates** (sidebar → Task Templates → +)
- Name: `Deploy Website`
- Playbook: `ansible/playbooks/deploy_website.yml`
- Repository: `env0-ansible-demo`
- Note the template ID from the URL bar (e.g. `/templates/1`) → `TF_VAR_awx_job_template_id`

**5 — Set app type via API** (required so Semaphore finds ansible-playbook):

```bash
TOKEN="your-token-here"
python3 << PYEOF
import urllib.request, json
TOKEN = "$TOKEN"
req = urllib.request.Request(
    "http://localhost:3000/api/project/1/templates/1",
    data=json.dumps({"id":1,"project_id":1,"inventory_id":1,
        "repository_id":1,"environment_id":1,"ssh_key_id":1,
        "name":"Deploy Website",
        "playbook":"ansible/playbooks/deploy_website.yml",
        "allow_override_args_in_task":True,"app":"ansible"}).encode(),
    headers={"Authorization":f"Bearer {TOKEN}","Content-Type":"application/json"},
    method="PUT")
urllib.request.urlopen(req)
print("Done")
PYEOF
```

**6 — Get API token**: http://localhost:3000/tokens → click 👁 on newest token

---

## Part 6 — Set up env0

### Create account and connect GitHub

1. Sign up at https://app.env0.com
2. **Settings → VCS Providers → Add → GitHub** → authorize

### Create a Template

1. **Templates → + New Template → Terraform**
2. Repository: `env0-ec2-ansible-demo`, Branch: `main`
3. Terraform working directory: `terraform/`
4. Terraform version: `1.7.0`

### Set up the self-hosted agent

```bash
# In env0: Settings → Agents → New Agent → copy the API key
export ENV0_AGENT_API_KEY="paste-your-key-here"
chmod +x scripts/start-agent.sh
./scripts/start-agent.sh
```

Agent shows **Connected** in env0 → Settings → Agents within 30 seconds.

Assign the agent to your template: Template Settings → Agent → `local-mac-agent`

### Add all variables to env0

| Variable | Value | Sensitive? |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | `aws configure get aws_access_key_id` | No |
| `AWS_SECRET_ACCESS_KEY` | `aws configure get aws_secret_access_key` | **YES** |
| `TF_VAR_awx_host` | ngrok URL (e.g. https://xxx.ngrok-free.app) | No |
| `TF_VAR_awx_token` | Semaphore API token | **YES** |
| `TF_VAR_key_name` | `env0-demo-key` | No |
| `TF_VAR_awx_job_template_id` | Template ID (e.g. `1`) | No |
| `TF_VAR_instance_type` | `t2.micro` | No |
| `TF_VAR_auto_stop_hours` | `4` | No |

> ⚠️ **Every time you restart ngrok, you get a new URL.**
> Update `TF_VAR_awx_host` in env0 before running the workflow.

### Create the Workflow

1. **Workflows → + New Workflow** → Name: `EC2 + Ansible Deploy`
2. Add Step 1: Template = `AWS EC2 + Ansible Tower Demo`, Action = **Plan**
3. Add Step 2: Type = **Approval**
4. Add Step 3: Template = same, Action = **Deploy**
5. Save

---

## Part 7 — Run the deployment

### Pre-flight checklist

```
[ ] Docker Desktop is running
[ ] Semaphore is up: curl -s http://localhost:3000/api/ping
[ ] Ansible is in container: docker exec semaphore ansible --version
[ ] ngrok is running: curl -s http://localhost:4040/api/tunnels | python3 -m json.tool
[ ] TF_VAR_awx_host matches CURRENT ngrok URL in env0
[ ] env0 agent shows "Connected"
[ ] All 8 variables set in env0
[ ] EC2 key pair exists: aws ec2 describe-key-pairs --key-names env0-demo-key
```

### Trigger

1. env0 → **Workflows → EC2 + Ansible Deploy → Run Workflow**
2. Review the Plan output
3. Click **Approve**
4. Watch the Apply — takes 1–2 minutes

### Watch bootstrap in real time

```bash
# Get EC2 IP from env0 outputs, then:
ssh -i ~/.ssh/env0-demo-key.pem ubuntu@YOUR_EC2_IP \
  'sudo tail -f /var/log/user-data.log'
```

Watch the Semaphore job at: http://localhost:3000/project/1/history

### Website

Once the Semaphore task completes, open `http://YOUR_ELASTIC_IP` — the page shows
the full pipeline, instance ID, OS version, and deployment timestamp.

---

## Part 8 — Cost savings

The instance auto-stops after 4 hours by default (`TF_VAR_auto_stop_hours=4`).

### Restart a stopped instance

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ec2 start-instances --instance-ids $INSTANCE_ID
```

### Check your bill

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --query 'ResultsByTime[0].Total.BlendedCost.Amount' \
  --output text
```

### Set $1 billing alert

```bash
chmod +x scripts/setup-aws.sh
./scripts/setup-aws.sh your@gmail.com
```

---

## Part 9 — Destroy everything

```bash
# Via env0
# Workflows → EC2 + Ansible Deploy → Destroy

# Or via Terraform CLI
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# fill in terraform.tfvars with your values
terraform init && terraform destroy

# Stop local services
docker compose -f awx-local/docker-compose.yml down
docker stop env0-agent
pkill -f "ngrok http"
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Semaphore crashes on startup | Regenerate encryption key: `KEY=$(openssl rand -base64 32)` and update `docker-compose.yml` |
| `exec: no command` in Semaphore | Run `docker exec semaphore ansible --version`. If missing, rebuild: `docker compose build --no-cache` |
| Role 'webserver' not found | Ensure `ansible.cfg` exists at repo root with `roles_path = ansible/roles` |
| AWX/Semaphore not reachable from EC2 | ngrok tunnel stopped — restart it and update `TF_VAR_awx_host` in env0 |
| ngrok URL changed | Re-run `ngrok http 3000`, update `TF_VAR_awx_host`, re-apply Terraform |
| env0 agent not connecting | Check `docker logs env0-agent`, verify `ENV0_AGENT_API_KEY` |
| user_data fails | `ssh ubuntu@IP 'cat /var/log/user-data.log'` |
| Website not loading | `ssh ubuntu@IP 'sudo systemctl status nginx'` |
| Instance stopped unexpectedly | Auto-stop fired. Restart: `aws ec2 start-instances --instance-ids <id>` |

---

## Daily startup commands

```bash
# 1. Start Semaphore + ngrok (get new URL each time)
./scripts/start-awx.sh

# 2. Update TF_VAR_awx_host in env0 with the new ngrok URL

# 3. Start env0 agent
export ENV0_AGENT_API_KEY="your-key"
./scripts/start-agent.sh

# 4. Run the workflow in env0 UI
```

---

## Free tier cost breakdown

| Resource | Free tier limit | Cost if exceeded |
|---|---|---|
| EC2 t2.micro | 750 hrs/month (year 1) | ~$0.012/hr |
| EBS gp3 20 GB | 30 GB/month (year 1) | $0.08/GB/month |
| Elastic IP | Free while associated | $0.005/hr if unassociated |
| Data transfer | 100 GB/month | $0.09/GB |

With `auto_stop_hours=4` and 1–2 deploys/week: **$0.00/month** for year 1.
