# ─────────────────────────────────────────────────────────────────────────────
# outputs.tf
# Values printed after terraform apply and stored in env0 run outputs.
# Reference these in subsequent workflow steps with:
#   ${{ steps.<step-name>.outputs.public_ip }}
# ─────────────────────────────────────────────────────────────────────────────

output "instance_id" {
  description = "EC2 instance ID — use this to start/stop via AWS CLI"
  value       = aws_instance.web.id
}

output "instance_type" {
  description = "Confirms which instance type was provisioned"
  value       = aws_instance.web.instance_type
}

output "ami_id" {
  description = "AMI ID used — helpful for auditing which Ubuntu version was deployed"
  value       = data.aws_ami.ubuntu.id
}

output "public_ip" {
  description = "Elastic IP — stable across stop/start cycles"
  value       = aws_eip.web_eip.public_ip
}

output "public_dns" {
  description = "EC2 public DNS hostname (changes on stop/start if using direct instance DNS)"
  value       = aws_instance.web.public_dns
}

output "website_url" {
  description = "Direct link to the NGINX website deployed by Ansible"
  value       = "http://${aws_eip.web_eip.public_ip}"
}

output "ssh_command" {
  description = "Ready-to-run SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.web_eip.public_ip}"
}

output "auto_stop_info" {
  description = "Auto-stop configuration summary"
  value = var.auto_stop_hours > 0 ? (
    "Instance will auto-stop ${var.auto_stop_hours} hour(s) after first boot. " +
    "Restart with: aws ec2 start-instances --instance-ids ${aws_instance.web.id} --region ${var.aws_region}"
  ) : "Auto-stop is disabled."
}

output "check_user_data_log" {
  description = "SSH command to watch the bootstrap log in real time"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.web_eip.public_ip} 'sudo tail -f /var/log/user-data.log'"
}
