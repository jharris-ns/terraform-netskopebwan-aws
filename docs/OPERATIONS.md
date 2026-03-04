# Operations

Day-2 operational procedures for the deployed Netskope SD-WAN gateway infrastructure.

## Scaling Gateways

To add or remove gateways, update `gateway_count` in your `terraform.tfvars` and re-apply:

```hcl
gateway_count = 4   # Scale from 2 to 4 gateways
```

```sh
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

New gateways are assigned the next available subnet CIDRs, inside CIDRs, and BGP MED values. Existing gateways are not affected.

**Limit**: Maximum 4 gateways per deployment (AWS TGW Connect Peer limit per Connect attachment).

## Gateway Replacement

To replace a specific gateway instance (e.g., after AMI update):

```sh
# Taint the specific instance to force recreation
terraform taint 'aws_instance.gateways["aws-gw-1"]'

# Also taint the GRE config to re-run tunnel setup
terraform taint 'null_resource.gre_config["aws-gw-1"]'

# Apply to recreate
terraform apply -var-file=terraform.tfvars
```

This recreates only the targeted gateway. The Netskope portal configuration (policy, interfaces, BGP) is preserved.

## Rotating the Netskope API Token

1. Generate a new REST API token in the Netskope SD-WAN portal
2. Update `tenant_token` in your `terraform.tfvars`
3. Run `terraform plan` to verify — the plan should show no changes (the token is only used for provider authentication, not stored in state as a resource attribute)

If the token is stored in a secrets manager, update it there and re-run the pipeline.

## Upgrading the Gateway AMI

When a new Netskope BWAN AMI is published:

1. The `ami_name` filter (`BWAN-SASE-RTM-CLOUD-`) with `most_recent = true` automatically picks the latest AMI
2. Run `terraform plan` — if a new AMI is available, the plan shows instance replacement
3. Apply to roll gateways to the new AMI

For a controlled rollout, taint and replace one gateway at a time (see Gateway Replacement above).

## BGP and GRE Verification

For BGP and GRE tunnel verification, refer to the Netskope documentation for connection and diagnostics via the Netskope console.

## Re-Running GRE Configuration

If GRE/BGP configuration needs to be re-applied (e.g., after a gateway reboot that lost configuration, or after a firmware upgrade that reset the tunnel), taint the `gre_config` resource for the affected gateway and re-apply:

```sh
# Re-run GRE/BGP configuration for a specific gateway
terraform taint 'null_resource.gre_config["aws-gw-1"]'
terraform apply -var-file=terraform.tfvars
```

This re-executes the SSM document on the gateway, which:
1. Re-activates the gateway with the Netskope tenant
2. Writes the FRR BGP configuration (`frrcmds-user.json`) with TGW Connect peer addresses and MED values
3. Configures the GRE tunnel interface (`gre1`) with the correct local/remote IPs and MTU
4. Restarts the `infiot_spoke` container and verifies BGP neighbors appear

The SSE monitor is a separate resource. If it also needs re-deploying (e.g., the monitor script or FRR advertise/retract JSON files were lost):

```sh
terraform taint 'null_resource.sse_monitor["aws-gw-1"]'
terraform apply -var-file=terraform.tfvars
```

To re-run both on all gateways, taint each gateway key individually — wildcard tainting is not supported:

```sh
terraform taint 'null_resource.gre_config["aws-gw-1"]'
terraform taint 'null_resource.gre_config["aws-gw-2"]'
terraform taint 'null_resource.sse_monitor["aws-gw-1"]'
terraform taint 'null_resource.sse_monitor["aws-gw-2"]'
terraform apply -var-file=terraform.tfvars
```

**Note**: The GRE config step includes gateway activation (`infhostd activate`). If the gateway is already activated, the activation step is idempotent — it will succeed without side effects.

## Monitoring Recommendations

### CloudWatch Metrics

- **EC2**: `StatusCheckFailed`, `CPUUtilization`, `NetworkIn/Out` for gateway instances
- **Transit Gateway**: `BytesIn/Out`, `PacketDropCountBlackhole` per attachment
- **VPC Flow Logs**: Enable on gateway subnets for traffic analysis

### CloudWatch Alarms

| Metric | Threshold | Action |
|---|---|---|
| EC2 StatusCheckFailed | > 0 for 5 min | Investigate/replace gateway |
| TGW PacketDropCountBlackhole | > 0 | Check BGP routes |
| EC2 CPUUtilization | > 80% sustained | Consider larger instance type |

### Netskope Portal

Monitor gateway health, tunnel status, and policy enforcement in the Netskope SD-WAN portal dashboard.
