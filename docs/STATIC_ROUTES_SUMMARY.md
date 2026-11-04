# Static Routes: Issue, Approaches, and Current State

## The Problem

Netskope BWAN gateways need static routes to reach the TGW (for GRE/BGP) and downstream VPC/on-prem CIDRs via the LAN interface. Two separate issues surfaced:

1. **Static routes via the Netskope provider didn't persist.** The `netskopebwan_gateway_staticroute` resource had a provider bug — `Read` returned nulls, so routes never survived in Terraform state. Every `plan` showed drift and routes were unreliable.

2. **BGP sessions failed due to policy routing.** The Netskope agent creates a policy routing table (table 101) with a default route via the WAN interface. GRE outer packets sourced from the LAN IP were being sent out the WAN interface instead of LAN, breaking the GRE tunnel to the TGW and killing BGP.

## Approaches Tried

| Commit | Approach | Outcome |
|--------|----------|---------|
| `a572a8e` | Updated example tfvars to document static routes | Docs-only; no functional change |
| `c471466` | **Moved static routes from Netskope provider to Linux `ip route` commands via SSM.** Removed `netskopebwan_gateway_staticroute.aws_cidrs`. Routes now installed in both main and table 101 during the GRE config SSM step. Also added TGW CIDR route to table 101 to fix the GRE-over-WAN policy routing issue. | Core fix — routes persist at the OS level and survive provider bugs |
| `b54139d` | Added BGP `set-med-peer` route-map deny rule to block redistributed `0.0.0.0/0` from leaking to TGW peers. Applied via SSE monitor on container start. Also migrated security groups to standalone `aws_vpc_security_group_*_rule` resources. | Fixed a separate BGP default-route blackhole on new gateway boot |

## Current State

- **Static routes** are installed via the SSM GRE config script as Linux routes (`ip route replace`) in both the main table and table 101. The Netskope provider static route resource is no longer used.
- **`static_routes` defaults to `[]`** — users must explicitly list the TGW CIDR and any VPC/on-prem CIDRs reachable via the TGW.
- **TGW CIDR** is automatically added to table 101 to ensure GRE outer packets route via LAN, not WAN.
- **BGP default route leak** is blocked by a deny rule in the `set-med-peer` route-map, applied by the SSE monitor after FRR stabilization on each container start.
- **MTU** is now configurable: `wan_mtu` (default 1500) for overlay interfaces, `gre_mtu` (default 1300) for the GRE tunnel.
- **LAN interface** no longer gets a default gateway in the Netskope config — traffic is routed via explicit static routes only.