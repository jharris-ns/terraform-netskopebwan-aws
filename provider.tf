#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

locals {
  netskope_tenant_url_slice = split(".", var.netskope_tenant.tenant_url)
  tenant_api_url_slice      = concat(slice(local.netskope_tenant_url_slice, 0, 1), ["api"], slice(local.netskope_tenant_url_slice, 1, length(local.netskope_tenant_url_slice)))
  tenant_api_url            = join(".", local.tenant_api_url_slice)
}

provider "aws" {
  region = var.aws_network_config.region

  default_tags {
    tags = var.tags
  }
}

provider "netskopebwan" {
  baseurl  = local.tenant_api_url
  apitoken = var.netskope_tenant.tenant_token
}