# Deploying from AWS CloudShell

AWS CloudShell provides a browser-based shell with pre-authenticated AWS credentials. This guide covers deploying Netskope SD-WAN gateways from CloudShell.

## 1. Install tfenv and Terraform

CloudShell does not include Terraform. Install [tfenv](https://github.com/tfutils/tfenv) to manage Terraform versions — it respects `.terraform-version` files and makes upgrades simple:

```sh
git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.tfenv/bin:$PATH"
```

Then install Terraform:

```sh
tfenv install latest
tfenv use latest
terraform version
```

To pin a specific version (e.g., for team consistency):

```sh
tfenv install 1.9.8
tfenv use 1.9.8
```

Both `~/.tfenv` and `~/.bashrc` persist across CloudShell sessions.

## 2. Clone the Repository

```sh
git clone <repository-url>
cd terraform-netskopebwan-aws
```

## 3. Create Your Variables File

```sh
cp example.tfvars terraform.tfvars
```

Edit `terraform.tfvars` with your values. At minimum, configure:

```hcl
aws_network_config = {
  create_vpc = true
  region     = "us-east-1"       # Must match your CloudShell region (see note below)
  vpc_cidr   = "172.32.0.0/16"
}

aws_transit_gw = {
  create_transit_gw = true
  tgw_asn           = "64512"
  tgw_cidr          = "192.0.1.0/24"
}

netskope_tenant = {
  deployment_name = "my-corp-prod"
  tenant_bgp_asn  = "400"
}

netskope_gateway_config = {
  gateway_policy = "my-aws-policy"
}

aws_instance = {
  keypair = "my-keypair"
}
```

## 4. Set Netskope Credentials

Set the tenant URL and API token as environment variables so they stay out of your tfvars file:

```sh
export TF_VAR_netskope_tenant_url="https://example.infiot.net"
export TF_VAR_netskope_tenant_token="YOUR_API_TOKEN"
```

Alternatively, you can set `tenant_url` and `tenant_token` directly in the `netskope_tenant` block in `terraform.tfvars`.

## 5. Deploy

```sh
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

## Region Considerations

CloudShell inherits AWS credentials for the region shown in the console. The SSM provisioner scripts use the AWS CLI, which will use these same credentials.

- Set `aws_network_config.region` to match your CloudShell region, or
- If deploying to a different region, export `AWS_DEFAULT_REGION` before running Terraform:

```sh
export AWS_DEFAULT_REGION="ap-southeast-2"
```

## Storage Limits

CloudShell provides 1 GB of persistent storage in `$HOME`. Terraform state and provider plugins count against this. For production use, configure a [remote backend](STATE_MANAGEMENT.md) to store state in S3.

## IAM Permissions

CloudShell uses the permissions of your IAM identity (user or role). See [IAM Permissions](IAM_PERMISSIONS.md) for the required policies.

## Session Timeouts

CloudShell sessions time out after 20 minutes of inactivity. Long-running `terraform apply` operations (especially GRE configuration via SSM) may exceed this. Keep the browser tab active to prevent timeout.

## Next Steps

- [Quick Start](QUICKSTART.md) — Verification steps after deployment
- [Deployment Guide](DEPLOYMENT_GUIDE.md) — Full configuration options
- [Operations](OPERATIONS.md) — Day-2 procedures
