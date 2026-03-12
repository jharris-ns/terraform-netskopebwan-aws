# Deployment Guide

Comprehensive configuration reference and deployment instructions for Netskope SD-WAN gateways in AWS. For a minimal "get deployed fast" walkthrough, see the [Quick Start](QUICKSTART.md).

## Prerequisites

- **Terraform** >= 1.3
- **AWS CLI** configured with sufficient permissions (see [IAM Permissions](IAM_PERMISSIONS.md))
- **Netskope SD-WAN tenant** with a REST API token (created in the SD-WAN portal)
- **Netskope gateway policy** — create a policy in the SD-WAN portal before deploying. The policy name is set in `gateway_policy` and must already exist; Terraform will fail at plan time if it cannot find it.
- **AWS EC2 key pair** in the target region (optional, for SSH access)

## Authentication

### AWS

The AWS provider uses the standard SDK credential chain. Use any of these methods:

| Method | Setup |
|---|---|
| **SSO Profile** (recommended) | `aws configure sso`, then `aws sso login --profile my-sso-profile` and `export AWS_PROFILE="my-sso-profile"` |
| **IAM Access Keys** | `export AWS_ACCESS_KEY_ID="AKIA..."` and `export AWS_SECRET_ACCESS_KEY="..."` (optionally `AWS_SESSION_TOKEN` for temporary credentials) |
| **Named Profile** | `export AWS_PROFILE="my-profile"` (reads `~/.aws/credentials`) |
| **Instance Role** | No configuration needed — the provider uses the EC2 instance metadata service automatically |

### Netskope

Set the tenant URL and API token as environment variables to keep secrets out of version control:

```sh
export TF_VAR_netskope_tenant_url="https://your-tenant.infiot.net"
export TF_VAR_netskope_tenant_token="your-api-token"
```

The `https://` scheme on `tenant_url` is optional — it is stripped automatically to prevent URL duplication. `netskope_tenant_token` is marked `sensitive = true`, so Terraform redacts it from plan output.

These override the corresponding fields in the `netskope_tenant` object. The remaining fields (`deployment_name`, `tenant_bgp_asn`) are set in `terraform.tfvars`.

## Configuration Reference

Copy the example file as your starting point:

```sh
cp example.tfvars terraform.tfvars
```

### `netskope_tenant`

| Field | Required | Default | Description |
|---|---|---|---|
| `deployment_name` | Yes | — | Free-form string used in resource naming (e.g., `"my-corp-prod"`) |
| `tenant_bgp_asn` | No | `"400"` | BGP ASN for the gateways |

> **Note:** `tenant_url` and `tenant_token` are set via environment variables (`TF_VAR_netskope_tenant_url`, `TF_VAR_netskope_tenant_token`), not in tfvars.

### `aws_network_config`

| Field | Required | Default | Description |
|---|---|---|---|
| `region` | No | `"us-east-1"` | AWS region for deployment |
| `create_vpc` | Yes | — | `true` to create a new VPC, `false` to use existing |
| `vpc_id` | When `create_vpc = false` | — | ID of existing VPC |
| `vpc_cidr` | When `create_vpc = true` | — | CIDR block for the VPC; gateway subnets are auto-carved from this |
| `route_table` | No | — | Existing route table IDs (auto-created if omitted) |

### `aws_transit_gw`

| Field | Required | Default | Description |
|---|---|---|---|
| `create_transit_gw` | Yes | — | `true` to create a new TGW, `false` to use existing |
| `tgw_id` | When `create_transit_gw = false` | — | ID of existing Transit Gateway |
| `tgw_asn` | No | `"64512"` | BGP ASN for the TGW. Must be a private ASN (16-bit: 1–65534 or 32-bit: 131072–4199999999). AWS reserves 7224 and 9059. Must not conflict with `tenant_bgp_asn`. |
| `tgw_cidr` | When `create_transit_gw = true` | — | CIDR block for TGW Connect Peer addressing. Must be RFC 1918 or CG-NAT (`100.64.0.0/10`) and must not overlap with any VPC CIDR attached to the TGW. |
| `phy_intfname` | No | — | Physical interface name on the gateway for GRE underlay |

### `netskope_gateway_config`

| Field | Required | Default | Description |
|---|---|---|---|
| `gateway_policy` | Yes | `"test"` | Name of an existing policy on the Netskope tenant. The policy must be created in the SD-WAN portal before deployment — all gateways in the deployment share this single policy. |
| `gateway_password` | No | `"infiot"` | Console login password |
| `gateway_model` | No | `"iXVirtual"` | Gateway model type |
| `dns_primary` | No | — | Primary DNS server for gateway interfaces |
| `dns_secondary` | No | — | Secondary DNS server for gateway interfaces |
| `static_routes` | No | `["192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12"]` | List of CIDR blocks to route via the LAN interface on each gateway. A static route is created per CIDR per gateway. |

### `aws_instance`

| Field | Required | Default | Description |
|---|---|---|---|
| `keypair` | No | `""` | EC2 key pair name for SSH access |
| `instance_type` | No | `"t3.medium"` | EC2 instance type |
| `ami_name` | No | — | AMI name filter for gateway image |
| `ami_owner` | No | — | AMI owner account ID |

### Standalone Variables

| Variable | Default | Description |
|---|---|---|
| `gateway_count` | `2` | Number of gateways (default 2, tested up to 4). Each gateway gets its own TGW Connect attachment with a single Connect peer; ECMP load balancing is achieved across attachments via BGP. The max of 4 is a soft limit in the validation and can be increased. See [Scaling](#scaling). |
| `az_count` | `2` | Number of AZs to distribute gateways across (round-robin) |
| `gateway_prefix` | `"aws-gw"` | Naming prefix for gateway identifiers (keys become `{prefix}-1`, `{prefix}-2`, etc.) |
| `gateway_role` | `"hub"` | Gateway role (`hub` or `spoke`) |
| `environment` | `"netskope"` | Prefix for resource naming (VPC, TGW, security groups) |
| `subnet_size` | `28` | Prefix length for auto-generated subnets carved from `vpc_cidr` |
| `inside_cidr_base` | `"169.254.100.0/24"` | Base link-local CIDR for GRE inside addresses. Must be within `169.254.0.0/16`. Avoid `169.254.169.0/24` (EC2 metadata) and `169.254.170.0/24` (AWS reserved). |

### `tags`

Common tags applied to all AWS resources via provider `default_tags`:

```hcl
tags = {
  ManagedBy   = "terraform"
  Environment = "production"
  Project     = "netskope-bwan"
  Owner       = "network-team"
}
```

These merge with per-resource `Name` tags set individually using the environment prefix and resource identifiers.

### `clients`

| Field | Default | Description |
|---|---|---|
| `create_clients` | `false` | Deploy an optional client VPC for testing |
| `ports` | — | List of ports to forward through the gateway |

## Deployment Paths

### New VPC + New Transit Gateway

Use when deploying into a fresh AWS environment:

```hcl
aws_network_config = {
  create_vpc = true
  region     = "us-east-1"
  vpc_cidr   = "172.32.0.0/16"
}

aws_transit_gw = {
  create_transit_gw = true
  tgw_asn           = "64513"
  tgw_cidr          = "192.0.1.0/24"
}
```

### Existing VPC + Existing Transit Gateway

Use when integrating into an established network:

```hcl
aws_network_config = {
  create_vpc = false
  vpc_id     = "vpc-0abc123def456"
  region     = "ap-southeast-2"
}

aws_transit_gw = {
  create_transit_gw = false
  tgw_id            = "tgw-0abc123def456"
}
```

**Note**: When reusing an existing VPC attachment, you may need to manually add the new gateway LAN subnets to it — the AWS API does not support in-place subnet updates via Terraform. Add them with the CLI or Console:

```sh
aws ec2 modify-transit-gateway-vpc-attachment \
  --transit-gateway-attachment-id tgw-attach-0abc123... \
  --add-subnet-ids subnet-111aaa subnet-222bbb
```

The subnet IDs are the ge2 (LAN) subnets Terraform created, one per AZ — find them in `terraform output` or `terraform state list`.

**Note**: When the project creates a new TGW, it enables `default_route_table_association` and `default_route_table_propagation`, so all attachments (gateway VPC, Connect, and client VPC) are automatically associated and propagated on the default TGW route table. When using an existing TGW, you are responsible for ensuring the TGW route table has the correct associations and propagations for the gateway VPC attachment and Connect attachments. Without these, BGP routes from the gateways will not appear in the TGW route table and traffic will not be forwarded.

## Step-by-Step Deployment

1. Clone the repository and create `terraform.tfvars` (see [Quick Start](QUICKSTART.md))
2. Set AWS and Netskope credentials (see [Authentication](#authentication) above)
3. Run `terraform init`
4. Run `terraform plan -var-file=terraform.tfvars` to preview changes
5. Run `terraform apply -var-file=terraform.tfvars` to deploy

The deployment creates resources in this order:
1. VPC, subnets, security groups, TGW infrastructure
2. Netskope portal: policy, gateways, interfaces, BGP config, activation tokens
3. EC2 instances with activation credentials in user-data
4. GRE tunnel configuration via SSM (waits for SSM agent readiness)

The GRE configuration step polls for SSM agent availability (up to 5 minutes) and then executes the tunnel setup. BGP session establishment is verified before completion.

## Scaling

### ECMP Architecture

Each gateway is deployed with its own dedicated TGW Connect attachment and a single Connect peer. This differs from the alternative approach of placing multiple Connect peers on a single attachment. The per-gateway attachment model enables ECMP load balancing across attachments — all gateways advertise the same prefixes with matching BGP AS-PATH attributes, so the TGW distributes traffic equally across all active paths.

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  Gateway 1  │────▶│ Connect Attach 1 │────▶│                 │
│  (1 Peer)   │     │  (1 Peer)        │     │                 │
├─────────────┤     ├──────────────────┤     │  Transit        │
│  Gateway 2  │────▶│ Connect Attach 2 │────▶│  Gateway        │
│  (1 Peer)   │     │  (1 Peer)        │     │  (ECMP across   │
├─────────────┤     ├──────────────────┤     │   attachments)  │
│  Gateway N  │────▶│ Connect Attach N │────▶│                 │
│  (1 Peer)   │     │  (1 Peer)        │     │                 │
└─────────────┘     └──────────────────┘     └─────────────────┘
```

### Changing Gateway Count

Adjust `gateway_count` to add or remove gateways. The default is 2 and the project has been tested with up to 4. The validation limit of 4 is a soft cap that can be increased in `variables.tf` — there is no hard AWS limit on the number of Connect attachments per TGW (the general attachment quota is 5,000). The project automatically:
- Creates a dedicated TGW Connect attachment per gateway
- Computes subnet CIDRs for new gateways
- Assigns availability zones round-robin
- Creates TGW Connect Peers with unique inside CIDRs
- Sets equal BGP MED values for ECMP load balancing across all gateways

```hcl
gateway_count = 4   # Tested up to 4; increase validation in variables.tf for more
az_count      = 2   # Spread across 2 AZs
```

### Changing AZ Distribution

Set `az_count` to control how many availability zones are used. Gateways are distributed round-robin:
- `az_count = 1`: All gateways in one AZ
- `az_count = 2`: Alternating AZs (gw-1 in AZ-a, gw-2 in AZ-b, gw-3 in AZ-a, ...)

## Destruction

To tear down the entire deployment:

```sh
terraform destroy -var-file=terraform.tfvars
```

This removes all AWS resources and Netskope gateway configuration created by the project. The Netskope gateway entries are deactivated and deleted via the provider. The gateway policy is not deleted — it was created outside of Terraform and remains on the tenant.

**Caution**: If other resources (e.g., additional TGW attachments, route table entries) were manually added to the VPC or Transit Gateway outside of Terraform, remove them before running `terraform destroy` to avoid dependency errors.
