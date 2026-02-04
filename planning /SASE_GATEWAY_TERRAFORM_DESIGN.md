# SASE Gateway AWS Deployment — Terraform Design Document

## 1. Overview

This document specifies the Terraform requirements for deploying a Netskope BWAN SASE Gateway on AWS with GRE tunnels over Transit Gateway (TGW). It is intended to be used as the design specification for a **separate Terraform project/repository** that consumes the `netskopebwan` provider from this repo.

### Three Concerns

| Concern | Mechanism | Provider |
|---------|-----------|----------|
| AWS infrastructure | VPC, subnets, EC2, TGW, IAM, VPC endpoints | `hashicorp/aws` |
| Netskope gateway configuration | Gateway object, activation, interfaces, BGP | `netskopebwan` |
| GRE tunnel automation | `infhostd gre` commands executed on the gateway | `hashicorp/aws` (SSM) |

### Providers

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    netskopebwan = {
      source  = "netskopeoss/netskopebwan"
      version = "~> 0.1"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "netskopebwan" {
  baseurl  = var.netskope_api_url
  apitoken = var.netskope_api_token
}
```

SSM is used as the execution channel for GRE configuration commands on the gateway instance. No SSH access or bastion host is required.

---

## 2. Architecture Diagram

```
                         ┌──────────────────────────────────────────────────────┐
                         │                       AWS VPC                        │
                         │                   (10.0.0.0/24)                      │
                         │                                                      │
  Internet               │  ┌─────────────────────┐  ┌──────────────────────┐  │
     │                   │  │   Public Subnet      │  │   Private Subnet     │  │
     │                   │  │   10.0.0.0/26        │  │   10.0.0.64/26       │  │
     │    ┌─────┐        │  │                      │  │                      │  │
     └────│ IGW │────────│──│  ┌────────────────┐  │  │  ┌────────────────┐  │  │
          └─────┘        │  │  │  WAN ENI (GE1) │  │  │  │  LAN ENI (GE2) │  │  │
                         │  │  │  + EIP          │  │  │  │  src/dst off   │  │  │
                         │  │  │  src/dst off    │  │  │  └───────┬────────┘  │  │
                         │  │  └───────┬────────┘  │  │          │           │  │
                         │  │          │           │  │          │           │  │
                         │  │  ┌───────┴───────────┴──┴──────────┴────────┐  │  │
                         │  │  │         SASE Gateway EC2                 │  │  │
                         │  │  │         (c5.xlarge, SSM agent)           │  │  │
                         │  │  └──────────────────────────────────────────┘  │  │
                         │  │                      │  │                      │  │
                         │  │  SSM VPC Endpoints   │  │     GRE Tunnels     │  │
                         │  │  (ssm, ssmmessages,  │  │         │           │  │
                         │  │   ec2messages)        │  │         ▼           │  │
                         │  └─────────────────────┘  │  ┌──────────────┐   │  │
                         │                            │  │ TGW Attach   │   │  │
                         │                            │  └──────┬───────┘   │  │
                         │                            └─────────┼───────────┘  │
                         └──────────────────────────────────────┼──────────────┘
                                                                │
                                                     ┌──────────┴──────────┐
                                                     │  Transit Gateway    │
                                                     │  (64512 ASN)        │
                                                     └──────────┬──────────┘
                                                                │
                                                     ┌──────────┴──────────┐
                                                     │  Workload VPCs      │
                                                     │  (spoke attachments)│
                                                     └─────────────────────┘
```

### Data Flow

1. WAN (GE1) provides internet connectivity for Netskope overlay tunnels and management
2. LAN (GE2) connects to the private subnet where the TGW attachment lives
3. GRE tunnels are established from the gateway LAN interface (`enp2s1`) to the TGW endpoint IPs
4. BGP peers run over the GRE tunnels to exchange routes between the gateway and TGW
5. Workload VPC traffic reaches the gateway through TGW → GRE → gateway LAN

---

## 3. Provider Requirements

### AWS Provider

Provisions all infrastructure: VPC, subnets, security groups, ENIs, EC2, IAM, TGW, VPC endpoints, and SSM command execution.

**Authentication:** Standard AWS provider authentication (environment variables, shared credentials, IAM role, etc.)

### netskopebwan Provider

Configures the Netskope gateway object: creation, activation token generation, interface configuration, BGP peers, and static routes.

**Authentication:**

| Parameter | Description |
|-----------|-------------|
| `baseurl` | Netskope API base URL (e.g., `https://tenant.api.infiot.net`) |
| `apitoken` | Bearer token for Netskope API |

---

## 4. AWS Infrastructure Resources

All resources derived from the validated CloudFormation template (`planning/ssm-agent-test.yaml`) and Netskope deployment guide.

### 4.1 VPC and Networking

```hcl
resource "aws_vpc" "gateway" {
  cidr_block           = var.vpc_cidr          # e.g., "10.0.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.gateway.id
  cidr_block        = var.public_subnet_cidr   # e.g., "10.0.0.0/26"
  availability_zone = var.availability_zone
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.gateway.id
  cidr_block        = var.private_subnet_cidr  # e.g., "10.0.0.64/26"
  availability_zone = var.availability_zone
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.gateway.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.gateway.id
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.gateway.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}
```

### 4.2 Security Groups

**Public SG (WAN interface — GE1):**

```hcl
resource "aws_security_group" "public" {
  name        = "${var.name_prefix}-public-sg"
  description = "Public WAN SG"
  vpc_id      = aws_vpc.gateway.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "UDP 443"
  }

  ingress {
    from_port   = 4500
    to_port     = 4500
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "IPsec NAT-T"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }
}
```

**Private SG (LAN interface — GE2):**

```hcl
resource "aws_security_group" "private" {
  name        = "${var.name_prefix}-private-sg"
  description = "Private LAN SG"
  vpc_id      = aws_vpc.gateway.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all inbound"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }
}
```

**VPC Endpoint SG (SSM endpoints):**

```hcl
resource "aws_security_group" "endpoint" {
  name        = "${var.name_prefix}-endpoint-sg"
  description = "Allow HTTPS from VPC for SSM endpoints"
  vpc_id      = aws_vpc.gateway.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from VPC"
  }
}
```

### 4.3 Network Interfaces and EIP

```hcl
# WAN ENI (GE1) — primary interface, public subnet
resource "aws_network_interface" "wan" {
  subnet_id         = aws_subnet.public.id
  security_groups   = [aws_security_group.public.id]
  source_dest_check = false
  tags = { Name = "${var.name_prefix}-wan-eni" }
}

resource "aws_eip" "wan" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-eip" }
}

resource "aws_eip_association" "wan" {
  allocation_id        = aws_eip.wan.id
  network_interface_id = aws_network_interface.wan.id
}

# LAN ENI (GE2) — secondary interface, private subnet
resource "aws_network_interface" "lan" {
  subnet_id         = aws_subnet.private.id
  security_groups   = [aws_security_group.private.id]
  source_dest_check = false
  tags = { Name = "${var.name_prefix}-lan-eni" }
}
```

### 4.4 IAM Role and Instance Profile

```hcl
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.name_prefix}-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.gateway.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "gateway" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.gateway.name
}
```

### 4.5 SSM VPC Endpoints

Three interface endpoints are required for SSM connectivity without internet access from the private subnet:

```hcl
resource "aws_vpc_endpoint" "ssm" {
  vpc_id              = aws_vpc.gateway.id
  service_name        = "com.amazonaws.${var.aws_region}.ssm"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.public.id]
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ssmmessages" {
  vpc_id              = aws_vpc.gateway.id
  service_name        = "com.amazonaws.${var.aws_region}.ssmmessages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.public.id]
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "ec2messages" {
  vpc_id              = aws_vpc.gateway.id
  service_name        = "com.amazonaws.${var.aws_region}.ec2messages"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.public.id]
  security_group_ids  = [aws_security_group.endpoint.id]
  private_dns_enabled = true
}
```

### 4.6 AMI Lookup

```hcl
data "aws_ami" "sase_gateway" {
  most_recent = true
  owners      = ["679593333241"]

  filter {
    name   = "name"
    values = [
    ]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}
```

**AMI details:**
- Owner account: `679593333241`
- Name pattern: `BWAN-SASE-RTM-CLOUD-*`
- OS: Ubuntu 22.04 (uses `apt`/`dpkg`/`snap`, not `yum`/`rpm`)
- Confirmed AMI (eu-west-1): `ami-00778cd65ac4a8460`

### 4.7 EC2 Instance

```hcl
resource "aws_instance" "gateway" {
  ami           = data.aws_ami.sase_gateway.id
  instance_type = var.instance_type  # c5.xlarge or larger
  key_name      = var.key_pair_name

  # WAN ENI attached at launch as primary interface
  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.wan.id
  }

  iam_instance_profile = aws_iam_instance_profile.gateway.name

  root_block_device {
    volume_size = 38
    volume_type = "gp2"
  }

  # IMDSv2 enforced
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/templates/userdata.yaml", {
    gateway_password   = var.gateway_password
    activation_token   = netskopebwan_gateway_activate.token.token
    aws_region         = var.aws_region
  }))

  tags = { Name = "${var.name_prefix}-gateway" }
}
```

**User data template** (`templates/userdata.yaml`):

```yaml
#cloud-config
password: ${gateway_password}
runcmd:
  - curl -o /tmp/amazon-ssm-agent.deb https://s3.${aws_region}.amazonaws.com/amazon-ssm-${aws_region}/latest/debian_amd64/amazon-ssm-agent.deb
  - dpkg -i /tmp/amazon-ssm-agent.deb
  - systemctl enable amazon-ssm-agent
  - systemctl start amazon-ssm-agent
```

**Notes:**
- The `password` field in cloud-config sets the gateway's `infiot` user password (overrides default)
- The activation token can be injected via cloud-config or applied post-boot; the exact mechanism depends on the Netskope activation workflow
- SSM agent is not pre-installed on the SASE Gateway AMI; it must be installed at launch via user data

### 4.8 LAN ENI Attachment (Post-Launch)

The LAN ENI **must** be attached after the instance launches. This is a Netskope requirement — the WAN interface must be DeviceIndex 0 (primary) and the LAN interface must be DeviceIndex 1.

```hcl
resource "aws_network_interface_attachment" "lan" {
  instance_id          = aws_instance.gateway.id
  network_interface_id = aws_network_interface.lan.id
  device_index         = 1
}
```

---

## 5. Transit Gateway Resources

### 5.1 Transit Gateway

Either create a new TGW or reference an existing one:

```hcl
# Option A: Create new TGW
resource "aws_ec2_transit_gateway" "this" {
  count       = var.create_tgw ? 1 : 0
  description = "${var.name_prefix}-tgw"

  amazon_side_asn                 = var.tgw_asn  # e.g., 64512
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"

  tags = { Name = "${var.name_prefix}-tgw" }
}

# Option B: Reference existing TGW
data "aws_ec2_transit_gateway" "existing" {
  count = var.create_tgw ? 0 : 1
  id    = var.existing_tgw_id
}

locals {
  tgw_id = var.create_tgw ? aws_ec2_transit_gateway.this[0].id : data.aws_ec2_transit_gateway.existing[0].id
}
```

### 5.2 VPC Attachment

```hcl
resource "aws_ec2_transit_gateway_vpc_attachment" "gateway" {
  transit_gateway_id = local.tgw_id
  vpc_id             = aws_vpc.gateway.id
  subnet_ids         = [aws_subnet.private.id]

  tags = { Name = "${var.name_prefix}-tgw-attach" }
}
```

### 5.3 TGW Route Table

```hcl
resource "aws_ec2_transit_gateway_route_table" "gateway" {
  transit_gateway_id = local.tgw_id
  tags               = { Name = "${var.name_prefix}-tgw-rt" }
}

resource "aws_ec2_transit_gateway_route_table_association" "gateway" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.gateway.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.gateway.id
}
```

### 5.4 Private Subnet Route Updates

Route workload CIDRs through the TGW from the private subnet:

```hcl
resource "aws_route" "workload_via_tgw" {
  for_each = toset(var.workload_cidrs)

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = each.value
  transit_gateway_id     = local.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.gateway]
}
```

---

## 6. Netskope Provider Resources

### 6.1 Policy Lookup

```hcl
data "netskopebwan_policy" "this" {
  name = var.gateway_policy_name
}
```

### 6.2 Gateway Object

```hcl
resource "netskopebwan_gateway" "this" {
  name  = var.gateway_name
  model = "iXVirtual"
  role  = var.gateway_role  # e.g., "hub"

  assigned_policy {
    id   = data.netskopebwan_policy.this.id
    name = data.netskopebwan_policy.this.name
  }
}
```

**Resource attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `name` | Yes | Gateway display name |
| `model` | No | Gateway model — use `iXVirtual` for cloud deployments |
| `role` | No | Gateway role (e.g., `hub`, `spoke`) |
| `assigned_policy` | No | Block with `id` and `name` of the policy to assign |

### 6.3 Activation Token

```hcl
resource "netskopebwan_gateway_activate" "token" {
  gateway_id = netskopebwan_gateway.this.id
}
```

The `token` output attribute is passed to the EC2 user data for gateway activation at boot.

### 6.4 Interface Configuration — GE1 (WAN)

```hcl
resource "netskopebwan_gateway_interface" "ge1" {
  gateway_id  = netskopebwan_gateway.this.id
  name        = "GE1"
  type        = "ethernet"
  mode        = "routed"
  is_disabled = false
  zone        = "untrusted"
  mtu         = 1500
  enable_nat  = true

  addresses {
    address            = aws_network_interface.wan.private_ip
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = "8.8.8.8"
    dns_secondary      = "8.8.4.4"
    gateway            = cidrhost(var.public_subnet_cidr, 1)
    mask               = cidrnetmask(var.public_subnet_cidr)
  }
}
```

### 6.5 Interface Configuration — GE2 (LAN)

```hcl
resource "netskopebwan_gateway_interface" "ge2" {
  gateway_id   = netskopebwan_gateway.this.id
  name         = "GE2"
  type         = "ethernet"
  mode         = "routed"
  is_disabled  = false
  zone         = "trusted"
  mtu          = 1400
  do_advertise = true
  enable_nat   = false

  addresses {
    address            = aws_network_interface.lan.private_ip
    address_assignment = "static"
    address_family     = "ipv4"
    dns_primary        = "8.8.8.8"
    dns_secondary      = "8.8.4.4"
    gateway            = cidrhost(var.private_subnet_cidr, 1)
    mask               = cidrnetmask(var.private_subnet_cidr)
  }

  depends_on = [aws_network_interface_attachment.lan]
}
```

### 6.6 BGP Configuration

One BGP peer per GRE tunnel (typically two for redundancy):

```hcl
resource "netskopebwan_gateway_bgpconfig" "tgw_peer_1" {
  gateway_id = netskopebwan_gateway.this.id
  name       = "tgw-peer-1"
  neighbor   = var.gre_tunnel_1_tgw_inside_ip   # e.g., "169.254.10.1"
  remote_as  = var.tgw_asn                       # e.g., 64512
  local_as   = var.gateway_bgp_asn               # e.g., 400
}

resource "netskopebwan_gateway_bgpconfig" "tgw_peer_2" {
  gateway_id = netskopebwan_gateway.this.id
  name       = "tgw-peer-2"
  neighbor   = var.gre_tunnel_2_tgw_inside_ip   # e.g., "169.254.11.1"
  remote_as  = var.tgw_asn
  local_as   = var.gateway_bgp_asn
}
```

**Resource attributes:**

| Attribute | Required | Default | Description |
|-----------|----------|---------|-------------|
| `gateway_id` | Yes | — | Parent gateway ID |
| `name` | Yes | — | BGP peer name |
| `neighbor` | Yes | — | Neighbor BGP IP address (TGW inside tunnel IP) |
| `remote_as` | Yes | — | Remote AS number (TGW ASN) |
| `local_as` | No | 400 | Local AS number |

### 6.7 Static Routes (If Needed)

```hcl
resource "netskopebwan_gateway_staticroute" "workload" {
  gateway_id  = netskopebwan_gateway.this.id
  advertise   = true
  destination = "10.1.0.0/16"     # workload CIDR
  device      = "GE2"
  install     = true
  nhop        = cidrhost(var.private_subnet_cidr, 1)
}
```

Static routes are optional if BGP is handling route exchange. They may be useful for specific prefixes or as fallback routes.

---

## 7. GRE Tunnel Automation via SSM

### 7.1 Background

The SASE Gateway does not expose a Terraform-native resource for GRE tunnel configuration. GRE tunnels are configured via the `infhostd gre` CLI tool on the gateway OS. SSM provides a secure, agentless execution channel.

### 7.2 GRE Configuration Commands

The `infhostd gre add` command creates a GRE tunnel. Two tunnels are needed for TGW redundancy:

```bash
# Tunnel 1
infhostd gre add \
  --name gre-tgw-1 \
  --local_ip <LAN_ENI_PRIVATE_IP> \
  --remote_ip <TGW_ENDPOINT_IP_1> \
  --tunnel_ip <GATEWAY_INSIDE_IP_1>/30 \
  --phy_intfname enp2s1

# Tunnel 2
infhostd gre add \
  --name gre-tgw-2 \
  --local_ip <LAN_ENI_PRIVATE_IP> \
  --remote_ip <TGW_ENDPOINT_IP_2> \
  --tunnel_ip <GATEWAY_INSIDE_IP_2>/30 \
  --phy_intfname enp2s1
```

After adding tunnels, restart the container and service:

```bash
infhostd restart-container
service infhost restart
```

**Key details:**
- `phy_intfname` must be `enp2s1` (the physical interface name for the LAN ENI on this AMI)
- `local_ip` is the LAN ENI private IP address
- `remote_ip` is the TGW endpoint IP (from the TGW VPC attachment)
- `tunnel_ip` is the inside tunnel IP for the gateway side of the GRE tunnel (/30 recommended)
- GRE config persists across reboots and upgrades (stored in `/infroot/workdir/`)

### 7.3 Terraform Implementation — Primary Approach

Use `null_resource` with `local-exec` calling `aws ssm send-command`:

```hcl
resource "null_resource" "gre_tunnel_1" {
  triggers = {
    lan_ip        = aws_network_interface.lan.private_ip
    tgw_endpoint  = var.tgw_endpoint_ip_1
    tunnel_ip     = var.gre_tunnel_1_gateway_inside_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Wait for SSM agent to register
      aws ssm wait instance-information-available \
        --instance-information-filter-list key=InstanceIds,valueSet=${aws_instance.gateway.id} \
        --region ${var.aws_region}

      # Add GRE tunnel
      aws ssm send-command \
        --instance-ids ${aws_instance.gateway.id} \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["infhostd gre add --name gre-tgw-1 --local_ip ${aws_network_interface.lan.private_ip} --remote_ip ${var.tgw_endpoint_ip_1} --tunnel_ip ${var.gre_tunnel_1_gateway_inside_ip}/30 --phy_intfname enp2s1"]' \
        --region ${var.aws_region} \
        --output text \
        --query 'Command.CommandId'
    EOT
  }

  depends_on = [
    aws_instance.gateway,
    aws_network_interface_attachment.lan,
    netskopebwan_gateway_activate.token,
  ]
}

resource "null_resource" "gre_tunnel_2" {
  triggers = {
    lan_ip        = aws_network_interface.lan.private_ip
    tgw_endpoint  = var.tgw_endpoint_ip_2
    tunnel_ip     = var.gre_tunnel_2_gateway_inside_ip
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ssm send-command \
        --instance-ids ${aws_instance.gateway.id} \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["infhostd gre add --name gre-tgw-2 --local_ip ${aws_network_interface.lan.private_ip} --remote_ip ${var.tgw_endpoint_ip_2} --tunnel_ip ${var.gre_tunnel_2_gateway_inside_ip}/30 --phy_intfname enp2s1"]' \
        --region ${var.aws_region} \
        --output text \
        --query 'Command.CommandId'
    EOT
  }

  depends_on = [
    aws_instance.gateway,
    aws_network_interface_attachment.lan,
    netskopebwan_gateway_activate.token,
  ]
}

# Restart container and service after all tunnels are configured
resource "null_resource" "gre_restart" {
  triggers = {
    tunnel_1 = null_resource.gre_tunnel_1.id
    tunnel_2 = null_resource.gre_tunnel_2.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ssm send-command \
        --instance-ids ${aws_instance.gateway.id} \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["infhostd restart-container", "sleep 10", "service infhost restart"]' \
        --region ${var.aws_region} \
        --output text
    EOT
  }

  depends_on = [
    null_resource.gre_tunnel_1,
    null_resource.gre_tunnel_2,
  ]
}
```

### 7.4 Terraform Implementation — Alternative Approach

Use `terraform-provider-shell` for a more declarative lifecycle:

```hcl
resource "shell_script" "gre_tunnel_1" {
  lifecycle_commands {
    create = <<-EOT
      aws ssm send-command \
        --instance-ids ${aws_instance.gateway.id} \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["infhostd gre add --name gre-tgw-1 --local_ip ${aws_network_interface.lan.private_ip} --remote_ip ${var.tgw_endpoint_ip_1} --tunnel_ip ${var.gre_tunnel_1_gateway_inside_ip}/30 --phy_intfname enp2s1"]' \
        --region ${var.aws_region}
    EOT

    delete = <<-EOT
      aws ssm send-command \
        --instance-ids ${aws_instance.gateway.id} \
        --document-name "AWS-RunShellScript" \
        --parameters 'commands=["infhostd gre delete --name gre-tgw-1"]' \
        --region ${var.aws_region}
    EOT
  }
}
```

This approach provides `delete` lifecycle support, enabling `terraform destroy` to clean up GRE tunnels. However, it requires installing the `scottwinkler/shell` provider.

### 7.5 SSM Wait Strategy

The SSM agent takes time to register after instance launch. The Terraform execution must wait for registration before sending commands:

```hcl
# Option A: AWS CLI waiter (used in the null_resource approach above)
aws ssm wait instance-information-available \
  --instance-information-filter-list key=InstanceIds,valueSet=<instance_id>

# Option B: Polling loop
until aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=<instance_id>" \
  --query 'InstanceInformationList[0].PingStatus' \
  --output text | grep -q "Online"; do
  sleep 10
done
```

---

## 8. Resource Dependency Ordering

```
Phase 1: AWS Infrastructure (parallel where possible)
├── VPC, Subnets, Route Tables, IGW
├── Security Groups (public, private, endpoint)
├── WAN ENI + EIP (public subnet)
├── LAN ENI (private subnet)
├── TGW + VPC Attachment
├── SSM VPC Endpoints (ssm, ssmmessages, ec2messages)
└── IAM Role + Instance Profile

Phase 2: Netskope Gateway Object
├── data.netskopebwan_policy (lookup)
├── netskopebwan_gateway (create gateway)
└── netskopebwan_gateway_activate (get activation token)
    └── Depends on: gateway object

Phase 3: EC2 Launch
└── aws_instance.gateway
    ├── Depends on: WAN ENI, IAM instance profile, activation token
    └── User data includes: password, activation token, SSM agent install

Phase 4: LAN ENI Attachment
└── aws_network_interface_attachment.lan
    └── Depends on: EC2 instance, LAN ENI

Phase 5: Wait for SSM Registration
└── SSM agent registers with AWS Systems Manager
    └── Depends on: EC2 running, SSM VPC endpoints, IAM role

Phase 6: Netskope Interface Config
├── netskopebwan_gateway_interface.ge1 (WAN — uses WAN ENI private IP)
└── netskopebwan_gateway_interface.ge2 (LAN — uses LAN ENI private IP)
    └── Depends on: LAN ENI attachment, gateway activation

Phase 7: GRE Tunnel Config via SSM
├── null_resource.gre_tunnel_1
├── null_resource.gre_tunnel_2
└── null_resource.gre_restart
    └── Depends on: EC2 running, SSM registered, gateway activated, LAN attached

Phase 8: BGP Peer Config
├── netskopebwan_gateway_bgpconfig.tgw_peer_1
└── netskopebwan_gateway_bgpconfig.tgw_peer_2
    └── Depends on: GRE tunnels configured (BGP peers run over GRE inside IPs)
```

### Dependency Graph (Terraform)

```
aws_vpc
├── aws_subnet.public
│   ├── aws_network_interface.wan
│   │   ├── aws_eip_association.wan
│   │   └── aws_instance.gateway ──────────────────────┐
│   └── aws_vpc_endpoint.ssm/ssmmessages/ec2messages   │
├── aws_subnet.private                                  │
│   ├── aws_network_interface.lan                       │
│   │   └── aws_network_interface_attachment.lan ◄──────┘
│   └── aws_ec2_transit_gateway_vpc_attachment          │
├── aws_internet_gateway                                │
├── aws_security_group.public/private/endpoint          │
└── aws_iam_instance_profile ──────────────────────────►┘

netskopebwan_gateway
├── netskopebwan_gateway_activate ──────► aws_instance (user_data)
├── netskopebwan_gateway_interface.ge1
├── netskopebwan_gateway_interface.ge2
├── null_resource.gre_tunnel_1 ──────────► null_resource.gre_restart
├── null_resource.gre_tunnel_2 ──────────► null_resource.gre_restart
├── netskopebwan_gateway_bgpconfig.tgw_peer_1
└── netskopebwan_gateway_bgpconfig.tgw_peer_2
```

---

## 9. Variables

```hcl
# ──────────────────────────────────────
# AWS
# ──────────────────────────────────────
variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "eu-west-1"
}

variable "availability_zone" {
  description = "Availability zone within the region"
  type        = string
  default     = "eu-west-1a"
}

variable "vpc_cidr" {
  description = "CIDR block for the gateway VPC"
  type        = string
  default     = "10.0.0.0/24"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public (WAN) subnet"
  type        = string
  default     = "10.0.0.0/26"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private (LAN) subnet"
  type        = string
  default     = "10.0.0.64/26"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "sase-gw"
}

variable "instance_type" {
  description = "EC2 instance type (c5.xlarge or larger)"
  type        = string
  default     = "c5.xlarge"
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair for SSH access"
  type        = string
}

# ──────────────────────────────────────
# Netskope
# ──────────────────────────────────────
variable "netskope_api_url" {
  description = "Netskope BWAN API base URL"
  type        = string
}

variable "netskope_api_token" {
  description = "Netskope BWAN API bearer token"
  type        = string
  sensitive   = true
}

variable "gateway_name" {
  description = "Name for the SASE gateway in Netskope"
  type        = string
}

variable "gateway_role" {
  description = "Gateway role (hub or spoke)"
  type        = string
  default     = "hub"
}

variable "gateway_policy_name" {
  description = "Name of the Netskope policy to assign"
  type        = string
}

variable "gateway_password" {
  description = "Password for the gateway infiot user"
  type        = string
  sensitive   = true
}

variable "gateway_bgp_asn" {
  description = "BGP AS number for the SASE gateway"
  type        = number
  default     = 400
}

# ──────────────────────────────────────
# Transit Gateway
# ──────────────────────────────────────
variable "create_tgw" {
  description = "Whether to create a new TGW or use an existing one"
  type        = bool
  default     = true
}

variable "existing_tgw_id" {
  description = "ID of an existing TGW (required if create_tgw = false)"
  type        = string
  default     = ""
}

variable "tgw_asn" {
  description = "BGP ASN for the Transit Gateway"
  type        = number
  default     = 64512
}

variable "workload_cidrs" {
  description = "List of workload VPC CIDRs to route through TGW"
  type        = list(string)
  default     = []
}

# ──────────────────────────────────────
# GRE Tunnels
# ──────────────────────────────────────
variable "tgw_endpoint_ip_1" {
  description = "TGW endpoint IP for GRE tunnel 1"
  type        = string
}

variable "tgw_endpoint_ip_2" {
  description = "TGW endpoint IP for GRE tunnel 2"
  type        = string
}

variable "gre_tunnel_1_gateway_inside_ip" {
  description = "Gateway-side inside IP for GRE tunnel 1 (e.g., 169.254.10.2)"
  type        = string
}

variable "gre_tunnel_1_tgw_inside_ip" {
  description = "TGW-side inside IP for GRE tunnel 1 (e.g., 169.254.10.1)"
  type        = string
}

variable "gre_tunnel_2_gateway_inside_ip" {
  description = "Gateway-side inside IP for GRE tunnel 2 (e.g., 169.254.11.2)"
  type        = string
}

variable "gre_tunnel_2_tgw_inside_ip" {
  description = "TGW-side inside IP for GRE tunnel 2 (e.g., 169.254.11.1)"
  type        = string
}
```

---

## 10. Outputs

```hcl
# ──────────────────────────────────────
# Netskope Gateway
# ──────────────────────────────────────
output "gateway_id" {
  description = "Netskope BWAN gateway ID"
  value       = netskopebwan_gateway.this.id
}

output "activation_token" {
  description = "Gateway activation token"
  value       = netskopebwan_gateway_activate.token.token
  sensitive   = true
}

# ──────────────────────────────────────
# EC2 Instance
# ──────────────────────────────────────
output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.gateway.id
}

output "wan_public_ip" {
  description = "WAN interface public (EIP) IP"
  value       = aws_eip.wan.public_ip
}

output "wan_private_ip" {
  description = "WAN interface private IP"
  value       = aws_network_interface.wan.private_ip
}

output "lan_private_ip" {
  description = "LAN interface private IP"
  value       = aws_network_interface.lan.private_ip
}

# ──────────────────────────────────────
# Transit Gateway
# ──────────────────────────────────────
output "tgw_id" {
  description = "Transit Gateway ID"
  value       = local.tgw_id
}

output "tgw_attachment_id" {
  description = "TGW VPC attachment ID"
  value       = aws_ec2_transit_gateway_vpc_attachment.gateway.id
}

# ──────────────────────────────────────
# GRE Tunnels
# ──────────────────────────────────────
output "gre_tunnel_1_inside_ips" {
  description = "GRE tunnel 1 inside IPs (gateway / TGW)"
  value = {
    gateway = var.gre_tunnel_1_gateway_inside_ip
    tgw     = var.gre_tunnel_1_tgw_inside_ip
  }
}

output "gre_tunnel_2_inside_ips" {
  description = "GRE tunnel 2 inside IPs (gateway / TGW)"
  value = {
    gateway = var.gre_tunnel_2_gateway_inside_ip
    tgw     = var.gre_tunnel_2_tgw_inside_ip
  }
}

# ──────────────────────────────────────
# SSM
# ──────────────────────────────────────
output "ssm_session_command" {
  description = "Command to start an SSM session to the gateway"
  value       = "aws ssm start-session --target ${aws_instance.gateway.id} --region ${var.aws_region}"
}
```

---

## Source Material

| Document | Purpose |
|----------|---------|
| `planning/ssm-agent-test.yaml` | Validated CloudFormation template for dual-interface gateway with SSM |
| `planning/GRE_TGW_AUTOMATION_DISCUSSION.md` | Team feedback: GRE commands, interface names, persistence, AMI details |
| `examples/main.tf` | Existing netskopebwan provider usage patterns |
| `docs/Netskope One Gateway Deployment in AWS.pdf` | Official Netskope deployment guide |
| `docs/SASE Gateway Integration with Workloads on Existing AWS VPCs Using AWS Transit Gateway.pdf` | TGW integration reference |
