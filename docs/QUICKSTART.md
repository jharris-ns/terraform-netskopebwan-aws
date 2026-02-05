# Quick Start

Minimal steps to deploy Netskope SD-WAN gateways in AWS.

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
  deployment_name = "my-corp-prod"   # Free-form string used in resource naming
  tenant_bgp_asn  = "400"
  # tenant_url and tenant_token can be set here or via environment variables:
  # export TF_VAR_netskope_api_url="https://example.infiot.net"
  # export TF_VAR_netskope_api_token="YOUR_API_TOKEN"
}

netskope_gateway_config = {
  gateway_policy = "my-aws-policy"
}

aws_instance = {
  keypair = "my-keypair"   # EC2 key pair in the target region
}
```

## 2. Set Credentials

### AWS Authentication

Choose one of the following methods:

**Option A: AWS SSO Profile (recommended)**
```sh
# Login to SSO first
aws sso login --profile my-sso-profile

# Set the profile
export AWS_PROFILE="my-sso-profile"
```

**Option B: IAM Access Keys**
```sh
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
```

**Option C: Named Profile (credentials file)**
```sh
export AWS_PROFILE="my-profile"
```

### Netskope Authentication

Set the Netskope API credentials via environment variables:

```sh
export TF_VAR_netskope_api_url="https://your-tenant.infiot.net"
export TF_VAR_netskope_api_token="your-api-token"
```

These override any values set in `terraform.tfvars` for `netskope_tenant.tenant_url` and `netskope_tenant.tenant_token`.

## 3. Deploy

```sh
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## 4. Expected Outputs

After a successful apply, you will see:

```
gateways = {
  "aws-gw-1" = {
    gre_configured = true
    instance_id    = "i-0abc123..."
  }
  "aws-gw-2" = {
    gre_configured = true
    instance_id    = "i-0def456..."
  }
}

computed-gateway-map = { ... }    # Full computed configuration
gre-config-ssm-document = "my-aws-policy_netskope_gre_config"
```

## 5. Verification

Check gateway status in the Netskope SD-WAN portal — gateways should appear as activated. For BGP and GRE tunnel verification, refer to the Netskope documentation for connection and diagnostics via the Netskope console.

## Next Steps

- See [Deployment Guide](DEPLOYMENT_GUIDE.md) for detailed configuration options
- See [Architecture](ARCHITECTURE.md) for network topology details
- See [Operations](OPERATIONS.md) for day-2 procedures
