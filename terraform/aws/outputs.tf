output "static_ip" {
  value       = aws_lightsail_static_ip.inngest.ip_address
  description = "Create a DNS A record for var.inngest_domain pointing here (grey-cloud for auto TLS)"
}

output "instance_name" {
  value = aws_lightsail_instance.inngest.name
}

output "ssh_user" {
  value = "ubuntu"
}

output "ssh_host" {
  value = "ubuntu@${aws_lightsail_static_ip.inngest.ip_address}"
}

output "dns_record" {
  value = "${var.inngest_domain} A ${aws_lightsail_static_ip.inngest.ip_address}"
}

output "install_command" {
  value = "../scripts/install.sh ${aws_lightsail_static_ip.inngest.ip_address}"
}
