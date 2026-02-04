#------------------------------------------------------------------------------
#  Copyright (c) 2022 Netskope Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

# One TGW Connect Peer per gateway (that has a LAN interface)
resource "aws_ec2_transit_gateway_connect_peer" "gw_peers" {
  for_each = local.gw_lan_key

  peer_address                  = tolist(aws_network_interface.gw_interfaces["${each.key}-${each.value}"].private_ips)[0]
  bgp_asn                       = var.netskope_tenant.tenant_bgp_asn
  inside_cidr_blocks            = [var.gateways[each.key].inside_cidr]
  transit_gateway_attachment_id = aws_ec2_transit_gateway_connect.this[0].id

  tags = {
    Name = join("-", ["BGP", each.key, var.netskope_tenant.tenant_id])
  }
  depends_on = [time_sleep.api_delay]
}
