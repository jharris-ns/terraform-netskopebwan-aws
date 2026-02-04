#------------------------------------------------------------------------------
#  GRE Config Module - Variables
#------------------------------------------------------------------------------

variable "gre_configs" {
  description = "Map of GRE tunnel configurations keyed by gateway"
  type = map(object({
    instance_id  = string
    inside_ip    = string
    inside_mask  = string
    local_ip     = string
    remote_ip    = string
    intf_name    = optional(string, "gre1")
    mtu          = optional(string, "1300")
    phy_intfname = optional(string, "enp2s1")
    bgp_peers    = object({ peer1 = string, peer2 = string })
    bgp_metric   = string
  }))
}

variable "bgp_asn" {
  description = "Netskope BGP ASN"
  type        = string
}

variable "tgw_asn" {
  description = "Transit Gateway BGP ASN (remote-as for BGP neighbors)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Environment name for resource naming"
  type        = string
}
