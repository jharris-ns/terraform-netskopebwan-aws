#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

# ─── VPC ───────────────────────────────────────────────────────────────────────

data "aws_vpc" "existing" {
  count = var.aws_network_config.create_vpc == false ? 1 : 0
  id    = var.aws_network_config.vpc_id
}

resource "aws_vpc" "this" {
  count                = var.aws_network_config.create_vpc ? 1 : 0
  cidr_block           = var.aws_network_config.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = join("-", ["VPC", var.netskope_tenant.tenant_id])
  }
}

locals {
  vpc_id = var.aws_network_config.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
}

# ─── Internet Gateway ─────────────────────────────────────────────────────────

data "aws_internet_gateway" "existing" {
  count = var.aws_network_config.create_vpc == false ? 1 : 0
  filter {
    name   = "attachment.vpc-id"
    values = [local.vpc_id]
  }
}

resource "aws_internet_gateway" "this" {
  count  = var.aws_network_config.create_vpc ? 1 : 0
  vpc_id = local.vpc_id
  tags = {
    Name = join("-", ["IGW", var.netskope_tenant.tenant_id])
  }
}

locals {
  igw_id = var.aws_network_config.create_vpc ? aws_internet_gateway.this[0].id : data.aws_internet_gateway.existing[0].id
}

# ─── Subnets (per gateway × interface) ────────────────────────────────────────

resource "aws_subnet" "gw_subnets" {
  for_each          = local.gateway_subnets
  vpc_id            = local.vpc_id
  cidr_block        = each.value.subnet.subnet_cidr
  availability_zone = each.value.az

  tags = {
    Name        = join("-", [each.value.gw_key, upper(each.value.intf_key), var.netskope_tenant.tenant_id])
    Environment = join("-", [each.value.gw_key, each.value.intf_key, var.netskope_tenant.tenant_id])
  }
}

# ─── Route Tables ─────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
  count  = (var.aws_network_config.create_vpc || var.aws_network_config.route_table.public == "") ? 1 : 0
  vpc_id = local.vpc_id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = local.igw_id
  }

  tags = {
    Name = join("-", ["Public-RT", var.netskope_tenant.tenant_id])
  }
}

resource "aws_route_table" "private" {
  count  = (var.aws_network_config.create_vpc || var.aws_network_config.route_table.private == "") ? 1 : 0
  vpc_id = local.vpc_id

  tags = {
    Name = join("-", ["Private-RT", var.netskope_tenant.tenant_id])
  }
}

locals {
  public_rt_id  = var.aws_network_config.route_table.public != "" ? var.aws_network_config.route_table.public : try(aws_route_table.public[0].id, "")
  private_rt_id = var.aws_network_config.route_table.private != "" ? var.aws_network_config.route_table.private : try(aws_route_table.private[0].id, "")
}

# Public RT associations (WAN/overlay interfaces)
resource "aws_route_table_association" "public" {
  for_each       = local.gw_public_interfaces
  subnet_id      = aws_subnet.gw_subnets[each.key].id
  route_table_id = local.public_rt_id
}

# Private RT associations (LAN interfaces)
resource "aws_route_table_association" "private" {
  for_each       = local.gw_lan_interfaces
  subnet_id      = aws_subnet.gw_subnets[each.key].id
  route_table_id = local.private_rt_id
}

# ─── Security Groups ──────────────────────────────────────────────────────────

resource "aws_security_group" "public" {
  name   = join("-", ["Public-SG", var.netskope_tenant.tenant_id])
  vpc_id = local.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "IPSec"
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = join("-", ["Public-SG", var.netskope_tenant.tenant_id])
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "clients" {
  for_each          = var.clients.create_clients ? toset(var.clients.ports) : toset([])
  type              = "ingress"
  from_port         = sum([2000, tonumber(each.key)])
  to_port           = sum([2000, tonumber(each.key)])
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.public.id
}

resource "aws_security_group" "private" {
  name        = join("-", ["Private-SG", var.netskope_tenant.tenant_id])
  description = join("-", ["Private-SG", var.netskope_tenant.tenant_id])
  vpc_id      = local.vpc_id

  ingress {
    description = "All"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = join("-", ["Private-SG", var.netskope_tenant.tenant_id])
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Transit Gateway ──────────────────────────────────────────────────────────

data "aws_ec2_transit_gateway" "existing" {
  count = var.aws_transit_gw.create_transit_gw == false && var.aws_transit_gw.tgw_id != null ? 1 : 0
  id    = var.aws_transit_gw.tgw_id
}

resource "aws_ec2_transit_gateway" "this" {
  count                           = var.aws_transit_gw.create_transit_gw ? 1 : 0
  description                     = join("-", ["TGW", var.netskope_tenant.tenant_id])
  amazon_side_asn                 = var.aws_transit_gw.tgw_asn
  dns_support                     = "enable"
  multicast_support               = "disable"
  vpn_ecmp_support                = "enable"
  transit_gateway_cidr_blocks     = [var.aws_transit_gw.tgw_cidr]
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  auto_accept_shared_attachments  = "enable"

  tags = {
    Name = join("-", ["TGW", var.netskope_tenant.tenant_id])
  }

  depends_on = [time_sleep.api_delay]
}

locals {
  tgw = var.aws_transit_gw.create_transit_gw ? aws_ec2_transit_gateway.this[0] : data.aws_ec2_transit_gateway.existing[0]
}

# ─── TGW VPC Attachment ───────────────────────────────────────────────────────

data "aws_ec2_transit_gateway_vpc_attachment" "existing" {
  count = (var.aws_network_config.create_vpc == false && var.aws_transit_gw.vpc_attachment != "") ? 1 : 0
  filter {
    name   = "transit-gateway-id"
    values = [local.tgw.id]
  }
  filter {
    name   = "transit-gateway-attachment-id"
    values = [var.aws_transit_gw.vpc_attachment]
  }
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count              = (var.aws_network_config.create_vpc || var.aws_transit_gw.vpc_attachment == "") && local.has_lan_interfaces ? 1 : 0
  subnet_ids         = [for az, subnet_key in local.az_to_lan_subnet_key : aws_subnet.gw_subnets[subnet_key].id]
  transit_gateway_id = local.tgw.id
  vpc_id             = local.vpc_id

  tags = {
    Name = join("-", ["NSG-Attach", var.netskope_tenant.tenant_id])
  }
}

locals {
  tgw_attachment_id = (var.aws_network_config.create_vpc == false && var.aws_transit_gw.vpc_attachment != "") ? data.aws_ec2_transit_gateway_vpc_attachment.existing[0].id : try(aws_ec2_transit_gateway_vpc_attachment.this[0].id, "")
}

resource "aws_route" "tgw_route" {
  count                  = local.has_lan_interfaces ? 1 : 0
  route_table_id         = local.private_rt_id
  destination_cidr_block = tolist(local.tgw.transit_gateway_cidr_blocks)[0]
  transit_gateway_id     = local.tgw.id
}

resource "aws_ec2_transit_gateway_connect" "this" {
  count                   = local.has_lan_interfaces ? 1 : 0
  transport_attachment_id = local.tgw_attachment_id
  transit_gateway_id      = local.tgw.id

  tags = {
    Name = join("-", ["tgw_connect", var.netskope_tenant.tenant_id])
  }
  depends_on = [time_sleep.api_delay]
}

# ─── SSM VPC Endpoints ────────────────────────────────────────────────────────

resource "aws_security_group" "ssm_endpoint" {
  name        = join("-", ["SSM-Endpoint-SG", var.netskope_tenant.tenant_id])
  description = "Allow HTTPS for SSM VPC endpoints"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.aws_network_config.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = join("-", ["SSM-Endpoint-SG", var.netskope_tenant.tenant_id])
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Pick one public subnet per unique AZ for SSM endpoints
locals {
  ssm_endpoint_subnets = [
    for az in local.unique_azs : [
      for k, v in local.gw_public_interfaces : aws_subnet.gw_subnets[k].id if v.az == az
    ][0]
  ]
}

resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.aws_network_config.region}.ssm"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.ssm_endpoint_subnets
  security_group_ids  = [aws_security_group.ssm_endpoint.id]

  tags = {
    Name = join("-", ["SSM-Endpoint", var.netskope_tenant.tenant_id])
  }
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.aws_network_config.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.ssm_endpoint_subnets
  security_group_ids  = [aws_security_group.ssm_endpoint.id]

  tags = {
    Name = join("-", ["SSMMessages-Endpoint", var.netskope_tenant.tenant_id])
  }
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.aws_network_config.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = local.ssm_endpoint_subnets
  security_group_ids  = [aws_security_group.ssm_endpoint.id]

  tags = {
    Name = join("-", ["EC2Messages-Endpoint", var.netskope_tenant.tenant_id])
  }
}
