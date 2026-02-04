#------------------------------------------------------------------------------
#  NSG Config Module - Variable Declarations
#------------------------------------------------------------------------------

variable "gateways" {
  description = "Map of gateway instances to deploy"
  type        = any
}

variable "gateway_data" {
  description = "Per-gateway VPC data (interfaces, IPs) from aws_vpc module"
  type        = any
}

variable "clients" {
  description = "Client deployment configuration"
  type        = any
}

variable "netskope_tenant" {
  description = "Netskope tenant details"
  type        = any
}

variable "netskope_gateway_config" {
  description = "Netskope gateway configuration (shared)"
  type        = any
}

variable "aws_transit_gw" {
  description = "AWS Transit Gateway configuration"
  type        = any
}
