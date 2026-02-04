# Netskope SD-WAN Gateway — AWS Terraform Module

Deploys and activates Netskope SD-WAN (BWAN) gateways in AWS with automated GRE tunnel and BGP peering through an AWS Transit Gateway. The module handles the full lifecycle: VPC networking, Netskope portal configuration, EC2 instance provisioning, and post-launch GRE/BGP setup via SSM.

## What This Module Does

- Provisions 1–4 Netskope SD-WAN gateways distributed across availability zones
- Creates (or reuses) a VPC with public/private subnets, security groups, and an Internet Gateway
- Creates (or reuses) an AWS Transit Gateway with Connect attachments and BGP peering
- Registers gateways in the Netskope SD-WAN portal (policy, interfaces, activation, BGP)
- Configures GRE tunnels and FRR BGP sessions on each gateway via SSM
- Optionally deploys a client VPC for end-to-end testing

## Architecture

![Netskope SD-WAN GW deployment in AWS](./images/AWS.png)

*Fig 1. Netskope SD-WAN GW deployment in AWS*

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed network topology, resource inventory, and GRE/BGP tunnel design.

## Quick Start

```sh
git clone <repository-url>
cd terraform-netskopebwan-aws
cp example.tfvars terraform.tfvars
# Edit terraform.tfvars with your Netskope tenant and AWS settings

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for a step-by-step walkthrough with expected outputs.

## Prerequisites

- **Terraform** >= 0.13
- **AWS account** with permissions to create VPC, EC2, TGW, IAM, and SSM resources
- **AWS CLI** installed (used by the GRE configuration provisioner)
- **Netskope SD-WAN tenant** with tenant ID, tenant URL, and a REST API token

## Variables

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_network_config` | object | see below | VPC configuration (region, create/reuse, CIDR) |
| `aws_transit_gw` | object | see below | Transit Gateway configuration (create/reuse, ASN, CIDR) |
| `netskope_tenant` | object | *required* | Tenant ID, URL, API token, BGP ASN |
| `netskope_gateway_config` | object | `{}` | Gateway policy name, password, model, DNS |
| `aws_instance` | object | see below | EC2 instance type, key pair, AMI filter |
| `gateway_count` | number | `2` | Number of gateways to deploy (1–4) |
| `az_count` | number | `2` | Number of AZs for gateway distribution |
| `gateway_prefix` | string | `"aws-gw"` | Naming prefix for gateway identifiers |
| `gateway_role` | string | `"hub"` | Gateway role (hub or spoke) |
| `inside_cidr_base` | string | `"169.254.100.0/24"` | Base link-local CIDR for GRE inside addresses (must be within `169.254.0.0/16`, see constraints below) |
| `subnet_size` | number | `28` | Prefix length for auto-generated subnets |
| `environment` | string | `"netskope"` | Prefix for resource naming |
| `tags` | map(string) | `{ManagedBy = "terraform"}` | Tags applied to all AWS resources |
| `clients` | object | `{create_clients = false}` | Optional client VPC for testing |

### Object Variable Details

<details>
<summary><code>aws_network_config</code></summary>

| Field | Type | Default | Description |
|---|---|---|---|
| `region` | string | `"us-east-1"` | AWS region |
| `create_vpc` | bool | `true` | Create a new VPC or use existing |
| `vpc_id` | string | `""` | Existing VPC ID (when `create_vpc = false`) |
| `vpc_cidr` | string | `""` | VPC CIDR block (required when creating) |
| `route_table.public` | string | `""` | Existing public route table ID |
| `route_table.private` | string | `""` | Existing private route table ID |

</details>

<details>
<summary><code>aws_transit_gw</code></summary>

| Field | Type | Default | Description |
|---|---|---|---|
| `create_transit_gw` | bool | `true` | Create a new TGW or use existing |
| `tgw_id` | string | `null` | Existing TGW ID (when `create_transit_gw = false`) |
| `tgw_asn` | string | `"64512"` | TGW BGP ASN (16-bit: 1–65534 or 32-bit: 131072–4199999999; must not conflict with `tenant_bgp_asn`; AWS reserves 7224 and 9059) |
| `tgw_cidr` | string | `""` | TGW CIDR block for Connect Peer addressing (RFC 1918 or CG-NAT space; must not overlap with attached VPC CIDRs) |
| `vpc_attachment` | string | `""` | Existing VPC attachment ID |
| `phy_intfname` | string | `"enp2s1"` | Physical interface name for GRE underlay |

</details>

<details>
<summary><code>netskope_tenant</code></summary>

| Field | Type | Default | Description |
|---|---|---|---|
| `deployment_name` | string | *required* | Free-form string used in resource naming for identification (e.g., `"my-corp-prod"`) |
| `tenant_url` | string | *required* | Tenant URL (e.g., `https://example.infiot.net`) |
| `tenant_token` | string | *required* | REST API token |
| `tenant_bgp_asn` | string | `"400"` | BGP ASN for gateways |

</details>

<details>
<summary><code>netskope_gateway_config</code></summary>

| Field | Type | Default | Description |
|---|---|---|---|
| `gateway_password` | string | `"infiot"` | Console password for gateways |
| `gateway_policy` | string | `"test"` | Netskope policy name |
| `gateway_model` | string | `"iXVirtual"` | Gateway model |
| `dns_primary` | string | `"8.8.8.8"` | Primary DNS server |
| `dns_secondary` | string | `"8.8.4.4"` | Secondary DNS server |

</details>

<details>
<summary><code>aws_instance</code></summary>

| Field | Type | Default | Description |
|---|---|---|---|
| `keypair` | string | `""` | EC2 key pair name |
| `instance_type` | string | `"t3.medium"` | EC2 instance type |
| `ami_name` | string | `"BWAN-SASE-RTM-CLOUD-"` | AMI name filter |
| `ami_owner` | string | `"679593333241"` | AMI owner account ID |

</details>

<details>
<summary><code>clients</code></summary>

| Field | Type | Default | Description |
|---|---|---|---|
| `create_clients` | bool | `false` | Deploy client VPC and instance |
| `client_ami` | string | `"ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server"` | Client AMI filter |
| `vpc_cidr` | string | `"192.168.255.0/28"` | Client VPC CIDR |
| `instance_type` | string | `"t3.small"` | Client instance type |
| `password` | string | `"infiot"` | Client console password |
| `ports` | list(string) | `["22"]` | Ports for port forwarding rules |

</details>

## Outputs

| Output | Description |
|---|---|
| `gateways` | Map of gateway keys to instance IDs and GRE configuration status |
| `gre-config-ssm-document` | SSM document name used for GRE tunnel configuration |
| `computed-gateway-map` | Auto-computed gateway configuration (subnets, CIDRs, BGP metrics) |
| `client-details` | Client instance details (when `create_clients = true`) |

## Documentation

| Document | Description |
|---|---|
| [Architecture](docs/ARCHITECTURE.md) | Network topology, module responsibilities, resource inventory, GRE/BGP design |
| [Deployment Guide](docs/DEPLOYMENT_GUIDE.md) | Configuration walkthrough, deployment paths, scaling, tagging |
| [Quick Start](docs/QUICKSTART.md) | Minimal steps to deploy and verify |
| [IAM Permissions](docs/IAM_PERMISSIONS.md) | Required IAM policies for the Terraform operator and CI/CD |
| [State Management](docs/STATE_MANAGEMENT.md) | Remote backend setup (S3 + DynamoDB) |
| [Operations](docs/OPERATIONS.md) | Day-2: scaling, gateway replacement, AMI upgrades, BGP verification |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common issues, diagnostic commands, known limitations |
| [DevOps Notes](docs/DEVOPS_NOTES.md) | Internal patterns, provider details, variable flow |

## Support

Netskope-provided scripts in this and other GitHub projects do not fall under the regular Netskope technical support scope and are not supported by Netskope support services.
