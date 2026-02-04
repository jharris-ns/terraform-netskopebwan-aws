#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

output "gateways" {
  description = "Deployed gateway instances and their GRE configuration status"
  value = {
    for gw_key, gw in local.gateways : gw_key => {
      instance_id    = module.aws_ec2.instance_ids[gw_key]
      gre_configured = try(module.gre_config.gre_config_ids[gw_key] != null, false)
    }
  }
}

output "gre-config-ssm-document" {
  description = "SSM document name used for GRE tunnel configuration"
  value       = module.gre_config.ssm_document_name
}

output "computed-gateway-map" {
  description = "Auto-computed gateway configuration from gateway_count and az_count"
  value       = local.gateways
}

output "client-details" {
  value = var.clients.create_clients ? "Client deployed at ${try(module.clients[0].client_instance.ip, "unknown")}" : null
}
