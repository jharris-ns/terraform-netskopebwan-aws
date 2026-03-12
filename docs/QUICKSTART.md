# Quick Start

Minimal steps to deploy Netskope SD-WAN gateways in AWS.

## Prerequisites

- Terraform >= 1.3, AWS CLI configured
- Netskope SD-WAN tenant with a REST API token
- **Netskope gateway policy** — create a policy in the SD-WAN portal before deploying (the policy name is referenced in `terraform.tfvars`)

## 1. Clone and Configure

```sh
git clone <repository-url>
cd terraform-netskopebwan-aws
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars` — at minimum, set these values:

```hcl
aws_network_config = {
  create_vpc = true
  region     = "us-east-1"       # Your target region
  vpc_cidr   = "172.32.0.0/16"   # VPC CIDR block
}

aws_transit_gw = {
  create_transit_gw = true
  tgw_asn           = "64512"
  tgw_cidr          = "192.0.1.0/24"
}

netskope_tenant = {
  deployment_name = "my-corp-prod"    # Free-form string used in resource naming
  tenant_bgp_asn  = "400"
}

netskope_gateway_config = {
  gateway_policy = "my-aws-policy"  # must already exist on the tenant
}

aws_instance = {
  keypair = "my-keypair"   # EC2 key pair in the target region
}
```

## 2. Set Credentials

### AWS

> **CloudShell users:** AWS credentials are provided automatically — skip to Netskope below.

```sh
# SSO (recommended)
aws sso login --profile my-sso-profile
export AWS_PROFILE="my-sso-profile"

# OR access keys
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
```

### Netskope

```sh
export TF_VAR_netskope_tenant_url="https://example.infiot.net"
export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
```

## 3. Deploy

```sh
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## 4. Verify

After a successful apply you will see output like:

```
gateways = {
  "aws-gw-1" = {
    gre_configured = true
    instance_id    = "i-0abc123..."
  }
}
```

Check gateway status in the Netskope SD-WAN portal — gateways should appear as activated.

## Next Steps

- [Deployment Guide](DEPLOYMENT_GUIDE.md) — All configuration options and variable reference
- [CloudShell](CLOUDSHELL.md) — Browser-based deployment from AWS CloudShell
- [Architecture](ARCHITECTURE.md) — Network topology details
- [Operations](OPERATIONS.md) — Day-2 procedures
