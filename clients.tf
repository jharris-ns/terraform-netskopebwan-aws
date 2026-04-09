#------------------------------------------------------------------------------
#  Optional Client VPC + EC2 for testing
#------------------------------------------------------------------------------

# --- API propagation delay ---

resource "time_sleep" "client_api_delay" {
  count           = var.clients.create_clients ? 1 : 0
  create_duration = "30s"
}

# --- Client AZ data source ---

data "aws_availability_zones" "client_az" {
  count = var.clients.create_clients ? 1 : 0
  state = "available"
  filter {
    name   = "region-name"
    values = [var.aws_network_config.region]
  }
}

# --- Client VPC ---

resource "aws_vpc" "client_vpc" {
  count                = var.clients.create_clients ? 1 : 0
  cidr_block           = var.clients.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = join("-", ["Client-VPC", var.netskope_tenant.deployment_name])
  }
}

resource "aws_subnet" "client_subnet" {
  count             = var.clients.create_clients ? 1 : 0
  vpc_id            = aws_vpc.client_vpc[0].id
  cidr_block        = var.clients.vpc_cidr
  availability_zone = data.aws_availability_zones.client_az[0].names[0]

  tags = {
    Environment = join("-", ["Client-Subnet", var.netskope_tenant.deployment_name])
  }
}

resource "aws_route_table" "client_route_table" {
  count  = var.clients.create_clients ? 1 : 0
  vpc_id = aws_vpc.client_vpc[0].id

  tags = {
    Name = join("-", ["Client-RT", var.netskope_tenant.deployment_name])
  }
}

resource "aws_route_table_association" "client_rt" {
  count          = var.clients.create_clients ? 1 : 0
  subnet_id      = aws_subnet.client_subnet[0].id
  route_table_id = aws_route_table.client_route_table[0].id
}

resource "aws_security_group" "client_security_group" {
  count  = var.clients.create_clients ? 1 : 0
  name   = join("-", ["Client-SG", var.netskope_tenant.deployment_name])
  vpc_id = aws_vpc.client_vpc[0].id

  tags = {
    Name = join("-", ["Client-SG", var.netskope_tenant.deployment_name])
  }
}

resource "aws_vpc_security_group_ingress_rule" "client_all" {
  count             = var.clients.create_clients ? 1 : 0
  security_group_id = aws_security_group.client_security_group[0].id
  description       = "All"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "client_all" {
  count             = var.clients.create_clients ? 1 : 0
  security_group_id = aws_security_group.client_security_group[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ec2_transit_gateway_vpc_attachment" "client_tgw_attach" {
  count              = var.clients.create_clients ? 1 : 0
  subnet_ids         = [aws_subnet.client_subnet[0].id]
  transit_gateway_id = local.tgw.id
  vpc_id             = aws_vpc.client_vpc[0].id

  tags = {
    Name = join("-", ["Client-Attach", var.netskope_tenant.deployment_name])
  }
}

resource "aws_route" "netskope_sdwan_gw_tgw_route_entry" {
  count                  = var.clients.create_clients ? 1 : 0
  route_table_id         = aws_route_table.client_route_table[0].id
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = local.tgw.id
  depends_on = [
    aws_ec2_transit_gateway_vpc_attachment.client_tgw_attach
  ]
}

# --- Client EC2 ---

resource "aws_network_interface" "client_interface" {
  count           = var.clients.create_clients ? 1 : 0
  subnet_id       = aws_subnet.client_subnet[0].id
  security_groups = [aws_security_group.client_security_group[0].id]
  tags = {
    Name = join("-", ["Client-Eth0", var.netskope_tenant.deployment_name])
  }
}

data "aws_ami" "client_image" {
  count       = var.clients.create_clients ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

resource "aws_instance" "client_instance" {
  count                = var.clients.create_clients ? 1 : 0
  ami                  = data.aws_ami.client_image[0].id
  instance_type        = var.clients.instance_type
  availability_zone    = data.aws_availability_zones.client_az[0].names[0]
  key_name             = var.aws_instance.keypair
  iam_instance_profile = aws_iam_instance_profile.gateway_ssm_profile.name
  user_data = templatefile("${path.module}/scripts/client-user-data.sh",
    {
      password = var.clients.password
    }
  )

  network_interface {
    network_interface_id = aws_network_interface.client_interface[0].id
    device_index         = 0
  }

  tags = {
    Name = join("-", ["Client", var.netskope_tenant.deployment_name])
  }
}

# --- Client SSM VPC Endpoints ---

resource "aws_security_group" "client_ssm_endpoint" {
  count       = var.clients.create_clients ? 1 : 0
  name        = join("-", ["Client-SSM-Endpoint-SG", var.netskope_tenant.deployment_name])
  description = "Allow HTTPS for SSM VPC endpoints in client VPC"
  vpc_id      = aws_vpc.client_vpc[0].id

  tags = {
    Name = join("-", ["Client-SSM-Endpoint-SG", var.netskope_tenant.deployment_name])
  }
}

resource "aws_vpc_security_group_ingress_rule" "client_ssm_endpoint_https" {
  count             = var.clients.create_clients ? 1 : 0
  security_group_id = aws_security_group.client_ssm_endpoint[0].id
  description       = "HTTPS from client VPC"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.clients.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "client_ssm_endpoint_all" {
  count             = var.clients.create_clients ? 1 : 0
  security_group_id = aws_security_group.client_ssm_endpoint[0].id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_endpoint" "client_ssm" {
  count               = var.clients.create_clients ? 1 : 0
  vpc_id              = aws_vpc.client_vpc[0].id
  service_name        = "com.amazonaws.${var.aws_network_config.region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.client_subnet[0].id]
  security_group_ids  = [aws_security_group.client_ssm_endpoint[0].id]
  private_dns_enabled = true

  tags = {
    Name = join("-", ["Client-SSM", var.netskope_tenant.deployment_name])
  }
}

resource "aws_vpc_endpoint" "client_ssmmessages" {
  count               = var.clients.create_clients ? 1 : 0
  vpc_id              = aws_vpc.client_vpc[0].id
  service_name        = "com.amazonaws.${var.aws_network_config.region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.client_subnet[0].id]
  security_group_ids  = [aws_security_group.client_ssm_endpoint[0].id]
  private_dns_enabled = true

  tags = {
    Name = join("-", ["Client-SSMMessages", var.netskope_tenant.deployment_name])
  }
}

resource "aws_vpc_endpoint" "client_ec2messages" {
  count               = var.clients.create_clients ? 1 : 0
  vpc_id              = aws_vpc.client_vpc[0].id
  service_name        = "com.amazonaws.${var.aws_network_config.region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.client_subnet[0].id]
  security_group_ids  = [aws_security_group.client_ssm_endpoint[0].id]
  private_dns_enabled = true

  tags = {
    Name = join("-", ["Client-EC2Messages", var.netskope_tenant.deployment_name])
  }
}
