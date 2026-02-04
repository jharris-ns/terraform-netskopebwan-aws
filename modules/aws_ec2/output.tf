#------------------------------------------------------------------------------
#  Copyright (c) 2022 Infiot Inc.
#  All rights reserved.
#------------------------------------------------------------------------------

output "instance_ids" {
  description = "Map of gateway key to EC2 instance ID"
  value       = { for gw_key, inst in aws_instance.gateways : gw_key => inst.id }
}
