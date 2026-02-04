
#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------
module "aws_vpc" {
  source             = "./modules/aws_vpc"
  aws_network_config = var.aws_network_config
  gateways           = local.gateways
  clients            = var.clients
  aws_transit_gw     = var.aws_transit_gw
  netskope_tenant    = var.netskope_tenant
}

module "nsg_config" {
  source                  = "./modules/nsg_config"
  gateways                = local.gateways
  gateway_data            = module.aws_vpc.gateway_data
  clients                 = var.clients
  netskope_tenant         = var.netskope_tenant
  netskope_gateway_config = var.netskope_gateway_config
  aws_transit_gw          = var.aws_transit_gw
}

module "aws_ec2" {
  source                  = "./modules/aws_ec2"
  gateways                = local.gateways
  gateway_data            = module.aws_vpc.gateway_data
  gateway_tokens          = module.nsg_config.gateway_tokens
  aws_instance            = var.aws_instance
  netskope_tenant         = var.netskope_tenant
  netskope_gateway_config = var.netskope_gateway_config
  aws_network_config      = var.aws_network_config
  iam_instance_profile    = aws_iam_instance_profile.gateway_ssm_profile.name
}

module "gre_config" {
  source      = "./modules/gre_config"
  bgp_asn     = var.netskope_tenant.tenant_bgp_asn
  tgw_asn     = var.aws_transit_gw.tgw_asn
  region      = var.aws_network_config.region
  environment = var.netskope_gateway_config.gateway_policy

  gre_configs = {
    for gw_key, gw in local.gateways : gw_key => {
      instance_id  = module.aws_ec2.instance_ids[gw_key]
      inside_ip    = cidrhost(gw.inside_cidr, 1)
      inside_mask  = cidrnetmask(gw.inside_cidr)
      local_ip     = module.aws_vpc.gateway_data[gw_key].lan_ip
      remote_ip    = module.aws_vpc.gateway_data[gw_key].tgw_ip
      intf_name    = "gre1"
      mtu          = "1300"
      phy_intfname = var.aws_transit_gw.phy_intfname
      bgp_peers = {
        peer1 = cidrhost(gw.inside_cidr, 2)
        peer2 = cidrhost(gw.inside_cidr, 3)
      }
      bgp_metric = gw.bgp_metric
    }
  }
}

module "clients" {
  source             = "./modules/clients"
  count              = var.clients.create_clients ? 1 : 0
  clients            = var.clients
  aws_instance       = var.aws_instance
  netskope_tenant    = var.netskope_tenant
  aws_network_config = var.aws_network_config
  aws_transit_gw     = var.aws_transit_gw
}
