# Troubleshooting

## Common Issues

### SSM Agent Not Ready

**Symptom**: `terraform apply` hangs or fails at `null_resource.gre_config` with "SSM agent not online" errors.

**Cause**: The SSM agent is installed via user-data on first boot. It may not be ready when the GRE configuration step runs.

**Resolution**:
- The `gre_config` provisioner polls for SSM agent readiness (30 retries × 10 seconds = up to 5 minutes). Ensure the instance has internet access via the EIP on ge1 to download the SSM agent package from S3.
- Verify the SSM VPC endpoints are created and associated with the correct subnets and security groups.
- Check that the IAM instance profile (`*-netskope-gw-ssm-profile`) is attached to the instance.

```sh
# Check SSM agent status
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=<instance-id>" \
  --region <region>
```

If the agent never comes online:
```sh
# Connect via SSH (if key pair was provided) and check
ssh -i <key.pem> infiot@<eip>
sudo systemctl status amazon-ssm-agent
sudo journalctl -u amazon-ssm-agent
```

### BGP Not Establishing

**Symptom**: `gre_config` completes but BGP peers don't reach Established state.

**Diagnostic steps**:

```sh
# Connect to the gateway via SSM
aws ssm start-session --target <instance-id> --region <region>

# Check BGP state (inside infiot_spoke container)
sudo docker exec -it infiot_spoke vtysh -c "show bgp summary"

# Check GRE tunnel interface (inside infiot_spoke container)
sudo docker exec -it infiot_spoke vtysh -c "show interface gre1"

# Verify IP addressing on GRE tunnel (on host)
ip addr show gre1
```

**Common causes**:
- **Inside CIDR mismatch**: Verify the TGW Connect Peer's inside CIDR matches the gateway's GRE tunnel IPs. Check the `computed-gateway-map` output.
- **ASN mismatch**: Ensure `tenant_bgp_asn` matches what the gateway advertises and `tgw_asn` matches the Transit Gateway's ASN.
- **Security group blocking**: The private (LAN) security group allows all traffic. If using a custom SG, ensure GRE (protocol 47) is permitted.
- **FRR container not running**: Check `sudo docker ps` — the `infiot_spoke` container must be running.

### GRE Tunnel Down

**Symptom**: GRE tunnel interface exists but no traffic passes.

**Diagnostic steps** (run on host after connecting via SSM):

```sh
# Connect to the gateway via SSM
aws ssm start-session --target <instance-id> --region <region>

# Check tunnel endpoints
ip tunnel show gre1

# Verify connectivity to TGW peer
ping -c 3 <tgw-ip> -I <lan-ip>

# Check MTU
ip link show gre1   # Should show mtu 1300
```

**Common causes**:
- **MTU issues**: The default MTU of 1300 should work. If seeing fragmentation issues, try lowering to 1200.
- **Physical interface mismatch**: `phy_intfname` must match the LAN interface name on the BWAN AMI (default: `enp2s1`). Verify with `ip link show`.
- **TGW Connect not active**: Check the TGW Connect attachment status in the AWS console.

## Gateway Host Commands Reference

These commands are run on the gateway host (not inside a container) after connecting via SSM:

```sh
aws ssm start-session --target <instance-id> --region <region>
```

### Network Diagnostics

```sh
# Show interfaces brief
ip -br a

# Ping with source interface
ping <destination-ip> -I <interface-ip>

# Check interface duplex and port status
ethtool <interface-id>
# Example: ethtool enps20fo

# Show interface details (MAC addresses)
ip address

# Show system routing table (not the SD-WAN overlay routing table)
ip route

# Show ARP table
ip neighbor
```

### Gateway Management

```sh
# Show Borderless WAN firmware version
infhostd version

# Upgrade firmware (replace with desired version)
infhostd upgrade -displayname R5.3.97

# Restart Borderless WAN container
infhostd restart-container infiot_spoke

# Reboot device (will be down for approx 2-5 min)
reboot
```

### Flow Inspection

```sh
# Show flows (can also view in docker controller, pipe to grep for filtering)
infhostd click-dump --help
```

## Container Commands Reference

These commands are run inside the `infiot_spoke` container:

```sh
# Enter the container
sudo docker exec -it infiot_spoke bash
```

### Overlay and Tunnels

```sh
# Show overlay paths and SSE/IPSEC tunnels to NewEdge
/opt/infiot/bin/infcli.py --overlays

# Show interfaces
/opt/infiot/bin/infcli.py --show_int

# Show routing table
/opt/infiot/bin/infcli.py --rt
```

### SSE Monitor Not Running

**Symptom**: `systemctl status sse_monitor` shows inactive or failed on a gateway.

**Diagnostic steps** (connect via bastion or SSM):

```sh
# Check service status and recent logs
systemctl status sse_monitor
journalctl -u sse_monitor --no-pager -n 50

# Check the monitor log file
tail -50 /var/log/sse_monitor.log

# Verify all files are deployed
ls -la /root/sse_monitor/
cat /root/sse_monitor/frrcmds-advertise-default.json
cat /root/sse_monitor/frrcmds-retract-default.json
cat /etc/systemd/system/sse_monitor.service
cat /etc/logrotate.d/sse_monitor
```

**Common causes**:
- **Docker not running**: The service requires `docker.service`. Check `systemctl status docker`.
- **Container not started**: The monitor waits indefinitely for `infiot_spoke`. Check `docker ps`.
- **FRR JSON missing**: If the JSON files weren't deployed, the monitor logs `ERROR: <file> not found`.
- **ikectl not available**: The `ikectl` binary is inside the container at `/opt/infiot/scripts/ikectl`. If the container image is corrupted, tunnel checks will fail.

### SSE Monitor Running but Default Route Not Advertised

**Symptom**: Monitor is active but BGP peers don't show `default-originate`.

**Diagnostic steps**:

```sh
# Check monitor state from log
grep -E '(Tunnels UP|Tunnels DOWN|advertise|retract)' /var/log/sse_monitor.log | tail -20

# Check tunnel status manually
docker exec infiot_spoke /opt/infiot/scripts/ikectl status

# Verify BGP config inside container
docker exec infiot_spoke vtysh -c "show bgp summary"
docker exec infiot_spoke vtysh -c "show running-config" | grep default-originate
```

**Common causes**:
- **No ESTABLISHED tunnels**: The monitor only advertises when `ikectl status` output contains `ESTABLISHED`. If IPsec tunnels to NewEdge are down, this is expected behaviour — the monitor is correctly retracting the default route.
- **Wrong BGP peer IPs in JSON**: Check that the peer IPs in the JSON files match the TGW Connect Peer inside addresses from `terraform output computed-gateway-map`.
- **ikectl frrcmds failing**: Check the monitor log for `FAIL(rc=...)` entries. This can happen if FRR is not running inside the container.

### IMDS Unreachable After Activation

**Symptom**: SSM commands fail with `context deadline exceeded` errors. The SSM agent reports Online but cannot execute documents.

**Diagnostic steps** (connect via bastion SSH):

```sh
# Check IMDS route
ip route get 169.254.169.254

# Expected (working):
#   169.254.169.254 dev enp2s0 src <primary-ip>

# Broken (overlay capturing IMDS):
#   169.254.169.254 dev overlay src 169.254.0.x

# Test IMDS connectivity
curl -s -m 5 http://169.254.169.254/latest/meta-data/instance-id

# Check SSM agent errors
tail -20 /var/log/amazon/ssm/errors.log
```

**Cause**: The `infiot_spoke` container creates an overlay interface with a `169.254.0.0/16` connected route that captures IMDS traffic (`169.254.169.254`). The SSM agent cannot refresh IAM credentials without IMDS access.

**Resolution**: The `user-data.sh` script adds a `/32` host route for `169.254.169.254` pinned to the primary ENI at boot. If this route is missing (e.g., on instances deployed before the fix), add it manually:

```sh
# Identify primary ENI
PRIMARY_ENI=$(ip -o link show | awk -F': ' '/^2:/{print $2}')

# Add host route (takes effect immediately)
ip route add 169.254.169.254/32 dev "$PRIMARY_ENI"

# Verify
curl -s http://169.254.169.254/latest/meta-data/instance-id
```

Note: Instances deployed before this fix require a redeploy (`terraform destroy` + `terraform apply`) for the user-data change to take effect.

### Terraform Destroy Failures

**Symptom**: `terraform destroy` fails with dependency errors.

**Common causes**:
- Resources were manually added to the VPC/TGW outside of Terraform
- TGW Connect Peers can't be deleted before the Connect attachment
- ENIs are in use by other services

**Resolution**:
1. Remove manually-created resources first
2. If stuck, try targeted destroy in reverse dependency order:
   ```sh
   terraform destroy -target=null_resource.gre_config
   terraform destroy -target=aws_instance.gateways
   terraform destroy -target=netskopebwan_gateway.gateways
   terraform destroy -target=aws_vpc.this
   ```

### Provider Authentication Errors

**Symptom**: `Error: failed to authenticate` from the `netskopebwan` provider.

**Causes**:
- Invalid or expired `tenant_token`
- Incorrect `tenant_url` (the provider config derives the API URL by inserting `.api` into the hostname)
- Network connectivity to `https://<tenant>.api.infiot.net`

**Verification**:
```sh
# Test API connectivity
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer <token>" \
  "https://<tenant>.api.infiot.net/api/v1/policy"
```

## Known Limitations

1. **TGW Connect Peer limit**: AWS allows a maximum of 4 Connect Peers per TGW Connect attachment. The `gateway_count` variable is validated to enforce this limit.

2. **Single policy**: All gateways share one Netskope policy (`gateway_policy`). Per-gateway policy assignment is not supported.

3. **Existing VPC attachment**: When reusing an existing VPC and TGW, the VPC attachment subnet list may need manual updates due to an AWS API limitation with `aws_ec2_transit_gateway_vpc_attachment`.

4. **SSM dependency**: GRE/BGP configuration requires SSM Agent connectivity. If the agent fails to start, the entire deployment will time out.

5. **Sequential GRE configuration**: The `local-exec` provisioner for GRE config runs sequentially per gateway (not parallelized), as each invocation polls for completion.

6. **Provider version pinning**: The `netskopebwan` provider is pinned to `0.0.2`. Newer versions may introduce breaking changes to resource schemas.

7. **IMDS route hijacking**: The Netskope overlay interface (`169.254.0.0/16`) captures IMDS traffic post-activation. The `user-data.sh` IMDS route fix mitigates this, but if a future firmware update changes the overlay addressing or routing priority, the fix may need adjustment.

8. **SSE monitor requires container**: The monitor depends on `infiot_spoke` running with `ikectl` available. If the container image changes or `ikectl` is moved/renamed in a firmware update, the monitor will log errors.
