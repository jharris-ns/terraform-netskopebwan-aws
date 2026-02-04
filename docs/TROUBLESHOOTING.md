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
# Check BGP state
aws ssm start-session --target <instance-id> --region <region>
sudo docker exec -it infiot-router vtysh -c "show bgp summary"

# Check if GRE tunnel is up
sudo docker exec -it infiot-router vtysh -c "show interface gre1"

# Verify IP addressing on GRE tunnel
ip addr show gre1
```

**Common causes**:
- **Inside CIDR mismatch**: Verify the TGW Connect Peer's inside CIDR matches the gateway's GRE tunnel IPs. Check the `computed-gateway-map` output.
- **ASN mismatch**: Ensure `tenant_bgp_asn` matches what the gateway advertises and `tgw_asn` matches the Transit Gateway's ASN.
- **Security group blocking**: The private (LAN) security group allows all traffic. If using a custom SG, ensure GRE (protocol 47) is permitted.
- **FRR container not running**: Check `sudo docker ps` — the `infiot-router` container must be running.

### GRE Tunnel Down

**Symptom**: GRE tunnel interface exists but no traffic passes.

**Diagnostic steps**:

```sh
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
