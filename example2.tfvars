#------------------------------------------------------------------------------
#  Example: Use existing VPC and TGW with 2 gateways across 2 AZs
#------------------------------------------------------------------------------

# AWS VPC configuration (using existing VPC)
# - set create_vpc = false and provide vpc_id to use an existing VPC
# - region is still required for SSM endpoint and AMI lookups
aws_network_config = {
  create_vpc = false
  vpc_id     = "vpc-064378cc401df95e5"
  region     = "ap-southeast-2"
}

# Number of gateways to deploy (1-4, limited by AWS TGW Connect Peer max)
gateway_count = 2

# Number of availability zones to distribute gateways across (round-robin)
az_count = 2

# Naming prefix for gateway identifiers
# Gateway keys are generated as: {gateway_prefix}-1, {gateway_prefix}-2, etc.
# EC2 instance Name tags become: {gateway_prefix}-{n}-{deployment_name}
gateway_prefix = "aws-gw-ap2"

# AWS Transit Gateway configuration (using existing TGW)
# - set create_transit_gw = false and provide tgw_id to use an existing TGW
aws_transit_gw = {
  create_transit_gw = false
  tgw_id            = "tgw-084a9cb2bf3d8484f"
}

# Netskope tenant credentials
# - deployment_name: used in resource Name tags as a suffix
# - tenant_url: Netskope tenant URL for gateway activation
# - tenant_token: activation token for gateway registration
# - tenant_bgp_asn: BGP ASN used by gateways (default: 400)
netskope_tenant = {
  deployment_name = "606787aaac"
  tenant_url      = "https://example.infiot.net"
  tenant_token    = "WzEsIjYzNWNhZjSJd"
  tenant_bgp_asn  = "400"
}

# Netskope gateway shared configuration
# - gateway_policy: policy name assigned to all gateways
netskope_gateway_config = {
  gateway_policy = "aws-gw-ap2"
}

# AWS EC2 instance configuration
# - keypair: SSH key pair name for instance access
aws_instance = {
  keypair = "venky"
}

# Common tags applied to all AWS resources via provider default_tags
tags = {
  ManagedBy   = "terraform"
  Environment = "staging"
  Project     = "netskope-bwan"
}

# Optional test client deployment
clients = {
  create_clients = true
}
