#------------------------------------------------------------------------------
#  Auto-computed gateway map from gateway_count and az_count
#  See docs/DEVOPS_NOTES.md for detailed explanation of the cidrsubnet
#  computations, round-robin AZ assignment, and inside CIDR carving.
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

  gateways = {
    for i in range(var.gateway_count) :
    "${var.gateway_prefix}-${i + 1}" => {
      availability_zone = local.selected_azs[i % length(local.selected_azs)]
      subnets = {
        ge1 = {
          subnet_cidr = cidrsubnet(var.aws_network_config.vpc_cidr, var.subnet_size - tonumber(split("/", var.aws_network_config.vpc_cidr)[1]), i * 2)
          overlay     = "public"
        }
        ge2 = {
          subnet_cidr = cidrsubnet(var.aws_network_config.vpc_cidr, var.subnet_size - tonumber(split("/", var.aws_network_config.vpc_cidr)[1]), i * 2 + 1)
          overlay     = null
        }
      }
      inside_cidr  = cidrsubnet(var.inside_cidr_base, 29 - tonumber(split("/", var.inside_cidr_base)[1]), i)
      bgp_metric   = "10"
      gateway_name = "${var.gateway_prefix}-${i + 1}"
      gateway_role = var.gateway_role
    }
  }
}
