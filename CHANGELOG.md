# Changelog

#
This tells tar to skip setting ownership and permissions on directories that already exist on the target. New directories are still created as needed, but existing ones like `/root` are left untouched. File contents are extracted normally.

## 2026-04-16 — Persistent EIPs Across Gateway Recreation

### Problem

Elastic IPs were allocated inline on the `aws_eip` resource with a direct `network_interface` binding. This tied the EIP lifecycle to the ENI, meaning that if a gateway was destroyed and recreated, the EIP could be released and a new one allocated — breaking any external whitelisting that depends on stable public IPs.

### Fix

Separated EIP allocation from ENI association in `interfaces.tf`:

- **`aws_eip.gw_eips`** — now allocates EIPs without any `network_interface` binding. Added `lifecycle { prevent_destroy = true }` to guard against accidental release during `terraform destroy`. Replaced deprecated `vpc = true` attribute (kept for AWS provider v4.x compatibility).
- **`aws_eip_association.gw_eip_assoc`** (new resource) — handles the binding between EIP and ENI. This is the only resource destroyed/recreated when a gateway changes.

### Behaviour

| Action | EIP | ENI | Instance |
|---|---|---|---|
| Destroy & recreate a gateway | Preserved | Preserved | New instance, same IPs |
| `terraform destroy` (full) | Blocked by `prevent_destroy` | Destroyed | Destroyed |

To perform a full teardown, temporarily comment out the `lifecycle` block on `aws_eip.gw_eips` or use `terraform state rm` to detach the EIPs from state.

### Tested

- Deployed 2 gateways, recorded EIP `18.202.132.219` on GW1
- Tainted `aws_instance.gateways["aws-irl-gw-1"]` to force destroy/recreate
- After apply: new instance ID, same EIP, BGP sessions up on both peers

## 2026-04-08 — Fix BGP Default Route Leak via Redistribute

### Gateway 3 BGP Default Route Leak — Root Cause and Fix

When gateway 3 was deployed, it began advertising a default route (`0.0.0.0/0`) to the Transit Gateway via BGP even though its SSE tunnels had not yet established, creating a traffic blackhole.

### Root Cause

The root cause was in the existing FRR BGP configuration. The gateway redistributes kernel routes into BGP via:

```
redistribute kernel route-map advertise
redistribute connected route-map advertise
redistribute static route-map advertise
```

The `advertise` route-map at sequence 10 matches `ip address prefix-list default`, which permits `0.0.0.0/0` — the kernel default route pointing to the LAN gateway (e.g. `10.100.0.65`):

```
route-map advertise permit 10
  match ip address prefix-list default

ip prefix-list default seq 5 permit 0.0.0.0/0
```

The outbound route-map applied to TGW peers had no match clause, meaning it permitted all prefixes including the redistributed default route:

```
neighbor 169.254.100.18 route-map set-med-peer out
neighbor 169.254.100.19 route-map set-med-peer out

route-map set-med-peer permit 10
  set metric 10
```

The intended mechanism for controlled default route advertisement is the `neighbor <peer> default-originate` command, which the SSE monitor script toggles based on IPsec tunnel health. However, because the redistribute path was unfiltered through `set-med-peer`, gateways would advertise `0.0.0.0/0` to the TGW regardless of the SSE monitor state.

### Fix

We added a new deny rule ahead of the existing permit in the `set-med-peer` route-map:

```
route-map set-med-peer deny 5
  match ip address prefix-list default
route-map set-med-peer permit 10
  set metric 10
```

This blocks the redistributed `0.0.0.0/0` from being sent to TGW peers while still allowing all other prefixes (like `10.100.0.0/16`) through via the existing permit at sequence 10. Since `default-originate` operates independently of outbound route-map filtering in FRR, the SSE monitor can still advertise and retract the default route as designed.

The block rule is injected via a new FRR command file (`frrcmds-block-default-redistribute.json`) that the SSE monitor applies once after each FRR stabilization period on container start, ensuring the protection is in place from boot before any tunnel health checks begin.
