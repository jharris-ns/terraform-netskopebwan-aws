# Deployment Guide

## Prerequisites

- **AWS CLI** configured with credentials that have sufficient permissions (see [IAM Permissions](IAM_PERMISSIONS.md))
- **Terraform** >= 0.13 installed
- **Netskope SD-WAN tenant** with:
  - Tenant ID (from Netskope team)
  - Tenant URL (e.g., `https://example.infiot.net`)
  - REST API token (created in the Netskope SD-WAN portal)
- **AWS EC2 key pair** created in the target region (optional, for SSH access)

## Configuration Walkthrough

Copy one of the example files as your starting point:

```sh
cp example.tfvars terraform.tfvars
```

### Required Variables

#### `netskope_tenant`

| Field | Description |
|---|---|
| `deployment_name` | Free-form string used in resource naming for identification (e.g., `"my-corp-prod"`) |
| `tenant_url` | Full URL of your tenant (e.g., `https://example.infiot.net`) |
| `tenant_token` | REST API token from the Netskope SD-WAN portal |
| `tenant_bgp_asn` | BGP ASN for the gateways (default: `"400"`) |

#### `aws_network_config`

| Field | Description |
|---|---|
| `region` | AWS region for deployment (default: `"us-east-1"`) |
| `create_vpc` | `true` to create a new VPC, `false` to use existing |
| `vpc_id` | Required when `create_vpc = false` |
| `vpc_cidr` | VPC CIDR block (required when `create_vpc = true`) |

#### `aws_transit_gw`

| Field | Description |
|---|---|
| `create_transit_gw` | `true` to create a new TGW, `false` to use existing |
| `tgw_id` | Required when `create_transit_gw = false` |
| `tgw_asn` | BGP ASN for the Transit Gateway (default: `"64512"`). Must be a private ASN (16-bit: 1–65534 or 32-bit: 131072–4199999999). AWS reserves 7224 and 9059. Must not conflict with `tenant_bgp_asn`. |
| `tgw_cidr` | CIDR block assigned to the TGW for Connect Peer addressing (required when `create_transit_gw = true`). Must be RFC 1918 or CG-NAT (`100.64.0.0/10`) space and must not overlap with any VPC CIDR attached to the TGW. |

### Optional Variables

| Variable | Default | Description |
|---|---|---|
| `gateway_count` | `2` | Number of gateways (1–4) |
| `az_count` | `2` | Number of AZs to distribute gateways across |
| `gateway_prefix` | `"aws-gw"` | Naming prefix for gateway identifiers |
| `gateway_role` | `"hub"` | Gateway role (`hub` or `spoke`) |
| `environment` | `"netskope"` | Prefix for resource naming |
| `subnet_size` | `28` | Prefix length for auto-generated subnets |
| `inside_cidr_base` | `"169.254.100.0/24"` | Base link-local CIDR for GRE inside addresses. Must be within `169.254.0.0/16`. Avoid `169.254.169.0/24` (EC2 metadata) and `169.254.170.0/24` (AWS reserved). |
| `aws_instance.instance_type` | `"t3.medium"` | EC2 instance type |
| `aws_instance.keypair` | `""` | EC2 key pair name for SSH access |
| `netskope_gateway_config.gateway_policy` | `"test"` | Netskope policy name |
| `clients.create_clients` | `false` | Deploy optional client VPC for testing |

## Deployment Paths

### Path 1: New VPC + New Transit Gateway

Use this when deploying into a fresh AWS environment. See `example.tfvars` for a complete reference.

```hcl
aws_network_config = {
  create_vpc = true
  region     = "ap-southeast-2"
  vpc_cidr   = "172.32.0.0/16"
}

aws_transit_gw = {
  create_transit_gw = true
  tgw_asn           = "64513"
  tgw_cidr          = "192.0.1.0/24"
}
```

### Path 2: Existing VPC + Existing Transit Gateway

Use this when integrating into an established network. See `example2.tfvars` for a complete reference.

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

**Note**: When reusing an existing VPC attachment, you may need to manually update the subnet list in the TGW VPC attachment due to an [AWS API limitation](https://github.com/hashicorp/terraform-provider-aws/issues).

## Step-by-Step Deployment

```sh
# 1. Clone the repository
git clone <repository-url>
cd terraform-netskopebwan-aws

# 2. Configure your variables
cp example.tfvars terraform.tfvars
# Edit terraform.tfvars with your values

# 3. Initialize Terraform
terraform init

# 4. Preview changes
terraform plan -var-file=terraform.tfvars

# 5. Deploy
terraform apply -var-file=terraform.tfvars
```

The deployment creates resources in this order:
1. VPC, subnets, security groups, TGW infrastructure
2. Netskope portal: policy, gateways, interfaces, BGP config, activation tokens
3. EC2 instances with activation credentials in user-data
4. GRE tunnel configuration via SSM (waits for SSM agent readiness)

The GRE configuration step polls for SSM agent availability (up to 5 minutes) and then executes the tunnel setup. BGP session establishment is verified before completion.

## Scaling

### Changing Gateway Count

Adjust `gateway_count` (1–4) to add or remove gateways. The module automatically:
- Computes subnet CIDRs for new gateways
- Assigns availability zones round-robin
- Creates TGW Connect Peers with unique inside CIDRs
- Sets equal BGP MED values for ECMP load balancing across all gateways

```hcl
gateway_count = 4   # Deploy 4 gateways (max per TGW Connect attachment)
az_count      = 2   # Spread across 2 AZs
```

### Changing AZ Distribution

Set `az_count` to control how many availability zones are used. Gateways are distributed round-robin:
- `az_count = 1`: All gateways in one AZ
- `az_count = 2`: Alternating AZs (gw-1 in AZ-a, gw-2 in AZ-b, gw-3 in AZ-a, ...)

## Tagging Strategy

All AWS resources receive tags from two sources:

1. **Provider default tags** — set via the `tags` variable, applied to every resource:
   ```hcl
   tags = {
     ManagedBy   = "terraform"
     Environment = "production"
     Project     = "netskope-bwan"
     Owner       = "network-team"
   }
   ```

2. **Resource-level `Name` tags** — set individually per resource using the environment prefix and resource identifiers.

## Destruction

To tear down the entire deployment:

```sh
terraform destroy -var-file=terraform.tfvars
```

This removes all AWS resources and Netskope portal configuration created by the module. The Netskope gateway entries are deactivated and deleted via the provider.

**Caution**: If other resources (e.g., additional TGW attachments, route table entries) were manually added to the VPC or Transit Gateway outside of Terraform, remove them before running `terraform destroy` to avoid dependency errors.
