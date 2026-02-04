# Architecture

## Network Topology

```
                    ┌──────────────────────────────────────┐
                    │       Netskope SD-WAN Portal         │
                    │  (Policy, Gateways, BGP, Activation) │
                    └──────────┬───────────────────────────┘
                               │ REST API (netskopebwan provider)
                               │
    ┌──────────────────────────┼──────────────────────────────────────┐
    │  AWS Region              │                                      │
    │                          │                                      │
    │  ┌───────────────────────▼─────────────────────────────────┐   │
    │  │  VPC (vpc_cidr)                                         │   │
    │  │                                                         │   │
    │  │  ┌─────────────────┐    ┌─────────────────┐             │   │
    │  │  │  GW-1 (AZ-a)   │    │  GW-2 (AZ-b)   │  ...        │   │
    │  │  │  ┌───────────┐  │    │  ┌───────────┐  │             │   │
    │  │  │  │ ge1 (WAN) │◄─┼──EIP─┤ ge1 (WAN) │◄─┼──EIP       │   │
    │  │  │  │ Public SG  │  │    │  │ Public SG  │  │             │   │
    │  │  │  └───────────┘  │    │  └───────────┘  │             │   │
    │  │  │  ┌───────────┐  │    │  ┌───────────┐  │             │   │
    │  │  │  │ ge2 (LAN) │  │    │  │ ge2 (LAN) │  │             │   │
    │  │  │  │ Private SG │  │    │  │ Private SG │  │             │   │
    │  │  │  └─────┬─────┘  │    │  └─────┬─────┘  │             │   │
    │  │  │    GRE │tunnel   │    │    GRE │tunnel   │             │   │
    │  │  └────────┼────────┘    └────────┼────────┘             │   │
    │  │           │                      │                       │   │
    │  │  ┌────────▼──────────────────────▼──────────────────┐   │   │
    │  │  │  TGW VPC Attachment (one LAN subnet per AZ)      │   │   │
    │  │  └──────────────────────┬────────────────────────────┘   │   │
    │  └─────────────────────────┼───────────────────────────────┘   │
    │                            │                                    │
    │  ┌─────────────────────────▼────────────────────────────────┐  │
    │  │  Transit Gateway (tgw_asn)                                │  │
    │  │  ├── TGW Connect (GRE protocol)                          │  │
    │  │  │   ├── Connect Peer GW-1 (BGP AS tenant_bgp_asn)      │  │
    │  │  │   ├── Connect Peer GW-2 (BGP AS tenant_bgp_asn)      │  │
    │  │  │   └── ...                                              │  │
    │  │  └── Route propagation via BGP                            │  │
    │  └─────────────────────────┬────────────────────────────────┘  │
    │                            │ (optional)                         │
    │  ┌─────────────────────────▼────────────────────────────────┐  │
    │  │  Client VPC (optional, for testing)                       │  │
    │  │  - Default route → TGW                                   │  │
    │  │  - Ubuntu EC2 instance                                   │  │
    │  └──────────────────────────────────────────────────────────┘  │
    │                                                                 │
    │  SSM VPC Endpoints: ssm, ssmmessages, ec2messages              │
    └─────────────────────────────────────────────────────────────────┘
```

## Traffic Flow

1. **Outbound (Client → Internet)**: Client VPC → TGW → BGP route to GW → GRE tunnel → Netskope gateway → ge1 (WAN) → Internet via IGW
2. **Inbound management**: Operator → EIP → ge1 (SSH) or SSM Session Manager
3. **GRE underlay**: GW ge2 (LAN IP) ↔ TGW Connect Peer (TGW IP) over the VPC attachment
4. **BGP control plane**: FRR on each gateway peers with TGW over the GRE tunnel's inside CIDR

## File Responsibilities

| File | Purpose | Key References |
|---|---|---|
| `vpc.tf` | VPC, subnets, IGW, route tables, security groups, TGW, TGW Connect, SSM endpoints | `local.gateways`, `var.aws_network_config`, `var.aws_transit_gw` |
| `interfaces.tf` | ENIs and EIPs (per gateway x interface) | `local.gateway_subnets`, `local.gw_public_interfaces` |
| `bgp_peer.tf` | TGW Connect Peers (one per gateway with a LAN interface) | `local.gw_lan_key`, ENI private IPs |
| `nsg_config.tf` | Netskope portal: policy, gateways, interfaces, static routes, activation, BGP config | `local.gateways`, ENI private IPs, `var.netskope_gateway_config` |
| `ec2.tf` | EC2 instances with user-data (activation + SSM agent install) | `local.gateways`, ENI IDs, activation tokens, `var.aws_instance` |
| `gre_config.tf` | SSM document for GRE/BGP setup, SSM command execution per gateway | EC2 instance IDs, ENI LAN IPs, TGW peer addresses |
| `clients.tf` | Optional client VPC + EC2 + TGW attachment for testing | `var.clients`, `local.tgw` |
| `iam.tf` | IAM role + instance profile for SSM access | `var.netskope_gateway_config` |

## Resource Inventory

### AWS Resources (per deployment)

| Resource | Count | Notes |
|---|---|---|
| VPC | 0–1 | Conditional (`create_vpc`) |
| Internet Gateway | 0–1 | Created with VPC |
| Subnets | 2 × gateway_count | Public (WAN) + Private (LAN) per gateway |
| Route Tables | 2 | Public (→ IGW) and Private (→ TGW) |
| Security Groups | 3 | Public, Private, SSM endpoint |
| Transit Gateway | 0–1 | Conditional (`create_transit_gw`) |
| TGW VPC Attachment | 1 | One LAN subnet per AZ |
| TGW Connect | 1 | GRE protocol over VPC attachment |
| TGW Connect Peers | gateway_count | One per gateway |
| ENIs | 2 × gateway_count | ge1 + ge2 per gateway |
| Elastic IPs | gateway_count | One per WAN interface |
| EC2 Instances | gateway_count | Netskope BWAN gateway AMI |
| SSM VPC Endpoints | 3 | ssm, ssmmessages, ec2messages |
| IAM Role + Profile | 1 | SSM access for gateways |
| SSM Document | 1 | Shared GRE config document |
| Client VPC + EC2 | 0–1 | Optional |

### Netskope Portal Resources

| Resource | Count | Notes |
|---|---|---|
| Policy | 1 | Shared across all gateways |
| Gateway | gateway_count | One per deployed gateway |
| Gateway Interface | 2 × gateway_count | ge1 + ge2 per gateway |
| Static Route | gateway_count | EC2 metadata route (169.254.169.254) |
| BGP Config | 2 × gateway_count | Two TGW peers per gateway |

## GRE / BGP Tunnel Design

### GRE Tunnels

Each gateway establishes a GRE tunnel between its LAN interface (ge2) and the TGW Connect Peer:

- **Local endpoint**: Gateway ge2 private IP (LAN subnet)
- **Remote endpoint**: TGW Connect Peer address (from `tgw_cidr`)
- **Interface name**: `gre1`
- **Physical underlay**: `enp2s1` (configurable via `phy_intfname`)
- **MTU**: 1300 (accounts for GRE + outer IP overhead)

### Inside CIDR Addressing

Each gateway gets a `/29` block carved from `inside_cidr_base` (default `169.254.100.0/24`).

**AWS TGW Connect Peer constraints on inside CIDRs:**
- Must be from the `169.254.0.0/16` link-local range
- Each peer's `/29` must not overlap with other Connect Peers on the same TGW
- Avoid `169.254.169.0/24` (EC2 instance metadata) and `169.254.170.0/24` (reserved by AWS)

| Gateway | Inside CIDR | GW IP (.1) | TGW Peer 1 (.2) | TGW Peer 2 (.3) |
|---|---|---|---|---|
| gw-1 | 169.254.100.0/29 | 169.254.100.1 | 169.254.100.2 | 169.254.100.3 |
| gw-2 | 169.254.100.8/29 | 169.254.100.9 | 169.254.100.10 | 169.254.100.11 |
| gw-3 | 169.254.100.16/29 | 169.254.100.17 | 169.254.100.18 | 169.254.100.19 |
| gw-4 | 169.254.100.24/29 | 169.254.100.25 | 169.254.100.26 | 169.254.100.27 |

### BGP Configuration (FRR)

- **Gateway ASN**: `tenant_bgp_asn` (default: 400)
- **TGW ASN**: `tgw_asn` (default: 64512) — must be a private ASN (16-bit: 1–65534 or 32-bit: 131072–4199999999); AWS reserves 7224 and 9059; must not equal `tenant_bgp_asn`
- **Peers per gateway**: 2 (both TGW Connect Peer inside IPs)
- **MED (Multi-Exit Discriminator)**: `0` for all gateways — equal cost enables ECMP across all paths
- **Features**: `default-originate`, `ebgp-multihop 2`, `disable-connected-check`
- **Community**: `47474:47474` for HA signaling (denied inbound, set outbound)

## Security Layers

### Security Groups

| Security Group | Direction | Rule | Purpose |
|---|---|---|---|
| Public (WAN) | Ingress | TCP/22 from 0.0.0.0/0 | SSH management |
| Public (WAN) | Ingress | UDP/4500 from 0.0.0.0/0 | IPSec NAT-T |
| Public (WAN) | Ingress | TCP/2000+N from 0.0.0.0/0 | Client port forwarding |
| Public (WAN) | Egress | All | Outbound connectivity |
| Private (LAN) | Ingress | All from 0.0.0.0/0 | Trusted LAN |
| Private (LAN) | Egress | All | Trusted LAN |
| SSM Endpoint | Ingress | TCP/443 from VPC CIDR | SSM API access |

### IAM

- Gateway EC2 instances have an instance profile with `AmazonSSMManagedInstanceCore` policy
- This allows SSM Agent communication but no other AWS API access from the gateways

### SSM VPC Endpoints

Three interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) are created in the VPC to allow SSM communication without requiring internet access from the gateway instances during GRE configuration.

## Provider Versions

| Provider | Source | Version | Purpose |
|---|---|---|---|
| `aws` | hashicorp/aws | ~> 4.30 | AWS infrastructure |
| `netskopebwan` | netskopeoss/netskopebwan | 0.0.2 | Netskope portal configuration |
| `time` | hashicorp/time | ~> 0.7.2 | API propagation delays |
| `utils` | cloudposse/utils | unpinned | Utility functions |
| Terraform | — | >= 0.13 | Core |
