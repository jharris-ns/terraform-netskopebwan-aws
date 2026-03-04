# Troubleshooting

## Connecting to a Gateway

All gateway diagnostics start by connecting via SSM:

```sh
aws ssm start-session --target <instance-id> --region <region>
```

If SSM is unavailable, use SSH (requires a key pair in `var.aws_network_config`):

```sh
ssh -i <key.pem> infiot@<eip>
```

## Diagnostic Flowchart: Servers Cannot Reach Internet

This flowchart follows the traffic path from spoke VPC to internet. Start at Step 1 and work forward — each step assumes the previous one passes.

### Step 1: Check TGW Route Table for Default Route

The spoke VPC's TGW route table must contain a `0.0.0.0/0` route pointing at a Connect attachment. Without this, spoke traffic has no path to the gateway.

```sh
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id <tgw-rtb-id> \
  --filters "Name=state,Values=active" \
  --region <region>
```

**Pass** — `0.0.0.0/0` active and propagated via Connect attachments (two gateways in this example):
```json
{
    "Routes": [
        {
            "DestinationCidrBlock": "0.0.0.0/0",
            "TransitGatewayAttachments": [
                {
                    "ResourceId": "tgw-connect-peer-0bc92acde3f6be108(169.254.100.10 | 169.254.100.11)",
                    "TransitGatewayAttachmentId": "tgw-attach-098e6cd5b4fec48f0",
                    "ResourceType": "connect"
                },
                {
                    "ResourceId": "tgw-connect-peer-0d4e809c1412edcb7(169.254.100.2 | 169.254.100.3)",
                    "TransitGatewayAttachmentId": "tgw-attach-0678069986d8d7852",
                    "ResourceType": "connect"
                }
            ],
            "Type": "propagated",
            "State": "active"
        },
        {
            "DestinationCidrBlock": "10.100.0.0/16",
            "TransitGatewayAttachments": [
                {
                    "ResourceId": "vpc-08ca86f3ffef9fe03",
                    "TransitGatewayAttachmentId": "tgw-attach-0c8453e5a81175a07",
                    "ResourceType": "vpc"
                }
            ],
            "Type": "propagated",
            "State": "active"
        }
    ]
}
```

Note the `0.0.0.0/0` route has two Connect attachments — this is ECMP across two gateways. Each attachment's `ResourceId` shows the Connect Peer and its inside CIDR pair. The `10.100.0.0/16` route is the VPC attachment providing return-path connectivity to the gateway subnets.

**Fail**: The `0.0.0.0/0` route is missing, `blackhole`, or has zero Connect attachments.

**If failing, check Connect Peer state** — both peers should show `available`:

```sh
aws ec2 describe-transit-gateway-connect-peers --region <region> \
  --output table \
  --query 'TransitGatewayConnectPeers[*].{Peer:TransitGatewayConnectPeerId,State:State,Attachment:TransitGatewayAttachmentId,InsideCidr:ConnectPeerConfiguration.InsideCidrBlocks}'
```

**Pass** — both Connect Peers `available` with correct inside CIDRs:
```
-------------------------------------------------------------------------------------
|                        DescribeTransitGatewayConnectPeers                         |
+-------------------------------+--------------------------------------+------------+
|          Attachment           |                Peer                  |   State    |
+-------------------------------+--------------------------------------+------------+
|  tgw-attach-098e6cd5b4fec48f0 |  tgw-connect-peer-0bc92acde3f6be108  |  available |
+-------------------------------+--------------------------------------+------------+
||                                   InsideCidr                                    ||
|+---------------------------------------------------------------------------------+|
||  169.254.100.8/29                                                               ||
|+---------------------------------------------------------------------------------+|
|                        DescribeTransitGatewayConnectPeers                         |
+-------------------------------+--------------------------------------+------------+
|          Attachment           |                Peer                  |   State    |
+-------------------------------+--------------------------------------+------------+
|  tgw-attach-0678069986d8d7852 |  tgw-connect-peer-0d4e809c1412edcb7  |  available |
+-------------------------------+--------------------------------------+------------+
||                                   InsideCidr                                    ||
|+---------------------------------------------------------------------------------+|
||  169.254.100.0/29                                                               ||
|+---------------------------------------------------------------------------------+|
```

Each peer has its own Connect attachment (per-gateway ECMP model). The `InsideCidr` `/29` block provides the BGP peer IPs for the GRE tunnel — these must match the gateway's GRE tunnel configuration.

**Common causes**:
- Connect Peer not in `available` state — BGP session hasn't established yet (continue to Step 2)
- Connect attachment not associated with the route table
- Route table association points at the wrong attachment

### Step 2: Check BGP Sessions on Gateway

The gateway must have BGP sessions Established with both TGW Connect peers (eBGP) and Netskope overlay peers (iBGP). The TGW peers propagate the default route into the TGW route table.

```sh
sudo docker exec infiot_spoke vtysh -c "show ip bgp summary"
```

**Pass** — TGW peers Established:
```
Neighbor        V         AS MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
169.254.0.10    4        400     155     153        0    0    0 02:20:54            0
169.254.0.11    4        400     155     152        0    0    0 02:20:54            0
169.254.100.2   4      64512     842     841        0    0    0 02:19:36            1
169.254.100.3   4      64512     842     841        0    0    0 02:19:37            1
```

**Fail** — TGW peers stuck in Connect/Active:
```
Neighbor        V         AS MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
169.254.0.10    4        400      38      35        0    0    0 00:27:02            1
169.254.0.11    4        400      43      38        0    0    0 00:26:44            1
169.254.100.10  4      64512       0       0        0    0    0    never      Connect
169.254.100.11  4      64512       0       0        0    0    0    never      Connect
```

The `169.254.0.x` peers are Netskope SSE overlay peers (iBGP, AS 400). The `169.254.100.x` peers are TGW Connect peers (eBGP, AS 64512). If the TGW peers show `Connect` or `Active`, the GRE tunnel underlay is likely not passing traffic — continue to Step 3.

**Then check the gateway is advertising 0.0.0.0/0 to the TGW**:

```sh
# Use a TGW peer IP, not a Netskope peer
sudo docker exec infiot_spoke vtysh -c "show ip bgp neighbors <tgw-peer-ip> advertised-routes"
```

**Pass** — default route advertised:
```
   Network          Next Hop            Metric LocPrf Weight Path
*> 0.0.0.0/0        0.0.0.0                 10         32768 ?
```

**Fail** — no routes advertised. The SSE monitor has retracted the default route because no SSE tunnels are established — skip to Step 4.

**Common causes**:
- **ASN mismatch**: `tenant_bgp_asn` must match what the gateway advertises; `tgw_asn` must match the Transit Gateway.
- **Inside CIDR mismatch**: TGW Connect Peer's inside CIDR must match the gateway's GRE tunnel IPs. Check the `computed-gateway-map` output.
- **FRR container not running**: Check `sudo docker ps` — the `infiot_spoke` container must be running.

### Step 3: Check GRE Tunnel

The GRE tunnel carries BGP and data-plane traffic between the gateway and the TGW. The tunnel must be up, endpoints must be correct, and traffic must use the LAN interface.

**Check tunnel interface and endpoints**:

```sh
ip addr show gre1
ip tunnel show gre1
```

**Pass**:
```
gre1@NONE: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1300 qdisc noqueue state UNKNOWN
    link/gre 10.100.0.52 peer 10.200.0.48
    inet 169.254.100.9/29 brd 169.254.100.15 scope global gre1
```

**Fail**: Interface missing, DOWN, or endpoints wrong.

**Verify underlay routing** — GRE traffic must route via the LAN interface, not the public interface:

```sh
ip route get <tgw-gre-ip>
```

**Pass** (via LAN interface `enp2s1`):
```
10.200.0.48 via 10.100.0.17 dev enp2s1 src 10.100.0.20
```

**Fail** (via public interface `enp2s0`):
```
10.200.0.48 via 10.100.0.33 dev enp2s0 src 10.100.0.44
```

If the route goes out `enp2s0` instead of `enp2s1`, the TGW endpoint is unreachable from that path. Check the VPC route table for the LAN subnet:

```sh
# Find LAN subnet ID from CIDR
aws ec2 describe-subnets --region <region> \
  --filters "Name=cidr-block,Values=<lan-subnet-cidr>" \
  --query 'Subnets[0].SubnetId' --output text

# VPC route table for a gateway's LAN subnet
aws ec2 describe-route-tables --region <region> \
  --filters "Name=association.subnet-id,Values=<lan-subnet-id>" \
  --query 'RouteTables[*].Routes'
```

**Capture GRE packets to confirm traffic flow**:

```sh
sudo tcpdump -i enp2s1 proto gre -c 10
```

**Common causes**:
- **Wrong underlay route**: `ip route get <tgw-ip>` must route via the LAN interface (`enp2s1`). If it routes via `enp2s0`, check the LAN subnet's VPC route table — it needs a route to the TGW CIDR via the TGW.
- **Security group blocking GRE**: The LAN security group allows all traffic by default. If using a custom SG, ensure GRE (protocol 47) is permitted.
- **Physical interface mismatch**: `phy_intfname` must match the LAN interface name on the BWAN AMI (default: `enp2s1`). Verify with `ip link show`.
- **MTU issues**: Default is 1300. If seeing fragmentation, try lowering to 1200.
- **TGW Connect not active**: Check the TGW Connect attachment status in the AWS console.

### Step 4: Check SSE Tunnels (IPsec to Netskope)

The gateway establishes IPsec tunnels to Netskope NewEdge POPs. These carry the actual internet-bound traffic. The SSE monitor watches these tunnels and only advertises the default route via BGP when at least one tunnel is ESTABLISHED.

**Check IPsec tunnel state**:

```sh
sudo docker exec infiot_spoke ikectl show sa 2>/dev/null | grep "^iked_sas:.*ESTABLISHED" | wc -l
```

**Pass**: Count is >= 1. Example `ikectl show sa` output — 3 established SSE tunnels:
```
iked_sas: 0x5599... 10.100.0.4:4500->34.225.14.147:4500<UFQDN/169.254.0.10@infiot.com>[] ESTABLISHED i natt udpecap ...
  sa_childsas: ...
  sa_flows: ...
iked_sas: 0x5599... 10.100.0.4:4500->44.246.78.51:4500<UFQDN/169.254.0.11@infiot.com>[] ESTABLISHED i natt udpecap ...
  sa_childsas: ...
  sa_flows: ...
iked_sas: 0x5599... 10.100.0.4:4500->34.68.134.104:4500<UFQDN/169.254.0.1@infiot.com>[] ESTABLISHED i natt udpecap ...
  sa_childsas: ...
  sa_flows: ...
```

Note: Only `iked_sas:` lines with `ESTABLISHED` are SSE tunnels. The `iked_activesas`, `sa_childsas`, and `sa_flows` lines are child SAs and should not be counted.

**Fail**: Count is 0 — no tunnels established. The gateway cannot reach Netskope POPs.

**Check SSE monitor status**:

```sh
systemctl status sse_monitor
journalctl -u sse_monitor --no-pager -n 50
tail -50 /var/log/sse_monitor.log
```

**Common causes**:
- **No ESTABLISHED tunnels**: The monitor only advertises when at least one SSE tunnel is up. If IPsec tunnels to Netskope POPs are down, the monitor is correctly retracting the default route — the problem is upstream (Netskope activation, connectivity to POPs).
- **Docker not running**: The service requires `docker.service`. Check `systemctl status docker`.
- **Container not started**: The monitor waits for `infiot_spoke`. Check `docker ps`.
- **Wrong BGP peer IPs in JSON**: Peer IPs in the JSON files must match the TGW Connect Peer inside addresses from `terraform output computed-gateway-map`.
- **FRR JSON missing or stale**: If the JSON files weren't deployed or the script was updated, taint and re-apply:
  ```sh
  terraform taint 'null_resource.sse_monitor["<gateway-key>"]'
  terraform apply
  ```

**Verify deployed monitor files**:

```sh
ls -la /root/sse_monitor/
cat /root/sse_monitor/frrcmds-advertise-default.json
cat /root/sse_monitor/frrcmds-retract-default.json
```

### Step 5: Check Netskope Overlay Connectivity

The Netskope overlay peers (iBGP, AS 400) provide the path from the gateway to Netskope NewEdge. If SSE tunnels are up (Step 4 passes) but traffic still doesn't flow, check the overlay BGP sessions.

```sh
sudo docker exec infiot_spoke vtysh -c "show ip bgp summary"
```

Look at the `169.254.0.x` peers (not the `169.254.100.x` TGW peers). They should show `Established` with a non-zero prefix count.

**Check overlay paths inside the container**:

```sh
sudo docker exec -it infiot_spoke bash
/opt/infiot/bin/infcli.py --overlays
```

**Pass** — three overlay paths up with `LocalUP: True` and `RemoteUP: True`:
```
OverlayIP       Link      LocalIP      RemoteIP             Role   LocalUP   RemoteUP   Latency   PMTU   EncType   PathType
169.254.0.10    enp2s0   10.100.0.7   34.225.14.147   SPOKE|CONTROLLER  True    True        10   1500         0     Infiot
169.254.0.1     enp2s0   10.100.0.7   34.68.134.104        SPOKE|DC|    True    True        10   1460         0     Infiot
169.254.0.11    enp2s0   10.100.0.7    44.246.78.51   SPOKE|CONTROLLER  True    True        10   1500         0     Infiot
```

Each row is an overlay tunnel to a Netskope NewEdge POP. The `OverlayIP` matches the iBGP peer addresses from Step 2. The `RemoteIP` values are the public IPs of the NewEdge POPs — these should match the `ikectl show sa` output from Step 4.

**Fail**: No rows, or `LocalUP`/`RemoteUP` showing `False`.

**Check container interfaces** — all four should show `L2State UP` / `L3State UP`:

```sh
/opt/infiot/bin/infcli.py --show_int
```

```
Name overlay, L3Index 3, Segment 0, IP 169.254.0.13(primary)
L2State UP, L3State UP, Native FALSE

Name enp2s0, L3Index 0, Segment 0, IP 10.100.0.7(primary)
L2State UP, L3State UP, Native TRUE

Name enp2s1, L3Index 1, Segment 0, IP 10.100.0.20(primary)
L2State UP, L3State UP, Native TRUE

Name gre1, L3Index 2, Segment 0, IP 169.254.100.1(primary)
L2State UP, L3State UP, Native FALSE
```

- `enp2s0` — WAN/public interface (SSE tunnels egress here)
- `enp2s1` — LAN interface (GRE tunnel underlay to TGW)
- `gre1` — GRE tunnel to TGW (BGP peering with TGW Connect)
- `overlay` — Netskope overlay (iBGP peering with NewEdge POPs)

**Check container routing table**:

```sh
/opt/infiot/bin/infcli.py --rt
```

```
                                Route Table 0

Net/mask                Gateway         Port    l2idx   l3idx   rtype   metric
0.0.0.0/0               -               2       -       -       def     0
 - 0.0.0.0/0            10.100.0.1      10      0       0       wan     100
 - 0.0.0.0/0            10.100.0.17     11      1       1       lan     429496729
169.254.100.0/29        -               12      2       2       lan     0
10.100.0.0/28           -               10      0       0       wan     0
10.100.0.16/28          -               11      1       1       lan     0
169.254.0.0/16          -               0       3       3       lan     0
10.100.0.0/16           169.254.100.2   12      2       2       lan     20
```

Key routes to verify:
- `0.0.0.0/0` with `rtype=def` on port 2 — default route via the overlay (internet-bound traffic goes through Netskope)
- `0.0.0.0/0` with `rtype=wan` metric 100 — WAN fallback via `enp2s0` gateway (used for SSE tunnel establishment itself)
- `10.100.0.0/16` via `169.254.100.2` on port 12 — VPC CIDR learned via BGP over the GRE tunnel (return path to spoke VPCs)
- `169.254.0.0/16` on l3idx 3 — overlay connected route (Netskope iBGP peering)

If the `10.100.0.0/16` route via the GRE tunnel is missing, the gateway has no return path to spoke VPCs — check that the TGW is advertising the VPC CIDR to the gateway's BGP peers (Step 2).

## Deployment Issues

### SSM Agent Not Ready

**Symptom**: `terraform apply` hangs or fails at `null_resource.gre_config` with "SSM agent not online" errors.

**Cause**: The SSM agent is installed via user-data on first boot and may not be ready when the GRE configuration step runs.

**Resolution**: The `gre_config` provisioner polls for readiness (30 retries × 10s = up to 5 minutes). Verify:
- The instance has internet access via the EIP on ge1 (needed to download the SSM agent from S3)
- SSM VPC endpoints are created and associated with the correct subnets/security groups
- The IAM instance profile (`*-netskope-gw-ssm-profile`) is attached

```sh
# Check SSM agent status from your workstation
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=<instance-id>" \
  --region <region>

# If agent never comes online, connect via SSH and check locally
sudo systemctl status amazon-ssm-agent
sudo journalctl -u amazon-ssm-agent
```

### Provider Authentication Errors

**Symptom**: `Error: failed to authenticate` from the `netskopebwan` provider.

**Causes**: Invalid/expired `tenant_token`, incorrect `tenant_url` (the provider derives the API URL by inserting `.api` into the hostname), or network connectivity to `https://<tenant>.api.infiot.net`.

```sh
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer <token>" \
  "https://<tenant>.api.infiot.net/api/v1/policy"
```

### Terraform Destroy Failures

**Symptom**: `terraform destroy` fails with dependency errors.

**Common causes**: Resources manually added to the VPC/TGW, ENIs in use by other services, or TGW Connect Peers still attached.

**Resolution**: Remove manually-created resources first. If stuck, destroy in reverse dependency order:

```sh
terraform destroy -target=null_resource.gre_config
terraform destroy -target=aws_instance.gateways
terraform destroy -target=netskopebwan_gateway.gateways
terraform destroy -target=aws_vpc.this
```

### IMDS Unreachable After Activation

**Symptom**: SSM commands fail with `context deadline exceeded` errors. The SSM agent reports Online but cannot execute documents.

**Cause**: The `infiot_spoke` container creates an overlay interface with a `169.254.0.0/16` connected route that captures IMDS traffic (`169.254.169.254`). The SSM agent cannot refresh IAM credentials without IMDS access.

**Diagnostic steps**:

```sh
ip route get 169.254.169.254
# Expected: 169.254.169.254 dev enp2s0 src <primary-ip>
# Broken:   169.254.169.254 dev overlay src 169.254.0.x

curl -s -m 5 http://169.254.169.254/latest/meta-data/instance-id
tail -20 /var/log/amazon/ssm/errors.log
```

**Resolution**: The `user-data.sh` script adds a `/32` host route for `169.254.169.254` pinned to the primary ENI at boot. If this route is missing (e.g., on instances deployed before the fix):

```sh
PRIMARY_ENI=$(ip -o link show | awk -F': ' '/^2:/{print $2}')
ip route add 169.254.169.254/32 dev "$PRIMARY_ENI"
curl -s http://169.254.169.254/latest/meta-data/instance-id   # verify
```

Instances deployed before this fix require a redeploy (`terraform destroy` + `terraform apply`) for the user-data change to take effect.

## Gateway Commands Quick Reference

Commands run on the gateway host after connecting via SSM.

### Network

```sh
ip -br a                                    # interfaces summary
ip route                                    # system routing table
ip neighbor                                 # ARP table
ping <dest-ip> -I <interface-ip>            # ping with source interface
ethtool <interface>                         # link status and duplex
```

### Gateway Management

```sh
infhostd version                            # firmware version
infhostd upgrade -displayname R5.3.97       # upgrade firmware
infhostd restart-container infiot_spoke      # restart BWAN container
reboot                                      # full reboot (2-5 min downtime)
```

### Container Diagnostics (without entering container)

```sh
sudo docker exec infiot_spoke vtysh -c "show ip bgp summary"
sudo docker exec infiot_spoke vtysh -c "show ip bgp neighbors <peer-ip> advertised-routes"
sudo docker exec infiot_spoke ikectl show sa 2>/dev/null | grep "^iked_sas:.*ESTABLISHED" | wc -l
```

### Container Diagnostics (inside container)

```sh
sudo docker exec -it infiot_spoke bash
/opt/infiot/bin/infcli.py --overlays        # overlay paths and SSE/IPSEC tunnels
/opt/infiot/bin/infcli.py --show_int        # interfaces
/opt/infiot/bin/infcli.py --rt              # routing table
```

### Flow Inspection

```sh
infhostd click-dump --help                  # show flows (pipe to grep for filtering)
```

## Known Limitations

1. **Gateway count**: Each gateway requires its own TGW Connect attachment. AWS applies a default limit of 5,000 Connect attachments per TGW, but each VPC attachment supports up to 4 Connect attachments — so `gateway_count` cannot exceed 4 per deployment. Request a quota increase if needed for multiple deployments sharing the same TGW.
2. **Single policy**: All gateways share one Netskope policy (`gateway_policy`). Per-gateway policy assignment is not supported.
3. **Existing VPC attachment**: When reusing an existing VPC and TGW, the VPC attachment subnet list may need manual updates due to an AWS API limitation.
4. **SSM dependency**: GRE/BGP configuration requires SSM Agent connectivity. If the agent fails to start, the deployment will time out.
5. **Sequential GRE configuration**: The `local-exec` provisioner for GRE config runs sequentially per gateway.
6. **Provider version pinning**: The `netskopebwan` provider is pinned to `0.0.2`. Newer versions may introduce breaking changes.
7. **IMDS route hijacking**: The Netskope overlay interface (`169.254.0.0/16`) captures IMDS traffic post-activation. The `user-data.sh` host route fix mitigates this, but firmware updates that change overlay addressing may require adjustment.
8. **SSE monitor requires container**: The monitor depends on `infiot_spoke` with `ikectl` available. Firmware updates that move/rename `ikectl` will break tunnel checks.
