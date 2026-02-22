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

### Conditional Resource Creation (Create vs. Reuse Existing)

The module supports both "create new" and "use existing" patterns for major infrastructure components. This is implemented using a consistent pattern: a boolean flag controls resource creation, and a local variable resolves to either the created resource or an existing one via data source lookup.

#### Pattern Overview

```hcl
# 1. Data source to look up existing resource (conditional)
data "aws_vpc" "existing" {
  count = var.aws_network_config.create_vpc == false ? 1 : 0
  id    = var.aws_network_config.vpc_id
}

# 2. Resource to create new (conditional)
resource "aws_vpc" "this" {
  count = var.aws_network_config.create_vpc ? 1 : 0
  # ...
}

# 3. Local that resolves to whichever exists
locals {
  vpc_id = var.aws_network_config.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
}
```

All downstream resources reference `local.vpc_id` rather than the resource or data source directly, making them agnostic to whether the VPC was created or reused.

#### Supported Resources

| Resource | Create Flag | Existing ID Variable | File | Local Reference |
|----------|-------------|---------------------|------|-----------------|
| VPC | `aws_network_config.create_vpc` | `aws_network_config.vpc_id` | `vpc.tf:83-100` | `local.vpc_id` |
| Internet Gateway | (follows VPC) | (auto-discovered via VPC) | `vpc.tf:104-122` | `local.igw_id` |
| Transit Gateway | `aws_transit_gw.create_transit_gw` | `aws_transit_gw.tgw_id` | `vpc.tf:261-287` | `local.tgw` |
| TGW VPC Attachment | (follows VPC/TGW) | `aws_transit_gw.vpc_attachment` | `vpc.tf:291-320` | `local.tgw_attachment_id` |
| Route Tables | (follows VPC) | `aws_network_config.route_table.public/private` | `vpc.tf:140-166` | `local.public_rt_id`, `local.private_rt_id` |

#### VPC (`vpc.tf`)

```hcl
# When create_vpc = false, look up the existing VPC
data "aws_vpc" "existing" {
  count = var.aws_network_config.create_vpc == false ? 1 : 0
  id    = var.aws_network_config.vpc_id
}

# When create_vpc = true, create a new VPC
resource "aws_vpc" "this" {
  count      = var.aws_network_config.create_vpc ? 1 : 0
  cidr_block = var.aws_network_config.vpc_cidr
  # ...
}

locals {
  vpc_id = var.aws_network_config.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
}
```

When reusing an existing VPC, the Internet Gateway is auto-discovered:

```hcl
data "aws_internet_gateway" "existing" {
  count = var.aws_network_config.create_vpc == false ? 1 : 0
  filter {
    name   = "attachment.vpc-id"
    values = [local.vpc_id]
  }
}
```

#### Transit Gateway (`vpc.tf`)

```hcl
# When create_transit_gw = false, look up the existing TGW
data "aws_ec2_transit_gateway" "existing" {
  count = var.aws_transit_gw.create_transit_gw == false && var.aws_transit_gw.tgw_id != null ? 1 : 0
  id    = var.aws_transit_gw.tgw_id
}

# When create_transit_gw = true, create a new TGW
resource "aws_ec2_transit_gateway" "this" {
  count           = var.aws_transit_gw.create_transit_gw ? 1 : 0
  amazon_side_asn = var.aws_transit_gw.tgw_asn
  # ...
}

locals {
  tgw = var.aws_transit_gw.create_transit_gw ? aws_ec2_transit_gateway.this[0] : data.aws_ec2_transit_gateway.existing[0]
}
```

#### TGW VPC Attachment (`vpc.tf`)

When reusing both an existing VPC and TGW, you may also reuse an existing VPC attachment:

```hcl
data "aws_ec2_transit_gateway_vpc_attachment" "existing" {
  count = (var.aws_network_config.create_vpc == false && var.aws_transit_gw.vpc_attachment != "") ? 1 : 0
  filter {
    name   = "transit-gateway-attachment-id"
    values = [var.aws_transit_gw.vpc_attachment]
  }
  # ...
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = (var.aws_network_config.create_vpc || var.aws_transit_gw.vpc_attachment == "") && local.has_lan_interfaces ? 1 : 0
  # ...
}
```

#### Route Tables (`vpc.tf`)

Route tables can be explicitly specified when reusing an existing VPC:

```hcl
resource "aws_route_table" "public" {
  count = (var.aws_network_config.create_vpc || var.aws_network_config.route_table.public == "") ? 1 : 0
  # ...
}

locals {
  public_rt_id = var.aws_network_config.route_table.public != "" ? var.aws_network_config.route_table.public : try(aws_route_table.public[0].id, "")
}
```

#### Example: Using All Existing Resources

```hcl
aws_network_config = {
  create_vpc = false
  vpc_id     = "vpc-0abc123def456"
  region     = "us-east-1"
  route_table = {
    public  = "rtb-0abc123"
    private = "rtb-0def456"
  }
}

aws_transit_gw = {
  create_transit_gw = false
  tgw_id            = "tgw-0abc123def456"
  vpc_attachment    = "tgw-attach-0abc123"  # Optional: reuse existing attachment
}
```

#### Important Notes

1. **Subnets are always created** — Even when reusing a VPC, the module creates new subnets for the gateways. This ensures proper isolation and consistent naming.

2. **TGW Connect is always created** — The TGW Connect attachment and Connect Peers are always created by the module, even when reusing an existing TGW.

3. **VPC attachment subnet limitation** — When reusing an existing TGW VPC attachment, you may need to manually update its subnet list due to an [AWS API limitation](https://github.com/hashicorp/terraform-provider-aws/issues) that prevents modifying attachment subnets via Terraform.

## Provider Internals

### Netskope BWAN Provider

The `netskopebwan` provider (source: `netskopeoss/netskopebwan`) communicates with the Netskope SD-WAN REST API.

**Credential Resolution** (in `provider.tf`):

The provider credentials can come from environment variables or the `netskope_tenant` object. Environment variables take precedence:

```hcl
locals {
  tenant_url   = coalesce(var.netskope_api_url, var.netskope_tenant.tenant_url)
  tenant_token = coalesce(var.netskope_api_token, var.netskope_tenant.tenant_token)
}
```

**API URL Transformation**:

The Netskope SD-WAN API uses a different hostname than the tenant portal. The code transforms the tenant URL by inserting `api` as the second segment:

```hcl
locals {
  # Input: "https://example.infiot.net"
  # Split by ".": ["https://example", "infiot", "net"]
  netskope_tenant_url_slice = split(".", local.tenant_url)

  # Insert "api" after the first segment:
  # ["https://example"] + ["api"] + ["infiot", "net"]
  tenant_api_url_slice = concat(
    slice(local.netskope_tenant_url_slice, 0, 1),  # First segment
    ["api"],                                        # Insert "api"
    slice(local.netskope_tenant_url_slice, 1, length(local.netskope_tenant_url_slice))  # Rest
  )

  # Join back: "https://example.api.infiot.net"
  tenant_api_url = join(".", local.tenant_api_url_slice)
}
```

| Tenant URL | API URL |
|------------|---------|
| `https://example.infiot.net` | `https://example.api.infiot.net` |
| `https://corp.stage0.infiot.net` | `https://corp.api.stage0.infiot.net` |

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

### SSM Limitation: No Session Manager After Activation

Once the Netskope BWAN gateway appliance is activated, SSM Session Manager (`aws ssm start-session`) and the `RunShellScript` document worker are non-functional. The SSM agent is running and reports "Online", but interactive shell sessions and shell-based command invocations fail silently or return errors. This appears to be a limitation of the appliance OS environment post-activation.

**Workaround:** Use a bastion host in the same VPC to SSH into the gateways via their private LAN IPs (`ssh infiot@<gateway-lan-ip>`). The optional bastion module (`bastion.tf`) provides this. The `RunCommand` document for GRE configuration still works because it uses the `aws:runShellScript` plugin with explicit command strings rather than an interactive session.

## SSE Monitor

The SSE monitor is a health-checking daemon deployed to each gateway that prevents traffic blackholing by controlling BGP default route advertisement based on IPsec tunnel state.

### How It Works

The monitor (`scripts/sse_monitor.sh`) runs as an infinite loop with a simple state machine:

```
                    ┌──────────────┐
          startup → │   unknown    │
                    └──────┬───────┘
                           │ wait for container + stabilize
                    ┌──────▼───────┐
         tunnels UP │  advertised  │◄──── applies frrcmds-advertise-default.json
                    └──────┬───────┘
                           │ tunnels DOWN or container stopped
                    ┌──────▼───────┐
       tunnels DOWN │  retracted   │◄──── applies frrcmds-retract-default.json
                    └──────────────┘
```

1. **Wait for container** — Polls `docker inspect` until `infiot_spoke` is running
2. **Stabilization** — Waits 30s for tunnels to establish after container start
3. **Poll loop** (every 10s):
   - If container stopped → retract default route, wait for restart
   - If `ikectl status` shows `ESTABLISHED` → advertise default route
   - If no tunnels established → retract default route
4. State changes are idempotent — FRR config is only applied on transitions

### FRR JSON Files

The monitor controls BGP by copying JSON command files into the `infiot_spoke` container and executing them via `ikectl frrcmds`. These files are generated per-gateway by `sse_monitor.tf` with the correct BGP peer IPs.

**`frrcmds-advertise-default.json`** — Tells both TGW BGP peers to originate a default route:
```json
{
  "frrCmdSets": [{
    "frrCmds": [
      "conf t",
      "router bgp <tenant_bgp_asn>",
      "neighbor <peer1> default-originate",
      "neighbor <peer2> default-originate"
    ]
  }]
}
```

**`frrcmds-retract-default.json`** — Removes default route advertisement:
```json
{
  "frrCmdSets": [{
    "frrCmds": [
      "conf t",
      "router bgp <tenant_bgp_asn>",
      "no neighbor <peer1> default-originate",
      "no neighbor <peer2> default-originate"
    ]
  }]
}
```

The `ikectl frrcmds` command applies these to the FRR routing daemon inside the container via `vtysh`.

### Deployment via SSM (`sse_monitor.tf`)

Unlike `gre_config.tf` which passes parameters to an SSM document, `sse_monitor.tf` builds a base64-encoded tar archive locally and sends it as a single SSM parameter:

1. **Local build** — Creates a temp directory mirroring the target filesystem:
   - `/root/sse_monitor/sse_monitor.sh` (copied from `scripts/`)
   - `/root/sse_monitor/frrcmds-advertise-default.json` (generated with per-gateway BGP peers)
   - `/root/sse_monitor/frrcmds-retract-default.json` (generated with per-gateway BGP peers)
   - `/etc/systemd/system/sse_monitor.service` (copied from `scripts/`)
   - `/etc/logrotate.d/sse_monitor` (copied from `scripts/`)
2. **Tar + base64** — `tar czf - root etc | base64` produces a single string
3. **SSM send** — The SSM document extracts the payload with `base64 -d | tar xz -C /`
4. **Enable** — `systemctl enable --now sse_monitor` starts the service immediately

The `null_resource.sse_monitor` depends on `null_resource.gre_config` to ensure GRE tunnels and BGP peers are configured before the monitor starts checking tunnel health.

### Systemd Service

The service unit (`scripts/sse_monitor.service`) ensures the monitor:
- Starts after Docker (`After=docker.service`, `Requires=docker.service`)
- Auto-restarts on crash (`Restart=always`, `RestartSec=10`)
- Starts on boot (`WantedBy=multi-user.target`)

### Log Rotation

`scripts/sse_monitor.logrotate` rotates `/var/log/sse_monitor.log` at 100MB, keeping 3 compressed archives. Uses `copytruncate` so the running script doesn't need to be signalled.

## User-Data and Cloud-Init

The EC2 user-data script (`scripts/user-data.sh`) is a cloud-config YAML that:
1. Sets the gateway console password
2. Provides the Netskope activation URI and token (consumed by the BWAN image on first boot)
3. **Pins the IMDS route** — Adds a `/32` host route for `169.254.169.254` to the primary ENI, preventing the Netskope overlay's `169.254.0.0/16` connected route from capturing metadata traffic (see IMDS Fix below)
4. Downloads and installs the SSM agent from the regional S3 bucket
5. Enables and starts the SSM agent service

### IMDS Route Fix

After gateway activation, the `infiot_spoke` container creates an overlay interface with an address in `169.254.0.0/16`. This adds a connected route that captures all link-local traffic — including `169.254.169.254` (EC2 Instance Metadata Service). Without the fix, the SSM agent cannot refresh IAM credentials and all SSM operations fail silently.

The fix in user-data adds `ip route add 169.254.169.254/32 dev <primary-ENI>` at boot, before the overlay comes up. The `/32` host route always wins over the `/16` connected route via longest-prefix match. A networkd-dispatcher hook makes the route persistent across reboots.

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
    ├──► sse_monitor.tf SSM document + null_resource per gateway
    │                   (depends on gre_config, deploys health monitor + FRR JSON)
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
