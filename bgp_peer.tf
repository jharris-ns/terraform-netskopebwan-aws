#------------------------------------------------------------------------------
#  TGW Connect Peers (one per gateway with a LAN interface)
#------------------------------------------------------------------------------

resource "aws_ec2_transit_gateway_connect_peer" "gw_peers" {
  for_each = local.gw_lan_key

  peer_address                  = tolist(aws_network_interface.gw_interfaces["${each.key}-${each.value}"].private_ips)[0]
  bgp_asn                       = var.netskope_tenant.tenant_bgp_asn
  inside_cidr_blocks            = [local.gateways[each.key].inside_cidr]
  transit_gateway_attachment_id = aws_ec2_transit_gateway_connect.this[0].id

  tags = {
    Name = join("-", ["BGP", each.key, var.netskope_tenant.deployment_name])
  }
  depends_on = [time_sleep.vpc_api_delay]
}
