# GRE Tunnel + BGP Configuration: End-to-End Data Flow

This document traces the complete sequence of Terraform resource creation, output propagation, and SSM document execution that constructs GRE tunnels to the AWS Transit Gateway and configures BGP over those tunnels.

---

## Phase 1: AWS Infrastructure (`module "aws_vpc"`)

### 1a. VPC + Subnets + ENIs

| Resource | File | Key Outputs |
|----------|------|-------------|
| `aws_vpc.netskope_sdwan_gw_vpc` | `modules/aws_vpc/vpc.tf:11` | VPC ID (stored in `local.netskope_sdwan_gw_vpc`) |
| `aws_subnet.netskope_sdwan_primary_gw_subnets` | `modules/aws_vpc/vpc.tf:95` | Subnet IDs per interface (ge1, ge2, etc.) |
| `aws_network_interface.netskope_sdwan_primary_gw_ip` | `modules/aws_vpc/interfaces.tf:16` | **ENI private IPs** — these become GRE tunnel local endpoints |

The ENI for the **first LAN interface** (the private/non-overlay one) is the critical one. Its private IP becomes the GRE underlay source address.

**Produced value:** `tolist(aws_network_interface.netskope_sdwan_primary_gw_ip[<first_lan_intf>].private_ips)[0]` — this is the **`primary_lan_ip`** in the module output.

### 1b. Transit Gateway + VPC Attachment + TGW Connect

| Resource | File | Key Outputs |
|----------|------|-------------|
| `aws_ec2_transit_gateway.netskope_sdwan_tgw` | `modules/aws_vpc/vpc.tf:262` | TGW ID, ASN, CIDR block |
| `aws_ec2_transit_gateway_vpc_attachment.netskope_sdwan_tgw_attach` | `modules/aws_vpc/vpc.tf:322` | Attachment ID (transport for GRE) |
| `aws_ec2_transit_gateway_connect.netskope_sdwan_tgw_connect` | `modules/aws_vpc/vpc.tf:344` | **TGW Connect attachment** — enables GRE/BGP protocol on the TGW side |

The TGW Connect resource tells AWS "I want to run GRE+BGP over this VPC attachment." It doesn't create tunnels by itself — the Connect Peers do that.

### 1c. TGW Connect Peers (AWS side of GRE+BGP)

| Resource | File | Key Inputs | Key Outputs |
|----------|------|------------|-------------|
| `netskope_sdwan_tgw_connect_peer1` | `modules/aws_vpc/aws_bgp_peer.tf:6` | `peer_address` = primary ENI LAN IP, `bgp_asn` = Netskope ASN, `inside_cidr_blocks` = `[primary_inside_cidr]` | **`transit_gateway_address`** = TGW's GRE endpoint IP |
| `netskope_sdwan_tgw_connect_peer2` | `modules/aws_vpc/aws_bgp_peer.tf:19` | Same pattern for secondary | Same |

This is where AWS allocates the GRE tunnel endpoints on the TGW side. The `inside_cidr_blocks` (e.g. `169.254.100.0/29`) defines the /29 from which both sides get their inside tunnel IPs. AWS assigns IPs from this range per its own logic (hosts 2 and 3 go to TGW, host 1 goes to the gateway).

**Produced value:** `transit_gateway_address` — this is the **`tgw_primary_ip`** in the module output, and becomes the GRE tunnel **remote IP** on the gateway.

### 1d. Module Output (`modules/aws_vpc/output.tf:10`)

```hcl
aws_vpc_output.aws_transit_gw = {
  tgw_primary_ip   = <TGW's GRE endpoint for primary>     # from connect_peer1
  tgw_secondary_ip = <TGW's GRE endpoint for secondary>   # from connect_peer2
  primary_lan_ip   = <primary GW's LAN ENI private IP>     # from ENI
  secondary_lan_ip = <secondary GW's LAN ENI private IP>   # from ENI
  tgw_id, tgw_asn, tgw_cidr                               # from TGW
}
```

---

## Phase 2: Netskope API Configuration (`module "nsg_config"`)

This module calls the Netskope tenant API to register gateways, create interfaces, configure BGP peers, and activate. It consumes the TGW output to configure the Netskope side. Its output adds `gateway_data` (activation tokens, interface mappings) to `netskope_gateway_config`.

---

## Phase 3: EC2 Instances (`module "aws_ec2"`)

| Resource | File | Key Inputs |
|----------|------|------------|
| `aws_instance.netskope_sdwan_gw_instance` | `modules/aws_ec2/gateway.tf:6` | user-data with password + activation + SSM agent install |
| `aws_instance.netskope_sdwan_ha_gw_instance` | `modules/aws_ec2/gateway.tf:34` | Same, conditional on `ha_enabled` |

user-data does three things at boot:

1. Sets gateway password
2. Activates against the Netskope tenant (URI + token)
3. Installs the SSM agent via dpkg

**Produced values:** `primary_instance_id`, `secondary_instance_id` — EC2 instance IDs passed to `gre_config`.

---

## Phase 4: GRE + BGP via SSM (`module "gre_config"`)

This is where everything comes together.

### Variable Mapping

How the variables are computed in `main.tf:33-69` and where each value originates:

| `gre_config` input | Computed from | Original source |
|---------------------|---------------|-----------------|
| `primary_gre_config.inside_ip` | `cidrhost(var.aws_transit_gw.primary_inside_cidr, 1)` | User input: host 1 of the /29 (e.g. `169.254.100.1`) |
| `primary_gre_config.inside_mask` | `cidrnetmask(var.aws_transit_gw.primary_inside_cidr)` | User input: netmask of the /29 (e.g. `255.255.255.248`) |
| `primary_gre_config.local_ip` | `module.aws_vpc...primary_lan_ip` | Phase 1: ENI private IP |
| `primary_gre_config.remote_ip` | `module.aws_vpc...tgw_primary_ip` | Phase 1: TGW Connect Peer's `transit_gateway_address` |
| `primary_bgp_peers.peer1` | `cidrhost(primary_inside_cidr, 2)` | Host 2 of the /29 (e.g. `169.254.100.2`) — TGW's inside IP |
| `primary_bgp_peers.peer2` | `cidrhost(primary_inside_cidr, 3)` | Host 3 of the /29 (e.g. `169.254.100.3`) — TGW's second inside IP |
| `bgp_asn` | `var.netskope_tenant.tenant_bgp_asn` | User input (default `400`) |
| `primary_bgp_metric` | Hardcoded `"10"` | MED for primary (lower = preferred) |
| `secondary_bgp_metric` | Hardcoded `"20"` | MED for secondary |
| `primary_instance_id` | `module.aws_ec2.primary_instance_id` | Phase 3: EC2 instance ID |

### SSM Document (`aws_ssm_document.gre_config`)

Created once in `modules/gre_config/main.tf:8`, shared by both primary and secondary. Accepts all tunnel + BGP params and runs two steps on the gateway:

**Step 1 — `writeFrrConfig`**: Writes `/infroot/workdir/frrcmds-user.json` containing 6 FRR command sets:

1. **HA community list** — `ip community-list standard HA_COMMUNITY permit 47474:47474`
2. **Prefix list + route-maps** — `advertise` and `set-med-peer` with `{{ bgpMetric }}`
3. **BGP router config** — two neighbors with `disable-connected-check`, `ebgp-multihop 2`, `set-med-peer` outbound route-map
4. **Controller filtering** — deny default route toward controllers (`To-Ctrlr-1..4 deny 5`)
5. **HA community filtering** — deny HA community from controllers + add community toward controllers
6. **Default-originate** — for both BGP peers

**Step 2 — `configureGRETunnel`**: Runs `infhostd config-gre` with the tunnel parameters, then `service infhost restart` + `infhostd restart-container`.

### Execution per Gateway (`null_resource.primary_gre_config`)

The `local-exec` provisioner runs **on your workstation** (not the gateway) and does:

1. **Poll SSM readiness** — calls `aws ssm describe-instance-information` every 10s for up to 5 min, waiting for the SSM agent (installed in user-data) to register as `Online`
2. **Send SSM command** — calls `aws ssm send-command` targeting the specific instance, passing all GRE + BGP parameters to the SSM document
3. **Poll command completion** — calls `aws ssm get-command-invocation` every 5s until `Success`, `Failed`, or timeout

The SSM agent on the gateway receives the command and executes both steps sequentially on the instance.

---

## GRE Tunnel Geometry

```
Gateway (inside 169.254.100.1) ←── GRE over enp2s1 ──→ TGW (inside 169.254.100.2, .3)
        local_ip = ENI LAN IP                           remote_ip = transit_gateway_address
        (private subnet)                                 (TGW Connect Peer)
```

BGP runs **inside the GRE tunnel** between `169.254.100.1` (gateway) and `169.254.100.2`/`.3` (TGW's two inside addresses). The `/29` gives both sides addresses in the same subnet so BGP can peer. `ebgp-multihop 2` and `disable-connected-check` are needed because the peers aren't directly connected at L2 — they're across GRE.

---

## Adding Additional Gateways

The current template is **hardcoded for exactly 2 gateways** (primary + optional HA secondary). Below is what's pinned to that assumption and what would need to change.

### What's Locked to 2 Gateways

1. **`modules/aws_vpc/aws_bgp_peer.tf`** — Two discrete resources: `connect_peer1` and `connect_peer2`. Not using `count` or `for_each` over a list.

2. **`variables.tf` (root)** — Separate `primary_inside_cidr` and `secondary_inside_cidr` fields in `aws_transit_gw`. Not a list.

3. **`main.tf`** — Separate `primary_gre_config` / `secondary_gre_config` / `primary_bgp_peers` / `secondary_bgp_peers` blocks. Each one manually spelled out.

4. **`modules/gre_config/main.tf`** — `null_resource.primary_gre_config` and `null_resource.secondary_gre_config` as separate resources.

5. **`modules/gre_config/variables.tf`** — Separate variable blocks for primary and secondary everything.

6. **`modules/aws_ec2/gateway.tf`** — `aws_instance.netskope_sdwan_gw_instance` (primary) and `aws_instance.netskope_sdwan_ha_gw_instance` (secondary, `count = ha_enabled ? 1 : 0`).

### What Would Need to Change for N Gateways

Refactor from paired resources to a `for_each` pattern over a list/map of gateways:

1. **Define a gateway list variable** — replace the primary/secondary split with something like:
   ```hcl
   variable "gateways" {
     type = map(object({
       inside_cidr = string
       zone        = string
       bgp_metric  = string
       # ...
     }))
   }
   ```

2. **`modules/aws_vpc/aws_bgp_peer.tf`** — Convert to `for_each = var.gateways` on a single `aws_ec2_transit_gateway_connect_peer` resource.

3. **`modules/aws_vpc/interfaces.tf`** — The ENIs already use `for_each` on interface names, but they'd need a per-gateway dimension added.

4. **`modules/aws_ec2/gateway.tf`** — Single `aws_instance` resource with `for_each = var.gateways`.

5. **`modules/gre_config/main.tf`** — Single `null_resource` with `for_each = var.gateways`, passing the per-gateway GRE + BGP params.

6. **`modules/nsg_config/`** — Would need to register N gateways via the Netskope API instead of just primary + optional secondary.

The SSM document itself doesn't change — it's already parameterized and gateway-agnostic. You'd just invoke it N times with different parameters.

### AWS Constraint

All gateways currently share a **single TGW Connect attachment** (`aws_ec2_transit_gateway_connect`). AWS allows up to 5 Connect Peers per Connect attachment, so you could have up to 5 gateways on one Connect. Beyond that you'd need additional Connect attachments.
