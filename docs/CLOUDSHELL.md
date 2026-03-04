# AWS CloudShell Notes

Environment-specific considerations when deploying from [AWS CloudShell](https://aws.amazon.com/cloudshell/). For the actual deployment steps, see the [Quick Start](QUICKSTART.md).

## Install Terraform

CloudShell does not include Terraform. Install [tfenv](https://github.com/tfutils/tfenv) to manage versions:

```sh
git clone --depth=1 https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.tfenv/bin:$PATH"
tfenv install latest
tfenv use latest
```

Both `~/.tfenv` and `~/.bashrc` persist across CloudShell sessions. To pin a specific version: `tfenv install 1.3.0 && tfenv use 1.3.0`.

## Region Considerations

CloudShell inherits AWS credentials for the region shown in the console. Set `aws_network_config.region` to match your CloudShell region, or export `AWS_DEFAULT_REGION` to target a different region:

```sh
export AWS_DEFAULT_REGION="ap-southeast-2"
```

## Storage Limits

CloudShell provides 1 GB of persistent storage in `$HOME`. Terraform state and provider plugins count against this. For production use, configure a [remote backend](STATE_MANAGEMENT.md) to store state in S3.

## Session Timeouts

CloudShell sessions time out after 20 minutes of inactivity. Long-running `terraform apply` operations (especially GRE configuration via SSM) may exceed this. Keep the browser tab active to prevent timeout.

## IAM Permissions

CloudShell uses the permissions of your IAM identity (user or role). See [IAM Permissions](IAM_PERMISSIONS.md) for the required policies.
