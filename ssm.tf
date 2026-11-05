#------------------------------------------------------------------------------
#  SSM SecureString parameters for gateway and client credentials
#  Keeps cleartext credentials out of EC2 user-data (CrowdStrike Cloud Risk fix)
#------------------------------------------------------------------------------

data "aws_kms_key" "ssm" {
  key_id = "alias/aws/ssm"
}

locals {
  ssm_prefix = "/${var.netskope_gateway_config.gateway_policy}/netskope-bwan"
}

resource "aws_ssm_parameter" "gateway_password" {
  name        = "${local.ssm_prefix}/gateway-password"
  description = "Netskope BWAN gateway console password"
  type        = "SecureString"
  value       = var.netskope_gateway_config.gateway_password

  tags = {
    Name = "${var.netskope_gateway_config.gateway_policy}-gateway-password"
  }
}

resource "aws_ssm_parameter" "gateway_activation_key" {
  for_each    = local.gateways
  name        = "${local.ssm_prefix}/${each.key}/activation-key"
  description = "One-time Netskope BWAN activation token for gateway ${each.key}"
  type        = "SecureString"
  value       = netskopebwan_gateway_activate.gateways[each.key].token

  tags = {
    Name = "${each.key}-activation-key"
  }
}

resource "aws_ssm_parameter" "client_password" {
  count       = var.clients.create_clients ? 1 : 0
  name        = "/${var.netskope_tenant.deployment_name}/netskope-bwan/client-password"
  description = "Password for the BWAN test client instance"
  type        = "SecureString"
  value       = var.clients.password

  tags = {
    Name = "${var.netskope_tenant.deployment_name}-client-password"
  }
}
