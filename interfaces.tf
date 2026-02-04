#------------------------------------------------------------------------------
#  ENIs and EIPs (per gateway x interface)
#------------------------------------------------------------------------------

# --- ENIs (per gateway x interface) ---

resource "aws_network_interface" "gw_interfaces" {
  for_each        = local.gateway_subnets
  subnet_id       = aws_subnet.gw_subnets[each.key].id
  security_groups = each.value.subnet.overlay == "public" ? [aws_security_group.public.id] : [aws_security_group.private.id]

  source_dest_check = each.value.subnet.overlay == "public" ? true : false

  tags = {
    Name = join("-", [each.value.gw_key, upper(each.value.intf_key), var.netskope_tenant.deployment_name])
  }
}

# --- EIPs (WAN/public overlay interfaces only) ---

resource "aws_eip" "gw_eips" {
  for_each                  = local.gw_public_interfaces
  vpc                       = true
  network_interface         = aws_network_interface.gw_interfaces[each.key].id
  associate_with_private_ip = tolist(aws_network_interface.gw_interfaces[each.key].private_ips)[0]

  tags = {
    Name = join("-", [each.value.gw_key, upper(each.value.intf_key), var.netskope_tenant.deployment_name])
  }
}
