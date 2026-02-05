#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

locals {
  # Use env variables if set, otherwise fall back to object values
  tenant_url                = coalesce(var.netskope_api_url, var.netskope_tenant.tenant_url)
  tenant_token              = coalesce(var.netskope_api_token, var.netskope_tenant.tenant_token)
  netskope_tenant_url_slice = split(".", local.tenant_url)
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
  apitoken = local.tenant_token
}