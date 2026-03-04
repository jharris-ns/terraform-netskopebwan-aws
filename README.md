# Netskope SD-WAN Gateway — AWS Terraform Project

Deploys and activates Netskope SD-WAN (BWAN) gateways in AWS with automated GRE tunnel and BGP peering through an AWS Transit Gateway. This project handles the full lifecycle: VPC networking, Netskope portal configuration, EC2 instance provisioning, and post-launch GRE/BGP setup via SSM.

## When to Use This Project

This project implements Netskope Borderless SD-WAN with BGP/GRE — the recommended approach for steering AWS workload traffic through Netskope for security inspection. It is transparent to applications: no agents, no code changes, no per-instance configuration.

### How It Works

BWAN Gateways run as EC2 instances in a dedicated Gateway VPC, connected to your application VPCs via AWS Transit Gateway. Each gateway establishes GRE tunnels to Netskope NewEdge Data Planes and runs BGP sessions over those tunnels to exchange routing information. Spoke VPC route tables direct internet-bound traffic (0.0.0.0/0) to the TGW, which forwards it to the gateways for inspection by Netskope.

### ECMP and Scaling

Each gateway originates a default route (0.0.0.0/0) over its BGP session to the Transit Gateway, advertising it with equal MED values across all gateways. Spoke VPC route tables point 0.0.0.0/0 at the TGW, and the TGW route table forwards this traffic to the Gateway VPC. Because each gateway gets its own dedicated TGW Connect attachment with a single Connect peer, and all gateways advertise the same prefix with matching AS-PATH and MED, the Transit Gateway distributes traffic across all gateways using Equal-Cost Multi-Path (ECMP) routing. This provides both load balancing and automatic failover — if a gateway goes down, its BGP session drops and the TGW immediately reroutes traffic to the remaining healthy gateways.

The default deployment uses 2 gateways. The project has been tested with up to 4. The validation limit of 4 is a soft cap that can be increased in `variables.tf` — there is no hard AWS limit on the number of Connect attachments per TGW.
### Applicable Workloads

Any AWS workload that routes outbound traffic via a default route (0.0.0.0/0) through the Transit Gateway — application servers, containers, batch jobs, legacy systems — benefits from Netskope inspection without modification.

### Key Benefits

- **No agents required** — works with any OS, container runtime, or serverless function
- **Transparent to applications** — no code or configuration changes on servers
- **Supports web and non-web traffic** inspection (with Cloud Firewall)
- **Centralized security** for entire VPCs without per-instance management
- **Private IP visibility** preserved for logging and policy enforcement
- **Automatic failover** via BGP — no manual intervention when a gateway fails

## What This Project Does

- Provisions 1–4 Netskope SD-WAN gateways distributed across availability zones
- Creates (or reuses) a VPC with public/private subnets, security groups, and an Internet Gateway
- Creates (or reuses) an AWS Transit Gateway with Connect attachments and BGP peering
- Registers gateways in the Netskope SD-WAN portal (policy, interfaces, activation, BGP)
- Configures GRE tunnels and FRR BGP sessions on each gateway via SSM
- Deploys an IPsec tunnel health monitor (SSE monitor) that controls BGP default route advertisement based on tunnel state
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

- **Terraform** >= 1.3 with providers: `aws ~> 4.30`, `netskopebwan 0.0.2`, `null ~> 3.0`, `time ~> 0.7.2`, `cloudposse/utils`
- **AWS account** with permissions to create VPC, EC2, TGW, IAM, and SSM resources
- **AWS CLI** installed and configured (supports SSO profiles via `AWS_PROFILE`; used by the GRE configuration provisioner)
- **Netskope SD-WAN tenant** with tenant ID, tenant URL, and a REST API token

## Outputs

| Output | Description |
|---|---|
| `gateways` | Map of gateway keys to instance IDs and GRE configuration status |
| `gre-config-ssm-document` | SSM document name used for GRE tunnel configuration |
| `computed-gateway-map` | Auto-computed gateway configuration (subnets, CIDRs, BGP metrics) |
| `client-details` | Client instance details (when `create_clients = true`) |

## Documentation

Start with the **Quick Start** to get deployed, then refer to the **Deployment Guide** for the full configuration reference.

| Document | Description |
|---|---|
| [Quick Start](docs/QUICKSTART.md) | Get deployed fast — minimal config, credentials, deploy, and verify |
| [Deployment Guide](docs/DEPLOYMENT_GUIDE.md) | Comprehensive variable reference, authentication options, deployment paths, ECMP scaling |
| [CloudShell](docs/CLOUDSHELL.md) | CloudShell-specific environment notes (Terraform install, region, storage limits) |
| [Architecture](docs/ARCHITECTURE.md) | Network topology, resource inventory, GRE/BGP design |
| [IAM Permissions](docs/IAM_PERMISSIONS.md) | Required IAM policies for the Terraform operator and CI/CD |
| [State Management](docs/STATE_MANAGEMENT.md) | Remote backend setup (S3 + DynamoDB) |
| [Operations](docs/OPERATIONS.md) | Day-2: scaling, gateway replacement, AMI upgrades, BGP verification |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common issues, diagnostic commands, known limitations |
| [DevOps Notes](docs/DEVOPS_NOTES.md) | Internal patterns, provider details, variable flow |

## License

This project is licensed under the BSD 3-Clause License — see the [LICENSE](LICENSE) file for details.

## Support

Netskope-provided scripts in this and other GitHub projects do not fall under the regular Netskope technical support scope and are not supported by Netskope support services.
