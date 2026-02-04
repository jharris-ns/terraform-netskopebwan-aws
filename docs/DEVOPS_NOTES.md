# DevOps Notes

Technical details for developers maintaining or extending this module.

## Terraform Patterns

### Dynamic Gateway Map (`locals.tf`)

The core design pattern is a computed `local.gateways` map that generates all per-gateway configuration from two count variables. This map is the single source of truth consumed by every resource file — adding a gateway requires only incrementing `gateway_count`.

```hcl
locals {
  available_azs = data.aws_availability_zones.available.names

  # Take the first az_count AZs (capped to however many actually exist in the region)
  selected_azs = slice(local.available_azs, 0, min(var.az_count, length(local.available_azs)))

  # ---------------------------------------------------------------------------
  # Gateway map — the single source of truth consumed by every resource file.
  #
  # Generates one entry per gateway from gateway_count. Each entry contains
  # all the computed networking values (subnets, inside CIDRs, AZ placement)
  # so that downstream resources only need `for_each = local.gateways`.
  #
  # Map keys are stable names (e.g. "aws-gw-1") rather than numeric indices,
  # so adding or removing a gateway does not force recreation of others.
  #
  # Example with gateway_count=2, az_count=2, vpc_cidr=172.32.0.0/16, subnet_size=28:
  #   "aws-gw-1" => { az=us-east-1a, ge1=172.32.0.0/28,  ge2=172.32.0.16/28, inside=169.254.100.0/29 }
  #   "aws-gw-2" => { az=us-east-1b, ge1=172.32.0.32/28, ge2=172.32.0.48/28, inside=169.254.100.8/29 }
  # ---------------------------------------------------------------------------
  gateways = {
    for i in range(var.gateway_count) :
    "${var.gateway_prefix}-${i + 1}" => {

      # Round-robin AZ assignment: gateway 0 → AZ 0, gateway 1 → AZ 1, gateway 2 → AZ 0, ...
      availability_zone = local.selected_azs[i % length(local.selected_azs)]

      subnets = {
        ge1 = {
          # WAN/public subnet.
          # cidrsubnet(prefix, newbits, netnum) subdivides the VPC CIDR into smaller blocks.
          #   newbits = subnet_size - vpc_prefix  (e.g. 28 - 16 = 12 → 4096 possible /28 subnets)
          #   netnum  = i * 2                     (even indices → WAN, keeping ge1/ge2 adjacent)
          subnet_cidr = cidrsubnet(
            var.aws_network_config.vpc_cidr,
            var.subnet_size - tonumber(split("/", var.aws_network_config.vpc_cidr)[1]),
            i * 2
          )
          overlay = "public"
        }
        ge2 = {
          # LAN/private subnet — same formula, odd index (i * 2 + 1) so it sits
          # immediately after the corresponding ge1 subnet in the address space.
          subnet_cidr = cidrsubnet(
            var.aws_network_config.vpc_cidr,
            var.subnet_size - tonumber(split("/", var.aws_network_config.vpc_cidr)[1]),
            i * 2 + 1
          )
          overlay = null
        }
      }

      # GRE tunnel inside addressing — each gateway gets a /29 (8 IPs) carved from
      # inside_cidr_base (default 169.254.100.0/24).
      #   newbits = 29 - base_prefix  (e.g. 29 - 24 = 5 → 32 possible /29 blocks)
      #   netnum  = i                 (gateway 0 → .0/29, gateway 1 → .8/29, ...)
      # Within each /29: .1 = gateway, .2 = TGW peer 1, .3 = TGW peer 2
      inside_cidr = cidrsubnet(
        var.inside_cidr_base,
        29 - tonumber(split("/", var.inside_cidr_base)[1]),
        i
      )

      # BGP MED — equal across all gateways to enable ECMP load balancing on the TGW
      bgp_metric = "10"

      gateway_name = "${var.gateway_prefix}-${i + 1}"
      gateway_role = var.gateway_role
    }
  }
}
```

#### Generated Structure

With `gateway_count=2`, `az_count=2`, `vpc_cidr="172.32.0.0/16"`, `subnet_size=28`, `inside_cidr_base="169.254.100.0/24"`:

```hcl
local.gateways = {
  "aws-gw-1" = {
    availability_zone = "us-east-1a"
    subnets = {
      ge1 = { subnet_cidr = "172.32.0.0/28",  overlay = "public" }
      ge2 = { subnet_cidr = "172.32.0.16/28", overlay = null }
    }
    inside_cidr  = "169.254.100.0/29"
    bgp_metric   = "10"
    gateway_name = "aws-gw-1"
    gateway_role = "hub"
  }
  "aws-gw-2" = {
    availability_zone = "us-east-1b"
    subnets = {
      ge1 = { subnet_cidr = "172.32.0.32/28", overlay = "public" }
      ge2 = { subnet_cidr = "172.32.0.48/28", overlay = null }
    }
    inside_cidr  = "169.254.100.8/29"
    bgp_metric   = "10"
    gateway_name = "aws-gw-2"
    gateway_role = "hub"
  }
}
```

This map drives all downstream resources. `vpc.tf` further flattens it into `local.gateway_subnets` (keyed `"aws-gw-1-ge1"`, `"aws-gw-1-ge2"`, etc.) for resources that need one instance per interface rather than per gateway.

### `for_each` Over Gateway Map

Terraform offers two ways to create multiple copies of a resource: `count` and `for_each`.

**`count`** uses a numeric index (`[0]`, `[1]`, `[2]`). The problem is that if you remove the item at index 0, every item after it shifts down — Terraform sees `[1]` become `[0]` and tries to destroy and recreate it. For infrastructure like EC2 instances this is destructive and unnecessary.

**`for_each`** uses a map, so each resource instance is keyed by a string (e.g., `"aws-gw-1"`). Removing `"aws-gw-1"` only destroys that one resource — `"aws-gw-2"` and `"aws-gw-3"` are untouched.

This configuration uses `for_each` everywhere. A resource block like:

```hcl
resource "aws_instance" "gateways" {
  for_each = local.gateways
  # ...
}
```

creates one EC2 instance per key in the `gateways` map. Terraform tracks each instance by its key, producing addresses like:

```
aws_instance.gateways["aws-gw-1"]
aws_instance.gateways["aws-gw-2"]
```

Inside the resource block, `each.key` is the gateway name (e.g., `"aws-gw-1"`) and `each.value` is the full gateway object (availability zone, subnets, inside CIDR, etc.).

The benefits:
- **Stable addresses** — keyed by name, not position, so no accidental recreation
- **Safe scaling** — adding `aws-gw-3` doesn't touch `aws-gw-1` or `aws-gw-2`
- **Readable plans** — `terraform plan` shows exactly which named gateway is changing

### Flattened Interface Maps

Some resources need one instance per *interface*, not per *gateway*. For example, each gateway has two ENIs (ge1 and ge2), so with 2 gateways you need 4 ENI resources.

The `gateways` map is nested — each gateway contains a `subnets` sub-map with `ge1` and `ge2` entries. Terraform's `for_each` only accepts a flat (single-level) map, so `vpc.tf` flattens the nested structure:

```hcl
# Input structure (nested):
#   gateways = {
#     "aws-gw-1" = { subnets = { ge1 = {...}, ge2 = {...} } }
#     "aws-gw-2" = { subnets = { ge1 = {...}, ge2 = {...} } }
#   }
#
# Output structure (flat):
#   gateway_subnets = {
#     "aws-gw-1-ge1" = { ... }
#     "aws-gw-1-ge2" = { ... }
#     "aws-gw-2-ge1" = { ... }
#     "aws-gw-2-ge2" = { ... }
#   }

gateway_subnets = merge([
  for gw_key, gw in local.gateways : {    # outer loop: each gateway
    for intf_key, intf in gw.subnets :     # inner loop: each interface in that gateway
    "${gw_key}-${intf_key}" => { ... }     # composite key: "aws-gw-1-ge1"
    if intf != null                        # skip null interfaces
  }
]...)
# The trailing `...` is Terraform's "expansion" syntax — it unpacks the list
# of maps produced by the outer `for` into separate arguments for `merge()`,
# which combines them into a single flat map.
```

This flattened map can then be used directly with `for_each`:

```hcl
resource "aws_subnet" "gw_subnets" {
  for_each   = local.gateway_subnets
  cidr_block = each.value.subnet_cidr
  # ...
}
```

This pattern is used for subnets, ENIs, EIPs, and Netskope interface resources — anywhere a resource maps 1:1 with an interface rather than a gateway.

### Conditional Resource Creation

Several resources support both "create new" and "use existing" patterns:

```hcl
resource "aws_vpc" "this" {
  count = var.aws_network_config.create_vpc ? 1 : 0
  ...
}

locals {
  vpc_id = var.aws_network_config.create_vpc ? aws_vpc.this[0].id : var.aws_network_config.vpc_id
}
```

The same pattern applies to Transit Gateway, route tables, and client resources.

## Provider Internals

### Netskope BWAN Provider

The `netskopebwan` provider (v0.0.2, source: `netskopeoss/netskopebwan`) communicates with the Netskope SD-WAN REST API.

**Base URL derivation** (in `provider.tf`):
```hcl
locals {
  tenant_url_parts = split(".", replace(var.netskope_tenant.tenant_url, "https://", ""))
  api_url = "https://${local.tenant_url_parts[0]}.api.${join(".", slice(local.tenant_url_parts, 1, length(local.tenant_url_parts)))}"
}
```

Example: `https://example.infiot.net` → `https://example.api.infiot.net`

### API Propagation Delays

`time_sleep` resources (30s) are placed after API object creation to allow Netskope's backend to propagate configuration before dependent resources reference them.

## SSM Document Design

The GRE configuration is applied post-launch via an SSM Command document (`aws_ssm_document.gre_config`). The document has three steps:

1. **writeFrrConfig** — Writes FRR configuration JSON to `/infroot/workdir/frrcmds-user.json`
2. **configureGRETunnel** — Runs `infhostd config-gre` and restarts the infhost container
3. **verifyBgpConfig** — Polls `show bgp summary` in the FRR container until peers appear

### SSM Execution Flow

The `null_resource.gre_config` provisioner uses `local-exec` with AWS CLI to:
1. Poll `ssm describe-instance-information` until the agent reports "Online" (30 retries × 10s)
2. Send the SSM command with gateway-specific parameters
3. Poll `ssm get-command-invocation` for Success/Failed/TimedOut

This approach avoids needing direct SSH access to the gateways.

## User-Data and Cloud-Init

The EC2 user-data script (`scripts/user-data.sh`) is a cloud-config YAML that:
1. Sets the gateway console password
2. Provides the Netskope activation URI and token (consumed by the BWAN image on first boot)
3. Downloads and installs the SSM agent from the regional S3 bucket
4. Enables and starts the SSM agent service

## Variable Flow

```
Root variables (variables.tf)
    │
    ├──► locals.tf ──► local.gateways (computed map)
    │
    ├──► vpc.tf        VPC, subnets, route tables, SGs, TGW, SSM endpoints
    │                  (defines local.gateway_subnets, local.gw_lan_key, local.tgw, etc.)
    │
    ├──► interfaces.tf ENIs + EIPs (references local.gateway_subnets)
    │
    ├──► bgp_peer.tf   TGW Connect Peers (references ENIs, local.gw_lan_key)
    │
    ├──► nsg_config.tf  Netskope portal: policy, gateways, interfaces, activation, BGP
    │                   (references ENI private_ips, local.gateways)
    │
    ├──► ec2.tf        EC2 instances (references ENIs, activation tokens, local.gateways)
    │
    ├──► gre_config.tf SSM document + null_resource per gateway
    │                  (references EC2 instance IDs, ENI IPs, TGW peer addresses)
    │
    ├──► clients.tf    Optional client VPC + EC2 (conditional via count)
    │
    └──► iam.tf        IAM role + instance profile
```

## Pre-Commit and Validation

The configuration includes input validation blocks:
- `gateway_count`: Must be 1–4 (AWS TGW Connect Peer limit)
- `az_count`: Must be >= 1

Recommended pre-commit hooks for development:
- `terraform fmt` — formatting
- `terraform validate` — syntax and type checking
- `tflint` — linting
- `tfsec` or `checkov` — security scanning
