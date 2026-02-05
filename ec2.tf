#------------------------------------------------------------------------------
#  EC2 Instances and AMI for Netskope BWAN Gateways
#------------------------------------------------------------------------------

# --- AMI ---

data "aws_ami" "netskope_gw_image_id" {
  most_recent = true
  owners      = [var.aws_instance.ami_owner]

  filter {
    name   = "name"
    values = [join("", [var.aws_instance.ami_name, "*"])]
  }
}

locals {
  netskope_gw_image_id = data.aws_ami.netskope_gw_image_id.image_id
}

# --- Gateway EC2 Instances ---

resource "aws_instance" "gateways" {
  for_each             = local.gateways
  ami                  = local.netskope_gw_image_id
  instance_type        = var.aws_instance.instance_type
  availability_zone    = local.gateways[each.key].availability_zone
  iam_instance_profile = aws_iam_instance_profile.gateway_ssm_profile.name
  key_name             = var.aws_instance.keypair

  user_data = templatefile("${path.module}/scripts/user-data.sh", {
    netskope_gw_default_password = var.netskope_gateway_config.gateway_password
    netskope_tenant_url          = local.tenant_url
    netskope_gw_activation_key   = netskopebwan_gateway_activate.gateways[each.key].token
    aws_region                   = var.aws_network_config.region
  })

  dynamic "network_interface" {
    for_each = {
      for idx, intf_key in sort(keys(local.gw_enabled_interfaces[each.key])) :
      idx => {
        id = aws_network_interface.gw_interfaces["${each.key}-${intf_key}"].id
      }
    }
    content {
      network_interface_id = network_interface.value.id
      device_index         = network_interface.key
    }
  }

  tags = {
    Name = join("-", [each.key, var.netskope_tenant.deployment_name])
  }
}
