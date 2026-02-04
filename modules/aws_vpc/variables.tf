#------------------------------------------------------------------------------
#  AWS VPC Module - Variable Declarations
#------------------------------------------------------------------------------

variable "aws_network_config" {
  description = "AWS VPC and network configuration"
  type        = any
}

variable "gateways" {
  description = "Map of gateway instances to deploy"
  type        = any
}

variable "clients" {
  description = "Client deployment configuration"
  type        = any
}

variable "aws_transit_gw" {
  description = "AWS Transit Gateway configuration"
  type        = any
}

variable "netskope_tenant" {
  description = "Netskope tenant details"
  type        = any
}
