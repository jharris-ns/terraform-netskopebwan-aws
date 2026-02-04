#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

output "gateways" {
  description = "Deployed gateway instances and their GRE configuration status"
  value = {
    for gw_key, gw in local.gateways : gw_key => {
      instance_id    = aws_instance.gateways[gw_key].id
      gre_configured = try(null_resource.gre_config[gw_key].id != null, false)
    }
  }
}

output "gre-config-ssm-document" {
  description = "SSM document name used for GRE tunnel configuration"
  value       = aws_ssm_document.gre_config.name
}

output "computed-gateway-map" {
  description = "Auto-computed gateway configuration from gateway_count and az_count"
  value       = local.gateways
}

output "client-details" {
  value = var.clients.create_clients ? "Client deployed at ${try(aws_instance.client_instance[0].private_ip, "unknown")}" : null
}
