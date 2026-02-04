#------------------------------------------------------------------------------
#  Auto-computed gateway map from gateway_count and az_count
#------------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "region-name"
    values = [var.aws_network_config.region]
  }
}

locals {
  available_azs = data.aws_availability_zones.available.names
  selected_azs  = slice(local.available_azs, 0, min(var.az_count, length(local.available_azs)))

  # Build the gateways map from count variables
  gateways = {
    for i in range(var.gateway_count) :
    "${var.gateway_prefix}-${i + 1}" => {
      availability_zone = local.selected_azs[i % length(local.selected_azs)]
      subnets = {
        ge1 = {
          # Public/WAN subnet: 2 subnets per gateway (ge1 at even index, ge2 at odd)
          subnet_cidr = cidrsubnet(var.aws_network_config.vpc_cidr, var.subnet_size - tonumber(split("/", var.aws_network_config.vpc_cidr)[1]), i * 2)
          overlay     = "public"
        }
        ge2 = {
          # LAN subnet
          subnet_cidr = cidrsubnet(var.aws_network_config.vpc_cidr, var.subnet_size - tonumber(split("/", var.aws_network_config.vpc_cidr)[1]), i * 2 + 1)
          overlay     = null
        }
      }
      # /29 blocks carved from inside_cidr_base (8 IPs each: i*8 offset)
      inside_cidr  = cidrsubnet(var.inside_cidr_base, 29 - tonumber(split("/", var.inside_cidr_base)[1]), i)
      bgp_metric   = tostring((i + 1) * 10)
      gateway_name = "${var.gateway_prefix}-${i + 1}"
      gateway_role = var.gateway_role
    }
  }
}
