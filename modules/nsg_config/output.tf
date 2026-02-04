#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

output "gateway_tokens" {
  value = {
    for gw_key in keys(var.gateways) : gw_key => {
      id    = netskopebwan_gateway.gateways[gw_key].id
      token = netskopebwan_gateway_activate.gateways[gw_key].token
    }
  }
}
