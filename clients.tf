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
  count      = var.clients.create_clients ? 1 : 0
  cidr_block = var.clients.vpc_cidr
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
    Name = join("-", ["Client-SG", var.netskope_tenant.deployment_name])
  }
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
  owners      = ["aws-marketplace"]

  filter {
    name   = "name"
    values = [join("", [var.clients.client_ami, "*"])]
  }
}

resource "aws_instance" "client_instance" {
  count             = var.clients.create_clients ? 1 : 0
  ami               = data.aws_ami.client_image[0].id
  instance_type     = var.clients.instance_type
  availability_zone = data.aws_availability_zones.client_az[0].names[0]
  key_name          = var.aws_instance.keypair
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
