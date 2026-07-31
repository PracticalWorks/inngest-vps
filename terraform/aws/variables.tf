variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "Lightsail region"
}

variable "availability_zone" {
  type        = string
  default     = "us-east-1a"
  description = "Lightsail AZ (must match region, e.g. us-east-1a)"
}

variable "instance_name" {
  type        = string
  default     = "inngest"
  description = "Lightsail instance name (unique per region)"
}

variable "bundle_id" {
  type        = string
  default     = "small_2_0"
  description = "small_2_0 = 2 GB RAM / 2 vCPU / $12 mo"
}

variable "blueprint_id" {
  type        = string
  default     = "ubuntu_24_04"
}

variable "ssh_public_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
  description = "Local public key uploaded to Lightsail"
}

variable "admin_cidr" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "CIDRs allowed to SSH (port 22). Tighten to your IP/32 in production."
}

variable "inngest_domain" {
  type        = string
  default     = "inngest.example.com"
}

variable "tags" {
  type        = map(string)
  default = {
    project = "inngest-vps"
    managed = "terraform"
  }
}
