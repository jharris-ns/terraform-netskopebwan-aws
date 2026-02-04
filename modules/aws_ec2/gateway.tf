#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

resource "aws_instance" "gateways" {
  for_each             = var.gateways
  ami                  = local.netskope_gw_image_id
  instance_type        = var.aws_instance.instance_type
  availability_zone    = var.gateway_data[each.key].availability_zone
  iam_instance_profile = var.iam_instance_profile != "" ? var.iam_instance_profile : null
  key_name             = var.aws_instance.keypair

  user_data = templatefile("${path.module}/scripts/user-data.sh", {
    netskope_gw_default_password = var.netskope_gateway_config.gateway_password
    netskope_tenant_url          = var.netskope_tenant.tenant_url
    netskope_gw_activation_key   = var.gateway_tokens[each.key].token
    aws_region                   = var.aws_network_config.region
  })

  dynamic "network_interface" {
    for_each = {
      for idx, intf_key in sort(keys(var.gateway_data[each.key].interfaces)) :
      idx => var.gateway_data[each.key].interfaces[intf_key]
    }
    content {
      network_interface_id = network_interface.value.id
      device_index         = network_interface.key
    }
  }

  tags = {
    Name = join("-", [each.key, var.netskope_tenant.tenant_id])
  }
}
