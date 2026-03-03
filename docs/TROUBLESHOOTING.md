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

## Common Issues

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

### BGP / GRE Tunnel Not Working

**Symptom**: `gre_config` completes but BGP peers don't reach Established state, or the GRE tunnel exists but no traffic passes.

**Step 1 — Check BGP state**:

```sh
sudo docker exec infiot_spoke vtysh -c "show ip bgp summary"
```

Working output (TGW peers Established):
```
Neighbor        V         AS MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
169.254.0.10    4        400     155     153        0    0    0 02:20:54            0
169.254.0.11    4        400     155     152        0    0    0 02:20:54            0
169.254.100.2   4      64512     842     841        0    0    0 02:19:36            1
169.254.100.3   4      64512     842     841        0    0    0 02:19:37            1
```

Broken output (TGW peers stuck in Connect):
```
Neighbor        V         AS MsgRcvd MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd
169.254.0.10    4        400      38      35        0    0    0 00:27:02            1
169.254.0.11    4        400      43      38        0    0    0 00:26:44            1
169.254.100.10  4      64512       0       0        0    0    0    never      Connect
169.254.100.11  4      64512       0       0        0    0    0    never      Connect
```

The `169.254.0.x` peers are Netskope SSE overlay peers (iBGP, AS 400). The `169.254.100.x` peers are TGW Connect peers (eBGP, AS 64512). If the TGW peers show `Connect` or `Active`, the GRE tunnel underlay is likely not passing traffic.

**Step 2 — Check GRE tunnel**:

```sh
# Tunnel interface and endpoints
ip addr show gre1
ip tunnel show gre1

# Expected output:
# gre1@NONE: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1300 qdisc noqueue state UNKNOWN
#     link/gre 10.100.0.52 peer 10.200.0.48
#     inet 169.254.100.9/29 brd 169.254.100.15 scope global gre1
```

**Step 3 — Verify underlay routing** (GRE traffic must use the LAN interface):

```sh
ip route get <tgw-gre-ip>

# Working (via LAN interface enp2s1):
#   10.200.0.48 via 10.100.0.17 dev enp2s1 src 10.100.0.20

# Broken (via public interface enp2s0):
#   10.200.0.48 via 10.100.0.33 dev enp2s0 src 10.100.0.44
```

If the route goes out `enp2s0` instead of `enp2s1`, the TGW endpoint is unreachable from that path. Check the VPC route table for the LAN subnet.

```sh
# Capture GRE packets on the LAN interface
sudo tcpdump -i enp2s1 proto gre -c 10
```

**Step 4 — Check advertised routes**:

```sh
# Use a TGW peer IP, not a Netskope peer
sudo docker exec infiot_spoke vtysh -c "show ip bgp neighbors <tgw-peer-ip> advertised-routes"

# Expected — default route being advertised:
#    Network          Next Hop            Metric LocPrf Weight Path
# *> 0.0.0.0/0        0.0.0.0                 10         32768 ?
```

**Step 5 — AWS-side diagnostics**:

```sh
# TGW route table — active routes
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id <tgw-rtb-id> \
  --filters "Name=state,Values=active" \
  --region <region>

# TGW Connect Peer state and BGP config
aws ec2 describe-transit-gateway-connect-peers --region <region> \
  --output table \
  --query 'TransitGatewayConnectPeers[*].{Peer:TransitGatewayConnectPeerId,State:State,Attachment:TransitGatewayAttachmentId,InsideCidr:ConnectPeerConfiguration.InsideCidrBlocks}'

# VPC route table for a gateway's LAN subnet
aws ec2 describe-route-tables --region <region> \
  --filters "Name=association.subnet-id,Values=<lan-subnet-id>" \
  --query 'RouteTables[*].Routes'

# Find LAN subnet ID from CIDR
aws ec2 describe-subnets --region <region> \
  --filters "Name=cidr-block,Values=<lan-subnet-cidr>" \
  --query 'Subnets[0].SubnetId' --output text
```

**Common causes**:
- **Inside CIDR mismatch**: TGW Connect Peer's inside CIDR must match the gateway's GRE tunnel IPs. Check the `computed-gateway-map` output.
- **ASN mismatch**: `tenant_bgp_asn` must match what the gateway advertises; `tgw_asn` must match the Transit Gateway.
- **Security group blocking**: The LAN security group allows all traffic by default. If using a custom SG, ensure GRE (protocol 47) is permitted.
- **Wrong underlay route**: `ip route get <tgw-ip>` must route via the LAN interface (`enp2s1`). If it routes via `enp2s0`, check the LAN subnet's VPC route table — it needs a route to the TGW CIDR via the TGW.
- **MTU issues**: Default is 1300. If seeing fragmentation, try lowering to 1200.
- **Physical interface mismatch**: `phy_intfname` must match the LAN interface name on the BWAN AMI (default: `enp2s1`). Verify with `ip link show`.
- **FRR container not running**: Check `sudo docker ps` — the `infiot_spoke` container must be running.
- **TGW Connect not active**: Check the TGW Connect attachment status in the AWS console.

### SSE Monitor Issues

**Symptom**: `systemctl status sse_monitor` shows inactive/failed, or the monitor is active but the default route is not advertised.

**Diagnostic steps**:

```sh
# Service status and logs
systemctl status sse_monitor
journalctl -u sse_monitor --no-pager -n 50
tail -50 /var/log/sse_monitor.log

# Check SSE tunnel count manually
sudo docker exec infiot_spoke ikectl show sa 2>/dev/null | grep "^iked_sas:.*ESTABLISHED" | wc -l

# Check advertised routes to TGW peers
sudo docker exec infiot_spoke vtysh -c "show ip bgp neighbors <tgw-peer-ip> advertised-routes"

# Verify deployed files
ls -la /root/sse_monitor/
cat /root/sse_monitor/frrcmds-advertise-default.json
cat /root/sse_monitor/frrcmds-retract-default.json
```

Example `ikectl show sa` output — 3 established SSE tunnels:
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

**Common causes**:
- **Docker not running**: The service requires `docker.service`. Check `systemctl status docker`.
- **Container not started**: The monitor waits for `infiot_spoke`. Check `docker ps`.
- **No ESTABLISHED tunnels**: The monitor only advertises when at least one SSE tunnel is up. If IPsec tunnels to Netskope POPs are down, this is expected — the monitor is correctly retracting the default route.
- **Wrong BGP peer IPs in JSON**: Peer IPs in the JSON files must match the TGW Connect Peer inside addresses from `terraform output computed-gateway-map`.
- **FRR JSON missing or stale**: If the JSON files weren't deployed or the script was updated, taint and re-apply:
  ```sh
  terraform taint 'null_resource.sse_monitor["<gateway-key>"]'
  terraform apply
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

### Provider Authentication Errors

**Symptom**: `Error: failed to authenticate` from the `netskopebwan` provider.

**Causes**: Invalid/expired `tenant_token`, incorrect `tenant_url` (the provider derives the API URL by inserting `.api` into the hostname), or network connectivity to `https://<tenant>.api.infiot.net`.

```sh
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer <token>" \
  "https://<tenant>.api.infiot.net/api/v1/policy"
```

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

1. **Gateway count limit**: ECMP requires a separate TGW Connect attachment per gateway. AWS limits each VPC attachment to 4 Connect attachments, so `gateway_count` cannot exceed 4.
2. **Single policy**: All gateways share one Netskope policy (`gateway_policy`). Per-gateway policy assignment is not supported.
3. **Existing VPC attachment**: When reusing an existing VPC and TGW, the VPC attachment subnet list may need manual updates due to an AWS API limitation.
4. **SSM dependency**: GRE/BGP configuration requires SSM Agent connectivity. If the agent fails to start, the deployment will time out.
5. **Sequential GRE configuration**: The `local-exec` provisioner for GRE config runs sequentially per gateway.
6. **Provider version pinning**: The `netskopebwan` provider is pinned to `0.0.2`. Newer versions may introduce breaking changes.
7. **IMDS route hijacking**: The Netskope overlay interface (`169.254.0.0/16`) captures IMDS traffic post-activation. The `user-data.sh` host route fix mitigates this, but firmware updates that change overlay addressing may require adjustment.
8. **SSE monitor requires container**: The monitor depends on `infiot_spoke` with `ikectl` available. Firmware updates that move/rename `ikectl` will break tunnel checks.
