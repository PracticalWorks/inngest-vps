terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  key_pair_name  = "${var.instance_name}-key"
}

resource "aws_lightsail_key_pair" "inngest" {
  name       = local.key_pair_name
  public_key = local.ssh_public_key
}

resource "aws_lightsail_static_ip" "inngest" {
  name = "${var.instance_name}-ip"
}

resource "aws_lightsail_instance" "inngest" {
  name              = var.instance_name
  availability_zone = var.availability_zone
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.inngest.name

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {})

  tags = var.tags
}

resource "aws_lightsail_static_ip_attachment" "inngest" {
  static_ip_name = aws_lightsail_static_ip.inngest.name
  instance_name  = aws_lightsail_instance.inngest.name
}

resource "aws_lightsail_instance_public_ports" "inngest" {
  instance_name = aws_lightsail_instance.inngest.name

  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
    cidrs     = var.admin_cidr
  }

  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
    cidrs     = ["0.0.0.0/0"]
  }

  port_info {
    protocol  = "tcp"
    from_port = 443
    to_port   = 443
    cidrs     = ["0.0.0.0/0"]
  }
}
