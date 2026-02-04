#------------------------------------------------------------------------------
#  AWS EC2 Module - Variable Declarations
#------------------------------------------------------------------------------

variable "gateways" {
  description = "Map of gateway instances to deploy"
  type        = any
}

variable "gateway_data" {
  description = "Per-gateway VPC data (interfaces, AZ) from aws_vpc module"
  type        = any
}

variable "gateway_tokens" {
  description = "Per-gateway activation tokens from nsg_config module"
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

variable "netskope_gateway_config" {
  description = "Netskope gateway configuration (shared)"
  type        = any
}

variable "aws_network_config" {
  description = "AWS VPC and network configuration"
  type        = any
}

variable "iam_instance_profile" {
  description = "IAM instance profile name for SSM access"
  type        = string
  default     = ""
}
