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
  for_each = local.gw_public_interfaces
  vpc = true

  tags = {
    Name = join("-", [each.value.gw_key, upper(each.value.intf_key), var.netskope_tenant.deployment_name])
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- EIP-to-ENI associations (recreated when gateway/ENI changes, EIP stays) ---

resource "aws_eip_association" "gw_eip_assoc" {
  for_each             = local.gw_public_interfaces
  allocation_id        = aws_eip.gw_eips[each.key].id
  network_interface_id = aws_network_interface.gw_interfaces[each.key].id
  private_ip_address   = tolist(aws_network_interface.gw_interfaces[each.key].private_ips)[0]
}
