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

##########################
## Deployment Variables ##
##########################

variable "environment" {
  description = "Environment prefix for resource naming (e.g. prod, staging, dev)"
  type        = string
  default     = "netskope"
}

variable "tags" {
  description = "Common tags applied to all AWS resources via provider default_tags"
  type        = map(string)
  default = {
    ManagedBy = "terraform"
  }
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
  description = <<-EOT
    Base link-local CIDR from which /29 blocks are carved per gateway for GRE tunnel inside addressing.
    AWS TGW Connect Peer constraints:
      - Must be from the 169.254.0.0/16 link-local range
      - Each gateway's /29 block must not overlap with other Connect Peers
      - Avoid 169.254.169.0/24 (EC2 metadata) and 169.254.170.0/24 (reserved by AWS)
      - Must be a /29 per peer (the module handles the subdivision automatically)
  EOT
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
    deployment_name = string # Free-form identifier used in resource naming (e.g. "my-corp-prod")
    tenant_url      = optional(string, "")
    tenant_token    = optional(string, "")
    tenant_bgp_asn  = optional(string, "400")
  })
}

variable "netskope_api_url" {
  description = "Netskope tenant URL. Set via TF_VAR_netskope_api_url env var."
  type        = string
  default     = ""
}

variable "netskope_api_token" {
  description = "Netskope API token. Set via TF_VAR_netskope_api_token env var."
  type        = string
  sensitive   = true
  default     = ""
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
  description = <<-EOT
    AWS Transit Gateway configuration for GRE/BGP connectivity.
    ASN constraints:
      - tgw_asn must be a 16-bit (1–65534) or 32-bit (131072–4199999999) private ASN
      - AWS reserves 7224 and 9059; these cannot be used
      - Must not conflict with tenant_bgp_asn (the gateway-side ASN)
    CIDR constraints:
      - tgw_cidr is assigned to the TGW itself and used for Connect Peer addressing
      - Must be a /24 or shorter prefix from RFC 1918 or 100.64.0.0/10 (CG-NAT) space
      - Must not overlap with any VPC CIDR attached to the TGW
  EOT
  type = object({
    create_transit_gw = optional(bool, true)
    tgw_id            = optional(string, null)
    tgw_asn           = optional(string, "64512") # Must not conflict with tenant_bgp_asn
    tgw_cidr          = optional(string, "")      # Must not overlap with attached VPC CIDRs
    vpc_attachment    = optional(string, "")
    phy_intfname      = optional(string, "enp2s1")
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
