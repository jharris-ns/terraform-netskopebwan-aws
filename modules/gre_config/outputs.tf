#------------------------------------------------------------------------------
#  GRE Config Module - Outputs
#------------------------------------------------------------------------------

output "ssm_document_name" {
  description = "Name of the SSM document for GRE configuration"
  value       = aws_ssm_document.gre_config.name
}

output "gre_config_ids" {
  description = "Map of gateway key to GRE config null_resource ID"
  value       = { for gw_key, res in null_resource.gre_config : gw_key => res.id }
}
