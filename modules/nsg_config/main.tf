#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

locals {
  # Flatten gateways × interfaces for interface configuration
  all_gateway_interfaces = merge([
    for gw_key, gw in var.gateways : {
      for intf_key, intf in gw.subnets :
      "${gw_key}-${intf_key}" => {
        gw_key   = gw_key
        intf_key = intf_key
        subnet   = intf
      } if intf != null
    }
  ]...)

  # Public overlay interfaces
  gw_public_interfaces = {
    for k, v in local.all_gateway_interfaces : k => v
    if v.subnet.overlay == "public"
  }

  # Private overlay interfaces
  gw_private_interfaces = {
    for k, v in local.all_gateway_interfaces : k => v
    if try(v.subnet.overlay, null) == "private"
  }

  # LAN (non-overlay) interfaces per gateway
  gw_lan_key = {
    for gw_key, gw in var.gateways : gw_key => [
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == null
    ][0] if length([
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == null
    ]) > 0
  }

  # First public overlay interface per gateway (for metadata static route)
  gw_public_key = {
    for gw_key, gw in var.gateways : gw_key => [
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == "public"
    ][0] if length([
      for intf_key, intf in gw.subnets : intf_key
      if intf != null && intf.overlay == "public"
    ]) > 0
  }

  # BGP peers from TGW inside CIDRs
  gw_bgp_peers = {
    for gw_key, gw in var.gateways : gw_key => {
      peer1 = cidrhost(gw.inside_cidr, 2)
      peer2 = cidrhost(gw.inside_cidr, 3)
    }
  }
}

# ─── Policy (shared across all gateways) ─────────────────────────────────────

resource "netskopebwan_policy" "multicloud" {
  name = var.netskope_gateway_config.gateway_policy
}

# ─── Gateway Resources (one per gateway) ─────────────────────────────────────

resource "netskopebwan_gateway" "gateways" {
  for_each = var.gateways
  name     = coalesce(each.value.gateway_name, each.key)
  model    = var.netskope_gateway_config.gateway_model
  role     = each.value.gateway_role
  assigned_policy {
    id   = resource.netskopebwan_policy.multicloud.id
    name = resource.netskopebwan_policy.multicloud.name
  }
}

resource "time_sleep" "gw_propagation" {
  for_each        = var.gateways
  create_duration = "30s"

  triggers = {
    gateway_id = netskopebwan_gateway.gateways[each.key].id
  }
}

# ─── Interface Configuration ─────────────────────────────────────────────────

resource "netskopebwan_gateway_interface" "gw_interfaces" {
  for_each   = local.all_gateway_interfaces
  gateway_id = time_sleep.gw_propagation[each.value.gw_key].triggers["gateway_id"]
  name       = upper(each.value.intf_key)
  type       = "ethernet"
  addresses {
    address            = tolist(var.gateway_data[each.value.gw_key].interfaces[each.value.intf_key].private_ips)[0]
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = var.netskope_gateway_config.dns_primary
    dns_secondary      = var.netskope_gateway_config.dns_secondary
    gateway            = cidrhost(var.gateways[each.value.gw_key].subnets[each.value.intf_key].subnet_cidr, 1)
    mask               = cidrnetmask(var.gateways[each.value.gw_key].subnets[each.value.intf_key].subnet_cidr)
  }
  dynamic "overlay_setting" {
    for_each = contains(keys(merge(local.gw_public_interfaces, local.gw_private_interfaces)), each.key) ? [1] : []
    content {
      is_backup           = false
      tx_bw_kbps          = 1000000
      rx_bw_kbps          = 1000000
      bw_measurement_mode = "manual"
      tag                 = contains(keys(local.gw_public_interfaces), each.key) ? "wired" : "private"
    }
  }
  enable_nat  = contains(keys(local.gw_public_interfaces), each.key)
  mode        = "routed"
  is_disabled = false
  zone        = contains(keys(local.gw_public_interfaces), each.key) ? "untrusted" : "trusted"
}

# ─── Static Route (metadata) ─────────────────────────────────────────────────

resource "netskopebwan_gateway_staticroute" "metadata" {
  for_each    = local.gw_public_key
  gateway_id  = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  advertise   = true
  destination = "169.254.169.254/32"
  device      = "GE1"
  install     = true
  nhop        = cidrhost(var.gateways[each.key].subnets[each.value].subnet_cidr, 1)
}

# ─── Gateway Activation ──────────────────────────────────────────────────────

resource "netskopebwan_gateway_activate" "gateways" {
  for_each           = var.gateways
  gateway_id         = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  timeout_in_seconds = 86400
}

# ─── BGP Peer Configuration ──────────────────────────────────────────────────

resource "netskopebwan_gateway_bgpconfig" "tgw_peer1" {
  for_each   = var.gateways
  gateway_id = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  name       = "tgw-peer-1-${each.key}"
  neighbor   = local.gw_bgp_peers[each.key].peer1
  remote_as  = var.aws_transit_gw.tgw_asn
}

resource "netskopebwan_gateway_bgpconfig" "tgw_peer2" {
  for_each   = var.gateways
  gateway_id = time_sleep.gw_propagation[each.key].triggers["gateway_id"]
  name       = "tgw-peer-2-${each.key}"
  neighbor   = local.gw_bgp_peers[each.key].peer2
  remote_as  = var.aws_transit_gw.tgw_asn
}
