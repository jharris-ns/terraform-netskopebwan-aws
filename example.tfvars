#------------------------------------------------------------------------------
#  Example: Create new VPC with 2 gateways across 2 AZs
#------------------------------------------------------------------------------

# AWS VPC configuration
# - create_vpc: set true to create a new VPC, false to use an existing one
# - vpc_id: required when create_vpc = false
# - vpc_cidr: CIDR block for the VPC; gateway subnets are auto-carved from this
# - route_table: optional existing route table IDs (auto-created if omitted)
aws_network_config = {
  create_vpc = true
  region     = "ap-southeast-2"
  vpc_cidr   = "172.32.0.0/16"
}

# Number of gateways to deploy (1-4, limited by AWS TGW Connect Peer max)
gateway_count = 2

# Number of availability zones to distribute gateways across (round-robin)
az_count = 2

# Naming prefix for gateway identifiers
# Gateway keys are generated as: {gateway_prefix}-1, {gateway_prefix}-2, etc.
# EC2 instance Name tags become: {gateway_prefix}-{n}-{deployment_name}
gateway_prefix = "aws-gw-ap2"

# Environment prefix for resource naming (e.g. VPC, TGW, security groups)
# environment = "prod"

# Role assigned to all gateways (hub or spoke)
# gateway_role = "hub"

# Base /24 link-local CIDR from which /29 blocks are carved per gateway
# Gateway 1 gets first /29, gateway 2 gets second /29, etc.
# inside_cidr_base = "169.254.100.0/24"

# Prefix length for auto-generated gateway subnets carved from vpc_cidr
# Each gateway gets 2 subnets (ge1 public, ge2 LAN) of this size
# subnet_size = 28

# AWS Transit Gateway configuration
# - create_transit_gw: set true to create a new TGW, false to use existing
# - tgw_id: required when create_transit_gw = false
# - tgw_asn: BGP ASN for the TGW (remote-as for gateway BGP peers)
# - tgw_cidr: CIDR block assigned to the TGW
# - phy_intfname: physical interface name on the gateway for GRE underlay
aws_transit_gw = {
  create_transit_gw = true
  tgw_asn           = "64513"
  tgw_cidr          = "192.0.1.0/24"
}

# Netskope tenant credentials
# - deployment_name: used in resource Name tags as a suffix
# - tenant_url: Netskope tenant URL for gateway activation
# - tenant_token: activation token for gateway registration
# - tenant_bgp_asn: BGP ASN used by gateways (default: 400)
netskope_tenant = {
  deployment_name = "60675"
  tenant_url      = "https://example.infiot.net"
  tenant_token    = "WzEwPSJd"
  tenant_bgp_asn  = "400"
}

# Netskope gateway shared configuration
# - gateway_policy: policy name assigned to all gateways
# - gateway_password: console login password (default: infiot)
# - gateway_model: gateway model type (default: iXVirtual)
# - dns_primary/dns_secondary: DNS servers for gateway interfaces
netskope_gateway_config = {
  gateway_policy = "aws-gw-ap2"
}

# AWS EC2 instance configuration
# - keypair: SSH key pair name for instance access
# - instance_type: EC2 instance type (default: t3.medium)
aws_instance = {
  keypair = "test"
}

# Common tags applied to all AWS resources via provider default_tags
# These merge with per-resource Name tags. Add org-specific tags as needed.
tags = {
  ManagedBy   = "terraform"
  Environment = "production"
  Project     = "netskope-bwan"
  Owner       = "network-team"
}

# Optional test client deployment
# - create_clients: set true to deploy a test client instance
# - ports: list of ports to forward through the gateway
clients = {
  create_clients = true
}
