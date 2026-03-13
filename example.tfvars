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

# Optional overrides (defaults shown) — uncomment to customize:
# environment      = "netskope"          # prefix for resource names (VPC, TGW, security groups)
# gateway_role     = "hub"               # role assigned to all gateways (hub or spoke)
# inside_cidr_base = "169.254.100.0/24"  # link-local /24 from which /29 blocks are carved per gateway
# subnet_size      = 28                  # prefix length for auto-generated gateway subnets

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

# Netskope tenant configuration
# - deployment_name: used in resource Name tags as a suffix
# - tenant_bgp_asn: BGP ASN used by gateways (default: 400)
#
# Secrets (tenant_url, tenant_token) must be set via environment variables:
#   export TF_VAR_netskope_tenant_url="example.infiot.net"   # with or without https://
#   export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
netskope_tenant = {
  deployment_name = "60675"
  tenant_bgp_asn  = "400"
}

# Netskope gateway shared configuration
# - gateway_policy: name of an existing policy on the Netskope tenant (must be created
#     in the SD-WAN portal before running terraform apply)
# - static_routes: CIDRs routed via the LAN interface on each gateway
#     (default: ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"])
#
# All options with custom values:
#   netskope_gateway_config = {
#     gateway_policy   = "my-policy"      # must already exist on the tenant
#     gateway_password = "my-password"    # console login password (default: infiot)
#     gateway_model    = "iXVirtual"      # gateway model type
#     dns_primary      = "8.8.8.8"        # primary DNS server
#     dns_secondary    = "8.8.4.4"        # secondary DNS server
#     static_routes    = ["10.0.0.0/8", "172.16.0.0/12"]  # AWS CIDRs to route via LAN
#   }
netskope_gateway_config = {
  gateway_policy = "aws-gw-ap2"
  static_routes  = ["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"]  # AWS CIDRs to route via LAN
}

# AWS EC2 instance configuration
# - keypair: SSH key pair name for instance access
# - instance_type: EC2 instance type (default: t3.medium)
aws_instance = {
  keypair = "REPLACE-WITH-YOUR-KEYPAIR"  # name of an existing EC2 key pair in your region (or "" for no SSH access)
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
# - create_clients: set true to deploy a test client instance in a separate VPC
# - ports: security group ingress ports allowed on the test client instance
clients = {
  create_clients = false
}

#------------------------------------------------------------------------------
#  Alternative: Use existing VPC and TGW
#  Uncomment the blocks below and comment out the corresponding blocks above.
#------------------------------------------------------------------------------

# aws_network_config = {
#   create_vpc = false
#   vpc_id     = "vpc-064378cc401df95e5"
#   region     = "ap-southeast-2"
# }

# aws_transit_gw = {
#   create_transit_gw = false
#   tgw_id            = "tgw-084a9cb2bf3d8484f"
#   vpc_attachment     = "tgw-attach-0c8453e5a81175a07"  # optional: reuse existing VPC attachment
# }
