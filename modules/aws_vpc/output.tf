#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

output "vpc_id" {
  value = local.vpc_id
}

output "tgw" {
  value = {
    id   = local.tgw.id
    asn  = local.tgw.amazon_side_asn
    cidr = tolist(local.tgw.transit_gateway_cidr_blocks)[0]
  }
}

# Per-gateway output: interfaces, LAN IP, TGW peer IP, AZ
output "gateway_data" {
  value = {
    for gw_key, gw in local.gateways_with_az : gw_key => {
      availability_zone = gw.availability_zone
      interfaces = {
        for intf_key, intf in gw.subnets :
        intf_key => {
          id          = aws_network_interface.gw_interfaces["${gw_key}-${intf_key}"].id
          private_ips = aws_network_interface.gw_interfaces["${gw_key}-${intf_key}"].private_ips
        } if intf != null
      }
      lan_ip = try(
        tolist(aws_network_interface.gw_interfaces["${gw_key}-${local.gw_lan_key[gw_key]}"].private_ips)[0],
        ""
      )
      tgw_ip = try(
        aws_ec2_transit_gateway_connect_peer.gw_peers[gw_key].transit_gateway_address,
        ""
      )
      elastic_ips = {
        for intf_key in keys(local.gw_enabled_interfaces[gw_key]) :
        intf_key => try(aws_eip.gw_eips["${gw_key}-${intf_key}"], null)
        if contains(keys(local.gw_public_interfaces), "${gw_key}-${intf_key}")
      }
    }
  }
}
