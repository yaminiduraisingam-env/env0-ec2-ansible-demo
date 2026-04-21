# ─────────────────────────────────────────────────────────────────────────────
# variables.tf
# Declares every input variable used by main.tf.
# Sensitive variables (awx_token, aws keys) are never hard-coded here —
# they are injected by env0 at plan/apply time.
# ─────────────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy all resources into. us-east-1 is used for free-tier eligibility."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type.
    t2.micro = free tier eligible (750 hrs/month for first 12 months).
    Do NOT change to t3.micro unless you are past the free tier window —
    t3 is NOT free-tier eligible in all regions.
  EOT
  type    = string
  default = "t2.micro"

  validation {
    condition     = contains(["t2.micro", "t2.small", "t2.medium", "t3.micro"], var.instance_type)
    error_message = "Use t2.micro for free tier. Other values are allowed but will incur charges."
  }
}

variable "key_name" {
  description = <<-EOT
    Name of an existing AWS EC2 Key Pair.
    This must already exist in the target region before running apply.
    Create it with: aws ec2 create-key-pair --key-name env0-demo-key
  EOT
  type = string
}

variable "awx_host" {
  description = <<-EOT
    The publicly reachable URL of your Ansible Tower / AWX instance.
    For local Mac AWX exposed via ngrok: https://abc123.ngrok-free.app
    Include the scheme (https:// or http://) but NO trailing slash.
  EOT
  type = string

  validation {
    condition     = can(regex("^https?://", var.awx_host))
    error_message = "awx_host must start with http:// or https://"
  }
}

variable "awx_token" {
  description = <<-EOT
    AWX Personal Access Token with Write scope.
    Generate in AWX UI: User menu → Tokens → Add.
    Mark as SENSITIVE in env0 so it is never stored in plain text.
  EOT
  type      = string
  sensitive = true
}

variable "awx_job_template_id" {
  description = <<-EOT
    Numeric ID of the AWX Job Template to trigger.
    Find it in the AWX UI URL when viewing the template:
    e.g. /templates/job_template/7/ → ID is 7.
  EOT
  type = number
}

variable "auto_stop_hours" {
  description = <<-EOT
    Number of hours after first boot before the instance automatically stops.
    This prevents runaway costs if you forget to stop it manually.
    Set to 0 to disable auto-stop.
    Recommended: 4 for day-use demos, 1 for quick tests.
  EOT
  type    = number
  default = 4

  validation {
    condition     = var.auto_stop_hours >= 0 && var.auto_stop_hours <= 72
    error_message = "auto_stop_hours must be between 0 (disabled) and 72."
  }
}

variable "allowed_ssh_cidr" {
  description = <<-EOT
    CIDR block allowed to SSH into the instance.
    Default 0.0.0.0/0 is open for demo purposes.
    For production, restrict to your IP: $(curl -s ifconfig.me)/32
  EOT
  type    = string
  default = "0.0.0.0/0"
}

variable "ebs_volume_size_gb" {
  description = "Root EBS volume size in GB. Free tier allows up to 30 GB."
  type        = number
  default     = 20

  validation {
    condition     = var.ebs_volume_size_gb >= 8 && var.ebs_volume_size_gb <= 30
    error_message = "Keep EBS volume between 8 GB and 30 GB to stay in the free tier."
  }
}

variable "environment_name" {
  description = "Logical environment name — used in tags and the deployed webpage."
  type        = string
  default     = "demo"
}

variable "project_name" {
  description = "Project name prefix applied to all AWS resource names and tags."
  type        = string
  default     = "env0-demo"
}
