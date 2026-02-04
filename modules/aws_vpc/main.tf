#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

locals {
  # AZ is always set by the root locals.tf computed gateway map
  gateways_with_az = var.gateways

  # Flatten gateways × interfaces into a single map
  gateway_subnets = merge([
    for gw_key, gw in local.gateways_with_az : {
      for intf_key, intf in gw.subnets :
      "${gw_key}-${intf_key}" => {
        gw_key    = gw_key
        intf_key  = intf_key
        subnet    = intf
        az        = gw.availability_zone
      } if intf != null
    }
  ]...)

  # Enabled interfaces per gateway (non-null subnets)
  gw_enabled_interfaces = {
    for gw_key, gw in local.gateways_with_az : gw_key => {
      for intf_key, intf in gw.subnets : intf_key => intf if intf != null
    }
  }

  # Public overlay (WAN) interfaces per gateway-interface
  gw_public_interfaces = {
    for k, v in local.gateway_subnets : k => v
    if v.subnet.overlay == "public"
  }

  # LAN interfaces: those with overlay = null (not public, not private)
  gw_lan_interfaces = {
    for k, v in local.gateway_subnets : k => v
    if v.subnet.overlay == null
  }

  # Unique AZs across all gateways
  unique_azs = distinct([for gw in local.gateways_with_az : gw.availability_zone])

  # Deduplicate: pick one LAN subnet per AZ for TGW VPC attachment
  az_to_lan_subnet_key = {
    for az in local.unique_azs : az => [
      for k, v in local.gw_lan_interfaces : k if v.az == az
    ][0]
  }

  # LAN interface key per gateway (first LAN interface found)
  gw_lan_key = {
    for gw_key, gw in local.gateways_with_az : gw_key => [
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == null
    ][0] if length([
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == null
    ]) > 0
  }

  has_lan_interfaces = length(local.gw_lan_interfaces) > 0
}
