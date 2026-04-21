# env0 + AWS EC2 + Ansible Tower — Complete Deployment Guide

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
  └─ Waits for AWX to respond
  └─ Calls AWX REST API: POST /api/v2/job_templates/{id}/launch/
  └─ Schedules auto-stop (4 hours by default)
        │
        ▼
AWX (running in Docker on your Mac, exposed via ngrok)
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

Every file in this repo and what it does:

```
env0-ec2-ansible-demo/
│
├── .gitignore                         Excludes secrets and Terraform state
├── .github/
│   └── workflows/
│       └── validate.yml               CI: runs terraform validate + ansible-lint on push
│
├── terraform/
│   ├── main.tf                        Core infrastructure: EC2, Security Group, Elastic IP
│   ├── variables.tf                   All input variables with descriptions and validations
│   ├── outputs.tf                     Outputs printed after apply (IP, URL, SSH command)
│   ├── user_data.sh                   Bootstrap script that runs on EC2 first boot
│   └── terraform.tfvars.example       Template for local testing (copy to terraform.tfvars)
│
├── ansible/
│   ├── ansible.cfg                    Ansible settings (SSH, roles path, remote_user)
│   ├── requirements.yml               Ansible Galaxy collections to install
│   ├── inventory/
│   │   └── hosts.ini                  Static inventory placeholder (host injected at runtime)
│   └── playbooks/
│       └── deploy_website.yml         Main playbook — installs NGINX and deploys the site
│   └── roles/
│       └── webserver/
│           ├── defaults/
│           │   └── main.yml           Default variable values for the role
│           ├── handlers/
│           │   └── main.yml           Handlers (reload/restart NGINX on config change)
│           ├── tasks/
│           │   └── main.yml           Task list: install NGINX, configure, deploy content
│           └── templates/
│               ├── nginx.conf.j2      Main NGINX configuration
│               ├── site.conf.j2       NGINX virtual host config
│               └── index.html.j2      The deployed webpage (with Ansible facts injected)
│
├── awx-local/
│   └── docker-compose.yml             Runs AWX + Postgres + Redis on your Mac
│
├── env0/
│   └── env0.yml                       Tells env0 about the Terraform template
│
└── scripts/
    ├── setup-aws.sh                   One-time AWS setup (key pair, billing alert)
    ├── start-awx.sh                   Starts AWX containers + ngrok tunnel
    ├── stop-awx.sh                    Gracefully stops AWX and ngrok
    ├── configure-awx.sh               Automates AWX setup via REST API
    └── start-agent.sh                 Starts the env0 agent Docker container
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
- Click the gear icon → Resources → Memory → set to **4096 MB (4 GB)**
- This is required for AWX to run. Click "Apply & Restart".

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
   (you can restrict this to EC2/VPC only later)
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
4. Set to **Public** (required for AWX to clone without credentials)
   — or Private and add a GitHub credential to AWX (see Part 5)
5. Click **Create repository** (leave it empty — do not add a README yet)

### Clone it and add all project files

```bash
# Clone the empty repo
git clone https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo.git
cd env0-ec2-ansible-demo

# Copy all the files from this project into the repo
# (assuming you have this guide's files in ~/env0-demo-files/)
cp -r ~/env0-demo-files/* .

# Stage, commit, and push everything
git add .
git commit -m "Initial commit: Terraform + Ansible + env0 configuration"
git push origin main
```

After pushing, go to your GitHub repo and verify all files are present.
The GitHub Actions CI workflow (`.github/workflows/validate.yml`) will
automatically run terraform validate and ansible-lint on your push.

---

## Part 3 — One-time AWS setup

Run the setup script. It creates the EC2 key pair and billing alert:

```bash
chmod +x scripts/setup-aws.sh
./scripts/setup-aws.sh your@gmail.com
```

What this script does:
- Checks your AWS CLI credentials are valid
- Creates an EC2 Key Pair named `env0-demo-key` in `us-east-1`
- Saves the private key to `~/.ssh/env0-demo-key.pem` with permission 400
- Creates a $1/month billing budget alert to your email

At the end, it prints the values you need to enter into env0. **Save this output.**

---

## Part 4 — Start AWX on your Mac

AWX is the open-source version of Red Hat Ansible Automation Platform.
It provides the REST API that the EC2 instance calls on boot.

### Start AWX and ngrok together

```bash
chmod +x scripts/start-awx.sh
./scripts/start-awx.sh
```

This script:
1. Checks Docker Desktop has enough memory
2. Runs `docker compose up -d` in the `awx-local/` directory
3. Waits for AWX to respond at http://localhost:8052
4. Starts ngrok to expose port 8052 publicly
5. Prints the ngrok public URL

**Wait for the script to finish before proceeding.** First-time startup
takes 2–4 minutes while AWX initializes the database.

When the script prints something like:

```
✅ ngrok public URL: https://abc123def456.ngrok-free.app

  ➡  Update TF_VAR_awx_host in env0 to:
     https://abc123def456.ngrok-free.app
```

**Copy that URL.** You will set it as `TF_VAR_awx_host` in env0 (Part 6).

Open AWX at http://localhost:8052 — log in with `admin` / `password`.

---

## Part 5 — Configure AWX

You can do this manually via the UI, or run the automated script.

### Option A: Automated (recommended)

```bash
chmod +x scripts/configure-awx.sh
./scripts/configure-awx.sh
# When prompted:
#   GitHub repo URL: https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo
#   SSH key file: ~/.ssh/env0-demo-key.pem  (press Enter for default)
```

The script creates everything in AWX and prints two values at the end:

```
TF_VAR_awx_job_template_id = 7       ← note this
TF_VAR_awx_token           = abc...  ← copy this NOW (not shown again)
```

### Option B: Manual via AWX UI

If you prefer clicking through the UI, follow these steps in order.
All are under http://localhost:8052 → left sidebar.

#### Step B-1: Create a Credential

A credential stores the SSH private key so AWX can log into EC2.

1. Sidebar → **Credentials** → **Add**
2. Name: `EC2 SSH Key`
3. Credential Type: **Machine**
4. Username: `ubuntu`  (Ubuntu EC2 instances always use this username)
5. SSH Private Key: paste the contents of `~/.ssh/env0-demo-key.pem`
   ```bash
   cat ~/.ssh/env0-demo-key.pem | pbcopy   # copies to clipboard on Mac
   ```
6. Click **Save**

#### Step B-2: Create a Project

A project links AWX to your GitHub repo where the playbooks live.

1. Sidebar → **Projects** → **Add**
2. Name: `env0-ansible-demo`
3. Source Control Type: **Git**
4. Source Control URL: `https://github.com/YOUR_USERNAME/env0-ec2-ansible-demo`
5. Source Control Branch: `main`
6. Check **Update Revision on Launch** — this pulls the latest playbooks every time
7. Check **Clean** — ensures a clean checkout each run
8. Click **Save**

AWX will immediately try to clone the repo. The project card shows a spinning
sync icon — wait until it turns green (✅ Successful) before continuing.

If it fails with "Permission denied": your repo may be private.
Either make it public, or add a GitHub credential (Credential Type: Source Control)
with a GitHub personal access token and link it to the project.

#### Step B-3: Create an Inventory

An inventory tells AWX which hosts to target. The actual EC2 IP is
injected at job launch time, so this is a placeholder.

1. Sidebar → **Inventories** → **Add** → **Add Inventory**
2. Name: `EC2 Dynamic Inventory`
3. Click **Save**

#### Step B-4: Create a Job Template

A Job Template links the inventory, project, playbook, and credential together.

1. Sidebar → **Templates** → **Add** → **Add Job Template**
2. Name: `Deploy Website`
3. Job Type: **Run**
4. Inventory: `EC2 Dynamic Inventory`
5. Project: `env0-ansible-demo`
6. Playbook: `ansible/playbooks/deploy_website.yml`
   (this dropdown appears once the project syncs successfully)
7. Credentials: click the search icon → select `EC2 SSH Key`
8. Extra Variables: paste this exactly:
   ```yaml
   ---
   target_host: "localhost"
   project_name: "env0-demo"
   environment_name: "demo"
   instance_id: "unknown"
   ```
9. Check **Prompt on Launch** next to Extra Variables
   (this allows user_data.sh to override the target_host at job launch)
10. Verbosity: **1 (Verbose)** — useful for debugging
11. Click **Save**

Note the Job Template ID from the URL bar:
`http://localhost:8052/#/templates/job_template/7/` → ID is **7**

#### Step B-5: Create a Personal Access Token

This token is what user_data.sh uses to authenticate with the AWX API.

1. Click your username in the top-right → **User Details**
2. Click the **Tokens** tab
3. Click **Add**
4. Description: `env0 Terraform integration`
5. Scope: **Write**
6. Click **Save**
7. **Copy the token that appears** — it is shown only once

---

## Part 6 — Set up env0

### Create an env0 account

Go to https://app.env0.com and sign up. The free plan supports this demo.

### Connect your GitHub repository

1. In env0, click **Settings** (left sidebar) → **VCS Providers**
2. Click **Add VCS Provider** → **GitHub**
3. Click **Connect with GitHub** — authorize env0 to access your repos
4. Select your repository: `env0-ec2-ansible-demo`

### Create a Template

1. Left sidebar → **Templates** → **+ New Template**
2. Select **Terraform**
3. Repository: select `env0-ec2-ansible-demo` (it appears after connecting GitHub)
4. Branch: `main`
5. Terraform working directory: `terraform/`
6. Terraform version: `1.7.0`
7. Click **Next**

### Set up the self-hosted agent

The template needs to run on YOUR Mac, not env0's cloud runners.
This is required because your AWX is running locally.

1. Left sidebar → **Settings** → **Agents** → **New Agent**
2. Name: `local-mac-agent`
3. Click **Create Agent** — an API key is displayed
4. Copy the API key

Now start the agent on your Mac:

```bash
export ENV0_AGENT_API_KEY="paste-your-key-here"
chmod +x scripts/start-agent.sh
./scripts/start-agent.sh
```

Go back to env0 → **Settings → Agents** — your agent should show
**Connected** within 30 seconds.

5. Go back to your Template settings → **Agent** → select `local-mac-agent`
6. Click **Save**

### Add all variables to env0

In the Template, click **Variables**. Add each variable below.
Variables marked SENSITIVE must be toggled to sensitive — env0 will
never display their value again after saving.

| Variable name               | Value                                   | Type              | Sensitive? |
|-----------------------------|-----------------------------------------|-------------------|------------|
| `AWS_ACCESS_KEY_ID`         | from `aws configure get aws_access_key_id` | Environment    | No         |
| `AWS_SECRET_ACCESS_KEY`     | from `aws configure get aws_secret_access_key` | Environment | **YES**    |
| `TF_VAR_awx_host`           | your ngrok URL (e.g. https://abc.ngrok-free.app) | Environment | No    |
| `TF_VAR_awx_token`          | token from AWX User → Tokens            | Environment       | **YES**    |
| `TF_VAR_key_name`           | `env0-demo-key`                         | Terraform         | No         |
| `TF_VAR_awx_job_template_id`| Job Template ID from AWX (e.g. `7`)     | Terraform         | No         |
| `TF_VAR_instance_type`      | `t2.micro`                              | Terraform         | No         |
| `TF_VAR_auto_stop_hours`    | `4`                                     | Terraform         | No         |
| `TF_VAR_ebs_volume_size_gb` | `20`                                    | Terraform         | No         |
| `TF_VAR_environment_name`   | `demo`                                  | Terraform         | No         |
| `TF_VAR_project_name`       | `env0-demo`                             | Terraform         | No         |

To get your AWS keys from the terminal:

```bash
aws configure get aws_access_key_id
aws configure get aws_secret_access_key
```

### Create the env0 Workflow

A Workflow chains multiple steps together. You will create:

```
Step 1 → Terraform Plan   (previews what will be created)
Step 2 → Approval Gate    (you review the plan before it runs)
Step 3 → Terraform Apply  (provisions the infrastructure)
```

1. Left sidebar → **Workflows** → **+ New Workflow**
2. Name: `EC2 + Ansible Deploy`
3. Add Step 1:
   - Step name: `Plan`
   - Template: `AWS EC2 + Ansible Tower Demo`
   - Action: **Plan**
4. Add Step 2:
   - Click the **+** after Step 1
   - Type: **Approval**
   - This pauses the workflow and emails you to review the plan
5. Add Step 3:
   - Step name: `Apply`
   - Template: `AWS EC2 + Ansible Tower Demo`
   - Action: **Deploy** (this runs terraform apply)
6. Click **Save Workflow**

---

## Part 7 — Run the full deployment

You are now ready. Before triggering the workflow, verify the checklist:

```
[ ] Docker Desktop is running with 4+ GB RAM
[ ] AWX is running: curl -s http://localhost:8052/api/v2/ping/ | python3 -m json.tool
[ ] ngrok tunnel is active: curl -s http://localhost:4040/api/tunnels | python3 -m json.tool
[ ] env0 agent shows "Connected" in app.env0.com → Settings → Agents
[ ] TF_VAR_awx_host in env0 matches the CURRENT ngrok URL
[ ] All 11 variables are set in env0 template
[ ] EC2 key pair exists: aws ec2 describe-key-pairs --key-names env0-demo-key
```

### Trigger the workflow

1. In env0, go to **Workflows** → `EC2 + Ansible Deploy`
2. Click **Run Workflow**
3. Watch the **Plan** step execute — this takes ~30 seconds

The plan output shows exactly what Terraform will create:
```
+ aws_instance.web
+ aws_security_group.web_sg
+ aws_eip.web_eip
```

4. If the plan looks correct, click **Approve** on the Approval step
5. The **Apply** step begins — this takes 1–2 minutes to provision EC2

Once the apply finishes, env0 shows the outputs:

```
website_url   = "http://1.2.3.4"
ssh_command   = "ssh -i ~/.ssh/env0-demo-key.pem ubuntu@1.2.3.4"
```

### What happens next (automatically)

The EC2 instance boots and runs `user_data.sh`. You can watch it in real time:

```bash
# Replace with your actual IP from env0 outputs
ssh -i ~/.ssh/env0-demo-key.pem ubuntu@YOUR_EC2_IP \
  'sudo tail -f /var/log/user-data.log'
```

You will see output like:

```
==============================================
 env0-demo (demo) bootstrap
 Started: 2024-01-15T10:30:00Z
==============================================
[1/5] Installing curl and jq...
[2/5] Retrieving instance metadata via IMDSv2...
      Instance ID : i-0abc1234
      Public IP   : 1.2.3.4
[3/5] Waiting for AWX at https://abc123.ngrok-free.app ...
      AWX responded 200 OK after 15 seconds
[4/5] Triggering AWX Job Template ID 7 ...
      AWX Job ID     : 42
      AWX Job Status : pending
[5/5] Scheduling auto-stop in 4 hours
==============================================
 Bootstrap complete: 2024-01-15T10:31:15Z
 Website will be live once AWX job 42 finishes.
==============================================
```

Now open AWX at http://localhost:8052 → **Jobs**. You will see job #42
running. Click it to watch Ansible configure the server in real time:

```
PLAY [Deploy and verify public NGINX website] **********************************

TASK [Gathering Facts] *********************************************************
ok: [1.2.3.4]

TASK [webserver : Update apt package cache] ************************************
changed: [1.2.3.4]

TASK [webserver : Install NGINX] ***********************************************
changed: [1.2.3.4]

TASK [webserver : Deploy custom nginx.conf] ************************************
changed: [1.2.3.4]

TASK [webserver : Deploy index.html from Jinja2 template] **********************
changed: [1.2.3.4]

TASK [webserver : Enable and start NGINX service] ******************************
ok: [1.2.3.4]

TASK [Smoke test — verify website returns HTTP 200] ****************************
ok: [1.2.3.4 -> localhost]

TASK [Print website URL] *******************************************************
ok: [1.2.3.4] => {
    "msg": [
        "✅ Deployment complete!",
        "Website URL: http://1.2.3.4"
    ]
}

PLAY RECAP *********************************************************************
1.2.3.4                    : ok=9  changed=5  unreachable=0  failed=0
```

### View the deployed website

Open `http://YOUR_EC2_IP` in your browser. You will see the website
showing the full deployment pipeline, the instance ID, OS version, and
the exact timestamp Ansible deployed it.

---

## Part 8 — Managing the instance (save money)

### The auto-stop is already configured

The instance shuts itself down 4 hours after boot by default.
This means if you run a deployment in the morning and forget about it,
it will stop itself by the afternoon — no runaway charges.

### Restart a stopped instance

When the instance stops, your Elastic IP stays reserved (no charge
while associated, even if stopped). To restart:

```bash
# Get the instance ID
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ec2 start-instances --instance-ids $INSTANCE_ID
echo "Starting $INSTANCE_ID..."

# Wait for it to be running
aws ec2 wait instance-running --instance-ids $INSTANCE_ID
echo "Instance is running"
```

The website will be back at the same IP as before (because of the Elastic IP).
Note: user_data.sh only runs on first boot — NGINX and the website
are already installed on the stopped EBS volume.

### Run a scheduled destroy/redeploy in env0

For maximum cost savings, use env0's schedule feature to destroy
and re-create the stack on a schedule.

1. In env0 → **Workflows** → **EC2 + Ansible Deploy** → **Settings**
2. Click **Schedule**
3. Add a destroy schedule: cron `0 22 * * *` (10 PM nightly)
4. Add a deploy schedule:  cron `0 8 * * 1-5` (8 AM weekdays only)

When the stack is destroyed, the EIP is released. When it's re-created,
you get a new EIP. The website URL changes each time.

### Check your AWS bill any time

```bash
# See this month's total charges
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --query 'ResultsByTime[0].Total.BlendedCost.Amount' \
  --output text
```

---

## Part 9 — Destroy everything (cleanup)

When you are done experimenting and want to avoid any possible charges:

### Option A: Destroy via env0

1. In env0 → your environment → click **Destroy**
2. env0 runs `terraform destroy` which removes the EC2 instance,
   security group, and Elastic IP

### Option B: Destroy via Terraform CLI

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your actual values
terraform init
terraform destroy
```

### Option C: Destroy via AWS CLI (nuclear option)

```bash
# Stop and terminate the instance
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:ManagedBy,Values=env0+terraform" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ec2 terminate-instances --instance-ids $INSTANCE_ID

# Release the Elastic IP
EIP_ALLOC=$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=env0-demo-eip" \
  --query 'Addresses[0].AllocationId' \
  --output text)

aws ec2 release-address --allocation-id $EIP_ALLOC

# Delete the security group (after instance is terminated)
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=env0-demo-web-sg" \
  --query 'SecurityGroups[0].GroupId' \
  --output text)
aws ec2 delete-security-group --group-id $SG_ID
```

### Stop AWX and the env0 agent

```bash
./scripts/stop-awx.sh
docker stop env0-agent
```

---

## Troubleshooting

### env0 agent is not connecting

```bash
# Check the agent container is running
docker ps | grep env0-agent

# Read the agent logs
docker logs env0-agent --tail 50

# Common causes:
# - AGENT_API_KEY is wrong → generate a new one in env0 UI
# - Docker socket not mounted → check the -v /var/run/docker.sock flag
# - Network issue → ensure Mac has internet access
```

### AWX is not responding

```bash
# Check all three containers are running
cd awx-local
docker compose ps

# Read AWX logs
docker compose logs awx_web --tail 50

# Common causes:
# - Not enough RAM → increase Docker Desktop memory to 4 GB
# - Database not ready → wait 2 more minutes, check awx_postgres logs
# - Port 8052 in use → change the port in docker-compose.yml
```

### ngrok URL is not working

```bash
# Check ngrok is running
ps aux | grep ngrok

# Get the current URL
curl -s http://localhost:4040/api/tunnels | python3 -c "
import sys, json
tunnels = json.load(sys.stdin).get('tunnels', [])
for t in tunnels:
    print(t['proto'], '->', t['public_url'])
"

# Restart ngrok if needed
pkill -f "ngrok http" && ngrok http 8052 &

# After restarting, update TF_VAR_awx_host in env0 and re-apply
```

### user_data.sh fails — AWX not reachable

The EC2 instance cannot reach AWX. SSH in and check the log:

```bash
ssh -i ~/.ssh/env0-demo-key.pem ubuntu@YOUR_EC2_IP 'cat /var/log/user-data.log'
```

Look for lines like:
```
Attempt 1/20 — HTTP 000 — retrying in 15s...
```
HTTP 000 means the connection was refused entirely. Causes:
- ngrok tunnel stopped (restart it and update TF_VAR_awx_host)
- AWX stopped (run `docker compose up -d` in awx-local/)
- Wrong awx_host URL (missing https://, trailing slash, etc.)

### Ansible job fails in AWX

Open AWX → Jobs → click the failed job → read the red task output.

Common failures:

**"UNREACHABLE" on EC2 host:**
```
fatal: [1.2.3.4]: UNREACHABLE! => {"msg": "Failed to connect to the host via ssh"}
```
- AWX is trying to SSH to the EC2 IP but failing
- Check the EC2 security group allows port 22 inbound
- Check the credential has the correct private key
- Verify the instance is running: `aws ec2 describe-instances --instance-ids i-xxx`

**"Permission denied" on SSH:**
```
fatal: [1.2.3.4]: UNREACHABLE! => {"msg": "Permission denied (publickey)"}
```
- The SSH key in AWX does not match the EC2 key pair
- Verify: `cat ~/.ssh/env0-demo-key.pem` matches what's in AWX credential

**NGINX install fails:**
```
TASK [webserver : Install NGINX] ***
fatal: [1.2.3.4]: FAILED! => {"msg": "Could not get lock /var/lib/dpkg/lock"}
```
- apt is still running from user_data.sh — wait 30 seconds and retry the AWX job

### Website loads but shows default NGINX page

Ansible ran but the template may not have deployed. SSH in and check:

```bash
ssh -i ~/.ssh/env0-demo-key.pem ubuntu@YOUR_EC2_IP
cat /var/www/html/index.html   # Should show the Jinja2-rendered HTML
sudo nginx -t                  # Test NGINX config
sudo systemctl status nginx    # Check NGINX is running
```

### How to re-run the AWX playbook manually

If you want to re-run the Ansible playbook without re-provisioning EC2:

```bash
# Get your EC2 IP
EC2_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

# Trigger AWX manually via curl
curl -sk -X POST \
  "https://YOUR_NGROK_URL/api/v2/job_templates/YOUR_JT_ID/launch/" \
  -H "Authorization: Bearer YOUR_AWX_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"extra_vars\": {\"target_host\": \"$EC2_IP\"}}"
```

---

## Free tier — complete cost breakdown

| Resource          | Usage                   | Free tier limit        | Cost if exceeded    |
|-------------------|-------------------------|------------------------|---------------------|
| EC2 t2.micro      | Up to 750 hrs/month     | 750 hrs/month (yr 1)   | ~$0.0116/hr         |
| EBS gp3 20 GB     | Always-on               | 30 GB/month (yr 1)     | $0.08/GB/month      |
| Elastic IP        | While instance running  | Free (while associated)| $0.005/hr if idle   |
| Data transfer out | First 100 GB/month      | 100 GB/month           | $0.09/GB            |
| Lambda + EventBridge | <1M invocations/month | Always free          | Effectively $0      |

With auto_stop_hours=4 and typical demo use (1–2 deployments/week),
your monthly cost should be **$0.00** for the first 12 months.

After 12 months, a t2.micro costs approximately **$8.47/month** if
run 24/7. With the auto-stop strategy, closer to **$1–2/month**.

---

## Quick reference — commands you will use repeatedly

```bash
# ── Daily startup ─────────────────────────────────────────────────────────
./scripts/start-awx.sh              # Start AWX + ngrok
export ENV0_AGENT_API_KEY="..."
./scripts/start-agent.sh            # Start env0 agent

# ── After restarting ngrok (URL changes!) ─────────────────────────────────
# Update TF_VAR_awx_host in env0 UI → Variables
# OR:
NEW_URL=$(curl -s http://localhost:4040/api/tunnels | python3 -c "
import sys,json; t=json.load(sys.stdin)['tunnels']
print(next(x['public_url'] for x in t if x['proto']=='https'))
")
echo "New ngrok URL: $NEW_URL"
echo "Update TF_VAR_awx_host in env0 to: $NEW_URL"

# ── EC2 management ────────────────────────────────────────────────────────
# Start a stopped instance:
aws ec2 start-instances --instance-ids $(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Stop an instance immediately:
aws ec2 stop-instances --instance-ids $(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=env0-demo-web" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Get the website URL:
aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=env0-demo-eip" \
  --query 'Addresses[0].PublicIp' \
  --output text

# Watch EC2 bootstrap log live:
ssh -i ~/.ssh/env0-demo-key.pem ubuntu@$(aws ec2 describe-addresses \
  --filters "Name=tag:Name,Values=env0-demo-eip" \
  --query 'Addresses[0].PublicIp' --output text) \
  'sudo tail -f /var/log/user-data.log'

# ── Cleanup ───────────────────────────────────────────────────────────────
./scripts/stop-awx.sh               # Stop AWX + ngrok
docker stop env0-agent              # Stop env0 agent
```
