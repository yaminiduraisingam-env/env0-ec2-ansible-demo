# ─────────────────────────────────────────────────────────────────────────────
# main.tf
# Provisions:
#   - Security Group  (SSH + HTTP + HTTPS + egress)
#   - EC2 Instance    (Ubuntu 22.04, t2.micro free tier)
#   - Elastic IP      (optional, keeps IP stable across stop/start cycles)
#
# The instance runs user_data.sh on first boot, which:
#   1. Installs curl and jq
#   2. Waits for AWX to be reachable
#   3. Calls the AWX REST API to launch a Job Template
#   4. Schedules an auto-stop cron job (if auto_stop_hours > 0)
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ── Optional: remote state in S3 ──────────────────────────────────────────
  # Uncomment and fill in to store state remotely (recommended for teams).
  # Create the bucket first: aws s3 mb s3://your-tf-state-bucket
  #
  # backend "s3" {
  #   bucket         = "your-tf-state-bucket"
  #   key            = "env0-demo/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment_name
      ManagedBy   = "env0+terraform"
      AutoStop    = var.auto_stop_hours > 0 ? "enabled" : "disabled"
    }
  }
}

# ── Data: find the latest Ubuntu 22.04 LTS AMI ───────────────────────────────
# We always use the most recent Ubuntu 22.04 image published by Canonical.
# The owner ID 099720109477 is Canonical's official AWS account.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── Security Group ────────────────────────────────────────────────────────────
# Controls inbound and outbound traffic to the EC2 instance.
# Inbound:
#   Port 22  - SSH (from allowed_ssh_cidr; restrict to your IP in production)
#   Port 80  - HTTP (public, for the NGINX website)
#   Port 443 - HTTPS (public, for the NGINX website with SSL)
# Outbound:
#   All traffic allowed (needed for apt-get, curl to AWX, etc.)
resource "aws_security_group" "web_sg" {
  name        = "${var.project_name}-web-sg"
  description = "Allow SSH, HTTP, HTTPS inbound; all outbound"

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP for NGINX website"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description = "HTTPS for NGINX website"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description      = "All outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "${var.project_name}-web-sg"
  }
}

# ── EC2 Instance ──────────────────────────────────────────────────────────────
resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # When the OS issues a shutdown command, STOP (not terminate) the instance.
  # This preserves the EBS volume so you can restart later.
  instance_initiated_shutdown_behavior = "stop"

  # Root EBS volume — stay under 30 GB for free tier
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ebs_volume_size_gb
    delete_on_termination = true
    encrypted             = true

    tags = {
      Name = "${var.project_name}-root-volume"
    }
  }

  # IMDSv2 required — prevents SSRF-based metadata attacks
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # user_data runs exactly once on first boot.
  # templatefile() injects Terraform variables into the shell script.
  user_data = templatefile("${path.module}/user_data.sh", {
    awx_host            = var.awx_host
    awx_token           = var.awx_token
    awx_job_template_id = var.awx_job_template_id
    auto_stop_hours     = var.auto_stop_hours
    project_name        = var.project_name
    environment_name    = var.environment_name
  })

  # Replace the instance (not update in place) if user_data changes.
  # This ensures bootstrapping always runs fresh on the new image.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}-web"
  }
}

# ── Elastic IP ────────────────────────────────────────────────────────────────
# An EIP gives the instance a stable public IP that persists across
# stop/start cycles. Without an EIP, AWS assigns a new public IP every
# time the instance starts.
#
# Cost: EIPs are FREE while associated with a running instance.
#       You are charged $0.005/hr only if the EIP is unassociated (i.e.
#       the instance is stopped). Since we auto-stop, release the EIP
#       in the nightly scheduled workflow if cost is a concern.
resource "aws_eip" "web_eip" {
  instance = aws_instance.web.id
  domain   = "vpc"

  # Wait for the instance to exist before assigning the EIP
  depends_on = [aws_instance.web]

  tags = {
    Name = "${var.project_name}-eip"
  }
}
