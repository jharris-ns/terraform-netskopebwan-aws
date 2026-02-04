#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------
#######################
## AWS VPC Variables ##
#######################

variable "aws_network_config" {
  description = "AWS VPC configuration (shared across all gateways)"
  type = object({
    region     = optional(string, "us-east-1")
    create_vpc = optional(bool, true)
    vpc_id     = optional(string, "")
    vpc_cidr   = optional(string, "")
    route_table = optional(object({
      public  = optional(string, "")
      private = optional(string, "")
    }), { public = "", private = "" })
  })
}

##############################
## Gateway Count Variables ##
##############################

variable "gateway_count" {
  description = "Number of Netskope BWAN gateways to deploy (max 4 per TGW Connect attachment)"
  type        = number
  default     = 2

  validation {
    condition     = var.gateway_count >= 1 && var.gateway_count <= 4
    error_message = "gateway_count must be between 1 and 4 (AWS limit: 4 Connect Peers per Connect attachment)."
  }
}

variable "az_count" {
  description = "Number of availability zones to distribute gateways across"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1
    error_message = "az_count must be at least 1."
  }
}

variable "gateway_prefix" {
  description = "Naming prefix for auto-generated gateway identifiers"
  type        = string
  default     = "aws-gw"
}

variable "gateway_role" {
  description = "Role assigned to all gateways"
  type        = string
  default     = "hub"
}

variable "inside_cidr_base" {
  description = "Base /24 link-local CIDR from which /29 blocks are carved per gateway (e.g. 169.254.100.0/24)"
  type        = string
  default     = "169.254.100.0/24"
}

variable "subnet_size" {
  description = "Subnet prefix length for auto-generated gateway subnets"
  type        = number
  default     = 28
}

##################################
## Profile and Region Variables ##
##################################

variable "aws_instance" {
  description = "AWS Instance Config"
  type = object({
    keypair       = optional(string, "")
    instance_type = optional(string, "t3.medium")
    ami_name      = optional(string, "BWAN-SASE-RTM-CLOUD-")
    ami_owner     = optional(string, "679593333241")
  })
  default = {
    keypair = ""
  }
}

###########################
## Netskope GW Variables ##
###########################

variable "netskope_tenant" {
  description = "Netskope Tenant Details"
  type = object({
    tenant_id      = string
    tenant_url     = string
    tenant_token   = string
    tenant_bgp_asn = optional(string, "400")
  })
}

variable "netskope_gateway_config" {
  description = "Netskope Gateway Details (shared across all gateways)"
  type = object({
    gateway_password = optional(string, "infiot")
    gateway_policy   = optional(string, "test")
    gateway_model    = optional(string, "iXVirtual")
    dns_primary      = optional(string, "8.8.8.8")
    dns_secondary    = optional(string, "8.8.4.4")
  })
  default = {}
}

##############################
## Transit Gateway Variable ##
##############################

variable "aws_transit_gw" {
  description = "AWS Transit Gateway configuration for GRE/BGP connectivity"
  type = object({
    create_transit_gw = optional(bool, true)
    tgw_id            = optional(string, null)
    tgw_asn           = optional(string, "64512")
    tgw_cidr          = optional(string, "")
    vpc_attachment     = optional(string, "")
    phy_intfname       = optional(string, "enp2s1")
  })
}

###############################
## Optional Client Variables ##
###############################

variable "clients" {
  description = "Optional Client / Host VPC configuration"
  type = object({
    create_clients = optional(bool, false)
    client_ami     = optional(string, "ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server")
    vpc_cidr       = optional(string, "192.168.255.0/28")
    instance_type  = optional(string, "t3.small")
    password       = optional(string, "infiot")
    ports          = optional(list(string), ["22"])
  })
  default = {
    create_clients = false
  }
}
