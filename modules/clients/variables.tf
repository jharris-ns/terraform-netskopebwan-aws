#------------------------------------------------------------------------------
#  Clients Module - Variable Declarations
#------------------------------------------------------------------------------

variable "clients" {
  description = "Client deployment configuration"
  type        = any
}

variable "aws_instance" {
  description = "AWS instance configuration"
  type        = any
}

variable "netskope_tenant" {
  description = "Netskope tenant details"
  type        = any
}

variable "aws_network_config" {
  description = "AWS VPC and network configuration"
  type        = any
}

variable "aws_transit_gw" {
  description = "AWS Transit Gateway configuration"
  type        = any
}

variable "netskope_gateway_config" {
  description = "Netskope gateway configuration (legacy, used for port forwarding)"
  type        = any
  default     = {}
}
