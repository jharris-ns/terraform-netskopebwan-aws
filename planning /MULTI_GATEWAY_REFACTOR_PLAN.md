# Multi-Gateway Refactor Plan: `for_each` Scaling

## Overview

Refactor the Terraform module from a hardcoded primary/secondary (2-instance) pattern to a dynamic `for_each`-based approach supporting N gateways across multiple AZs.

## Current Architecture

The module uses separate resource blocks for primary and secondary gateways:

```
aws_instance.netskope_sdwan_gw_instance        # primary
aws_instance.netskope_sdwan_ha_gw_instance[0]   # secondary (count = ha_enabled ? 1 : 0)
```

This pattern repeats across all modules (aws_vpc, nsg_config, aws_ec2, gre_config), resulting in duplicated resource definitions that cannot scale beyond 2 instances.

## Target Architecture

A single `gateways` map variable drives all resource creation via `for_each`. Adding a gateway is a matter of adding an entry to the map.

```
aws_instance.gateways["gw-1a"]
aws_instance.gateways["gw-1b"]
aws_instance.gateways["gw-1c"]
```

## AWS Constraints

- **TGW Connect Peers**: Maximum **5 Connect Peers per Connect attachment** (AWS hard limit)
- Each gateway requires 1 Connect Peer, so the ceiling is 5 gateways per Connect attachment
- Beyond 5 gateways: would require additional Connect attachments (out of scope for initial refactor)
- Each Connect Peer requires a unique `/29` inside CIDR from the `169.254.0.0/16` range

## Input Variable Design

### New `gateways` Variable

Replaces: `aws_network_config.primary_gw_subnets`, `aws_network_config.secondary_gw_subnets`, `aws_transit_gw.primary_inside_cidr`, `aws_transit_gw.secondary_inside_cidr`, `netskope_gateway_config.ha_enabled`

```hcl
variable "gateways" {
  description = "Map of gateway instances to deploy across AZs"
  type = map(object({
    availability_zone = string
    subnets = object({
      ge1 = object({
        subnet_cidr = string
        overlay     = optional(string, "public")
      })
      ge2 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
      }), null)
      ge3 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
      }), null)
      ge4 = optional(object({
        subnet_cidr = string
        overlay     = optional(string)
      }), null)
    })
    inside_cidr  = string                      # GRE tunnel inside CIDR (/29)
    bgp_metric   = string                      # MED value (lower = preferred path)
    gateway_name = optional(string)             # Override name (defaults to map key)
    gateway_role = optional(string, "hub")      # "hub" or "spoke"
  }))

  validation {
    condition     = length(var.gateways) <= 5
    error_message = "Maximum 5 gateways per TGW Connect attachment (AWS limit)."
  }
}
```

### Example tfvars — 3 Gateways Across 3 AZs

```hcl
gateways = {
  "gw-1a" = {
    availability_zone = "eu-west-1a"
    subnets = {
      ge1 = { subnet_cidr = "10.100.1.0/28", overlay = "public" }
      ge2 = { subnet_cidr = "10.100.1.16/28" }
    }
    inside_cidr = "169.254.100.0/29"
    bgp_metric  = "10"
  }
  "gw-1b" = {
    availability_zone = "eu-west-1b"
    subnets = {
      ge1 = { subnet_cidr = "10.100.2.0/28", overlay = "public" }
      ge2 = { subnet_cidr = "10.100.2.16/28" }
    }
    inside_cidr = "169.254.100.8/29"
    bgp_metric  = "20"
  }
  "gw-1c" = {
    availability_zone = "eu-west-1c"
    subnets = {
      ge1 = { subnet_cidr = "10.100.3.0/28", overlay = "public" }
      ge2 = { subnet_cidr = "10.100.3.16/28" }
    }
    inside_cidr = "169.254.100.16/29"
    bgp_metric  = "30"
  }
}
```

### Retained Variables (Unchanged)

These remain as-is since they are shared across all gateways:

- `aws_network_config` — VPC config (region, create_vpc, vpc_cidr, route_table)
  - Remove: `primary_zone`, `secondary_zone`, `primary_gw_subnets`, `secondary_gw_subnets`
- `aws_instance` — Instance type, AMI, keypair (shared across all gateways)
- `netskope_tenant` — Tenant ID, URL, token, BGP ASN
- `netskope_gateway_config` — Policy, password, model, DNS
  - Remove: `ha_enabled`, `gateway_name`, `gateway_role` (moved to per-gateway)
  - Keep: `gateway_policy` (shared policy for all gateways)
- `aws_transit_gw` — TGW creation, ASN, CIDR, phy_intfname
  - Remove: `primary_inside_cidr`, `secondary_inside_cidr` (moved to per-gateway)

## Module-by-Module Changes

### 1. `modules/aws_vpc/` — High Effort

**Current**: Separate resource blocks for primary/secondary subnets, ENIs, EIPs, Connect Peers.

**Target**: Single `for_each` loop per resource type iterating over the `gateways` map.

#### Subnets

```hcl
# Flatten gateways × interfaces into a single map
locals {
  gateway_subnets = merge([
    for gw_key, gw in var.gateways : {
      for intf_key, intf in gw.subnets :
      "${gw_key}-${intf_key}" => {
        gw_key    = gw_key
        intf_key  = intf_key
        subnet    = intf
        az        = gw.availability_zone
      } if intf != null
    }
  ]...)
}

resource "aws_subnet" "gw_subnets" {
  for_each          = { for k, v in local.gateway_subnets : k => v
                        if /* subnet doesn't already exist logic */ }
  vpc_id            = local.vpc_id
  cidr_block        = each.value.subnet.subnet_cidr
  availability_zone = each.value.az

  tags = {
    Environment = join("-", [each.value.gw_key, each.value.intf_key, var.netskope_tenant.tenant_id])
  }
}
```

#### ENIs

```hcl
resource "aws_network_interface" "gw_interfaces" {
  for_each        = local.gateway_subnets
  subnet_id       = aws_subnet.gw_subnets[each.key].id
  security_groups = [each.value.intf_key == "ge1" ?
    aws_security_group.public_sg.id :
    aws_security_group.private_sg.id]

  tags = {
    Name = join("-", [each.value.gw_key, upper(each.value.intf_key), var.netskope_tenant.tenant_id])
  }
}
```

#### EIPs (WAN interfaces only)

```hcl
locals {
  gateway_wan_interfaces = { for k, v in local.gateway_subnets : k => v
    if v.subnet.overlay == "public"
  }
}

resource "aws_eip" "gw_eips" {
  for_each             = local.gateway_wan_interfaces
  network_interface    = aws_network_interface.gw_interfaces[each.key].id
  ...
}
```

#### TGW Connect Peers

```hcl
resource "aws_ec2_transit_gateway_connect_peer" "gw_peers" {
  for_each = { for gw_key, gw in var.gateways : gw_key => gw
    if /* has LAN interface */ }

  peer_address                  = tolist(aws_network_interface.gw_interfaces["${each.key}-ge2"].private_ips)[0]
  bgp_asn                       = var.netskope_tenant.tenant_bgp_asn
  inside_cidr_blocks            = [each.value.inside_cidr]
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_connect.tgw_connect[0].id

  tags = {
    Name = join("-", ["BGP", each.key, var.netskope_tenant.tenant_id])
  }
}
```

#### TGW VPC Attachment

The VPC attachment needs all private (LAN) subnets across AZs:

```hcl
locals {
  lan_subnets = [for k, v in local.gateway_subnets :
    aws_subnet.gw_subnets[k].id if v.intf_key == "ge2"]
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attach" {
  count              = length(local.lan_subnets) > 0 ? 1 : 0
  subnet_ids         = local.lan_subnets
  transit_gateway_id = local.aws_transit_gateway.id
  vpc_id             = local.vpc_id
}
```

**Note**: TGW VPC attachment requires **one subnet per AZ** (not per gateway). If two gateways share the same AZ, they share the LAN subnet but have separate ENIs within it. This adds complexity — the subnet creation needs deduplication by AZ.

#### Outputs

```hcl
output "gateway_interfaces" {
  value = {
    for gw_key, gw in var.gateways : gw_key => {
      interfaces = {
        for intf_key in keys(gw.subnets) :
        intf_key => {
          id         = aws_network_interface.gw_interfaces["${gw_key}-${intf_key}"].id
          private_ip = tolist(aws_network_interface.gw_interfaces["${gw_key}-${intf_key}"].private_ips)[0]
        } if gw.subnets[intf_key] != null
      }
      lan_ip     = tolist(aws_network_interface.gw_interfaces["${gw_key}-ge2"].private_ips)[0]
      tgw_ip     = aws_ec2_transit_gateway_connect_peer.gw_peers[gw_key].transit_gateway_address
      bgp_peer1  = tolist(aws_ec2_transit_gateway_connect_peer.gw_peers[gw_key].inside_cidr_blocks)[0]
    }
  }
}
```

### 2. `modules/nsg_config/` — High Effort

**Current**: Separate `netskopebwan_gateway.primary` / `.secondary` with `count`.

**Target**: Single resource per type with `for_each`.

```hcl
resource "netskopebwan_gateway" "gateways" {
  for_each = var.gateways
  name     = coalesce(each.value.gateway_name, each.key)
  model    = var.netskope_gateway_config.gateway_model
  role     = each.value.gateway_role
  assigned_policy {
    name = var.netskope_gateway_config.gateway_policy
  }
}

resource "netskopebwan_gateway_activate" "gateways" {
  for_each           = var.gateways
  gateway_id         = netskopebwan_gateway.gateways[each.key].id
  timeout_in_seconds = 86400
}

resource "netskopebwan_gateway_interface" "gw_interfaces" {
  for_each = local.all_gateway_interfaces  # flattened gw × intf map
  gateway_id = netskopebwan_gateway.gateways[each.value.gw_key].id
  name       = upper(each.value.intf_key)
  ...
}

resource "netskopebwan_gateway_bgpconfig" "tgw_peer1" {
  for_each   = var.gateways
  gateway_id = netskopebwan_gateway.gateways[each.key].id
  name       = "tgw-peer-1-${each.key}"
  neighbor   = cidrhost(each.value.inside_cidr, 2)
  remote_as  = var.aws_transit_gw.tgw_asn
}

resource "netskopebwan_gateway_bgpconfig" "tgw_peer2" {
  for_each   = var.gateways
  gateway_id = netskopebwan_gateway.gateways[each.key].id
  name       = "tgw-peer-2-${each.key}"
  neighbor   = cidrhost(each.value.inside_cidr, 3)
  remote_as  = var.aws_transit_gw.tgw_asn
}
```

#### Outputs

```hcl
output "gateway_data" {
  value = {
    for gw_key, gw in var.gateways : gw_key => {
      token      = netskopebwan_gateway_activate.gateways[gw_key].token
      interfaces = { for intf_key, intf in ... }
    }
  }
}
```

### 3. `modules/aws_ec2/` — Low Effort

**Current**: Two separate `aws_instance` resources.

**Target**: Single resource with `for_each`.

```hcl
resource "aws_instance" "gateways" {
  for_each             = var.gateways
  ami                  = local.netskope_gw_image_id
  instance_type        = var.aws_instance.instance_type
  availability_zone    = each.value.availability_zone
  iam_instance_profile = var.iam_instance_profile
  key_name             = var.aws_instance.keypair

  user_data = templatefile("${path.module}/scripts/user-data.sh", {
    netskope_gw_default_password = var.netskope_gateway_config.gateway_password
    netskope_tenant_url          = var.netskope_tenant.tenant_url
    netskope_gw_activation_key   = var.gateway_data[each.key].token
    aws_region                   = var.aws_network_config.region
  })

  dynamic "network_interface" {
    for_each = keys(var.gateway_data[each.key].interfaces)
    content {
      network_interface_id = var.gateway_data[each.key].interfaces[network_interface.value].id
      device_index         = network_interface.key
    }
  }

  tags = {
    Name = join("-", [each.key, var.netskope_tenant.tenant_id])
  }
}
```

#### Outputs

```hcl
output "instance_ids" {
  value = { for gw_key, inst in aws_instance.gateways : gw_key => inst.id }
}
```

### 4. `modules/gre_config/` — Medium Effort

**Current**: Separate `null_resource.primary_gre_config` / `.secondary_gre_config`.

**Target**: Single resource with `for_each`.

```hcl
variable "gre_configs" {
  description = "Map of GRE tunnel configurations keyed by gateway"
  type = map(object({
    instance_id  = string
    inside_ip    = string
    inside_mask  = string
    local_ip     = string
    remote_ip    = string
    intf_name    = string
    mtu          = string
    phy_intfname = string
    bgp_peers    = object({ peer1 = string, peer2 = string })
    bgp_metric   = string
  }))
}

resource "null_resource" "gre_config" {
  for_each   = var.gre_configs
  depends_on = [aws_ssm_document.gre_config]

  triggers = {
    instance_id  = each.value.instance_id
    inside_ip    = each.value.inside_ip
    inside_mask  = each.value.inside_mask
    local_ip     = each.value.local_ip
    remote_ip    = each.value.remote_ip
    intf_name    = each.value.intf_name
    mtu          = each.value.mtu
    phy_intfname = each.value.phy_intfname
    bgp_asn      = var.bgp_asn
    tgw_asn      = var.tgw_asn
    bgp_peer1    = each.value.bgp_peers.peer1
    bgp_peer2    = each.value.bgp_peers.peer2
    bgp_metric   = each.value.bgp_metric
  }

  provisioner "local-exec" {
    command = <<-EOT
      REGION="${var.region}"
      INSTANCE_ID="${each.value.instance_id}"
      # ... same SSM polling + command logic ...
    EOT
  }
}
```

### 5. Root `main.tf` — Medium Effort

The root module builds the `gre_configs` map from outputs of the other modules:

```hcl
module "gre_config" {
  source     = "./modules/gre_config"
  bgp_asn    = var.netskope_tenant.tenant_bgp_asn
  tgw_asn    = var.aws_transit_gw.tgw_asn
  region     = var.aws_network_config.region
  environment = var.netskope_gateway_config.gateway_policy

  gre_configs = {
    for gw_key, gw in var.gateways : gw_key => {
      instance_id  = module.aws_ec2.instance_ids[gw_key]
      inside_ip    = cidrhost(gw.inside_cidr, 1)
      inside_mask  = cidrnetmask(gw.inside_cidr)
      local_ip     = module.aws_vpc.gateway_data[gw_key].lan_ip
      remote_ip    = module.aws_vpc.gateway_data[gw_key].tgw_ip
      intf_name    = "gre1"
      mtu          = "1300"
      phy_intfname = var.aws_transit_gw.phy_intfname
      bgp_peers    = {
        peer1 = cidrhost(gw.inside_cidr, 2)
        peer2 = cidrhost(gw.inside_cidr, 3)
      }
      bgp_metric = gw.bgp_metric
    }
  }
}
```

### 6. Root `output.tf` — Low Effort

```hcl
output "gateways" {
  value = {
    for gw_key, gw in var.gateways : gw_key => {
      instance_id = module.aws_ec2.instance_ids[gw_key]
      gre_configured = module.gre_config.gre_config_ids[gw_key] != null
    }
  }
}
```

## Complexity: Shared Subnets per AZ

The most complex part of the refactor is **subnet deduplication by AZ**. Currently each gateway gets its own subnets. With `for_each`, if two gateways are in the same AZ, they could potentially share subnets (with separate ENIs).

**Recommended approach**: Keep subnets per-gateway (not per-AZ). This is simpler and avoids CIDR conflicts. Each gateway entry in the map defines its own subnet CIDRs regardless of AZ. The TGW VPC attachment needs one subnet per AZ, which requires selecting one LAN subnet per unique AZ:

```hcl
locals {
  # Deduplicate: pick one LAN subnet per AZ for TGW attachment
  unique_az_lan_subnets = { for gw_key, gw in var.gateways :
    gw.availability_zone => aws_subnet.gw_subnets["${gw_key}-ge2"].id...
  }
  tgw_attachment_subnets = [for az, subnet_ids in local.unique_az_lan_subnets :
    subnet_ids[0]
  ]
}
```

## SSM VPC Endpoints

Currently deployed in the ge1 (WAN/public) subnet. With multiple gateways, endpoints only need to exist once per VPC (they're VPC-scoped). However, they need a subnet in each AZ where gateways are deployed:

```hcl
locals {
  unique_azs = distinct([for gw in var.gateways : gw.availability_zone])
  endpoint_subnets = [for az in local.unique_azs :
    /* pick one public subnet per AZ */]
}

resource "aws_vpc_endpoint" "ssm" {
  subnet_ids = local.endpoint_subnets
  ...
}
```

## Migration Strategy

### Fresh Deployment

No migration needed. Replace the old variable structure with the `gateways` map.

### Existing Deployment

Requires `terraform state mv` commands to rename resources:

```bash
# EC2 instances
terraform state mv \
  'module.aws_ec2.aws_instance.netskope_sdwan_gw_instance' \
  'module.aws_ec2.aws_instance.gateways["gw-1a"]'
terraform state mv \
  'module.aws_ec2.aws_instance.netskope_sdwan_ha_gw_instance[0]' \
  'module.aws_ec2.aws_instance.gateways["gw-1b"]'

# Repeat for ENIs, subnets, EIPs, TGW peers, NSG resources, GRE config...
```

**Recommendation**: Treat this as a new module version. Existing deployments continue using v1 (primary/secondary). New deployments use v2 (for_each). Provide a migration guide for users who want to upgrade in-place.

## Implementation Order

1. **Phase 1: Variables & Root Module**
   - Define `gateways` variable
   - Update root `main.tf` to pass gateway map to modules
   - Update root `variables.tf` and `output.tf`

2. **Phase 2: aws_vpc Module**
   - Refactor subnets, ENIs, EIPs to `for_each`
   - Handle AZ deduplication for TGW attachment
   - Refactor Connect Peers to `for_each`
   - Update outputs to return maps

3. **Phase 3: nsg_config Module**
   - Refactor gateway, interfaces, BGP, activation to `for_each`
   - Update outputs to return maps

4. **Phase 4: aws_ec2 Module**
   - Replace 2 instance resources with 1 `for_each`
   - Update outputs to return map

5. **Phase 5: gre_config Module**
   - Replace 2 null_resources with 1 `for_each`
   - Update SSM document (shared, no change needed)
   - Update outputs

6. **Phase 6: Testing**
   - Test with 1 gateway (regression)
   - Test with 2 gateways (parity with current HA)
   - Test with 3+ gateways (new capability)
   - Test scale to 5 gateways (AWS limit)

## Files Changed Summary

| File | Change Type | Effort |
|------|------------|--------|
| `variables.tf` (root) | Restructure | Medium |
| `main.tf` (root) | Restructure | Medium |
| `output.tf` (root) | Restructure | Low |
| `terraform.tfvars` | Restructure | Low |
| `modules/aws_vpc/vpc.tf` | Major refactor | High |
| `modules/aws_vpc/interfaces.tf` | Major refactor | High |
| `modules/aws_vpc/aws_bgp_peer.tf` | Refactor to for_each | Medium |
| `modules/aws_vpc/output.tf` | Restructure | Medium |
| `modules/aws_vpc/variables.tf` | Restructure | Medium |
| `modules/nsg_config/main.tf` | Major refactor | High |
| `modules/nsg_config/output.tf` | Restructure | Medium |
| `modules/nsg_config/variables.tf` | Restructure | Medium |
| `modules/aws_ec2/gateway.tf` | Refactor to for_each | Low |
| `modules/aws_ec2/output.tf` | Restructure | Low |
| `modules/aws_ec2/variables.tf` | Restructure | Low |
| `modules/gre_config/main.tf` | Refactor to for_each | Medium |
| `modules/gre_config/variables.tf` | Restructure | Medium |
| `modules/gre_config/outputs.tf` | Restructure | Low |

## Open Questions

1. **Subnet sharing**: Should two gateways in the same AZ share subnets or have dedicated ones?
   - Recommendation: Dedicated subnets per gateway (simpler, current pattern)

2. **Gateway naming**: Should each gateway have an independent name or derive from a base name?
   - Recommendation: Use map key as default, allow override via `gateway_name`

3. **Mixed roles**: Should gateways in the same deployment support mixed roles (some hub, some spoke)?
   - Recommendation: Yes, per-gateway `gateway_role` supports this

4. **Policy assignment**: Should all gateways share a policy or support per-gateway policies?
   - Recommendation: Shared policy initially, can add per-gateway override later

5. **Backwards compatibility**: Should the module support both the old (primary/secondary) and new (for_each) interfaces?
   - Recommendation: No. Clean break with migration guide. Maintaining both adds complexity.
