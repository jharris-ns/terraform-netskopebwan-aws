# State Management

## Current State

This module does not configure a backend — Terraform defaults to local state (`terraform.tfstate` in the working directory). This is acceptable for development but not recommended for shared or production environments.

## Recommended: S3 + DynamoDB Backend

Per [HashiCorp's backend documentation](https://developer.hashicorp.com/terraform/language/settings/backends/s3), S3 with DynamoDB locking is the standard remote backend for AWS-based Terraform deployments.

### 1. Create Backend Resources

Create the S3 bucket and DynamoDB table (once, outside this module):

```sh
# Create S3 bucket for state
aws s3api create-bucket \
  --bucket my-terraform-state-bucket \
  --region us-east-1

# Enable versioning (recommended for state recovery)
aws s3api put-bucket-versioning \
  --bucket my-terraform-state-bucket \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket my-terraform-state-bucket \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
  }'

# Block public access
aws s3api put-public-access-block \
  --bucket my-terraform-state-bucket \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 2. Configure the Backend

Add a backend block to the root module. Create or update a file (e.g., `backend.tf`):

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket"
    key            = "netskope-bwan/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-lock"
    encrypt        = true
  }
}
```

### 3. Migrate Existing State

If you already have local state:

```sh
terraform init -migrate-state
```

Terraform will prompt you to confirm the migration from local to S3. After migration, the local `terraform.tfstate` file can be deleted (keep a backup first).

## Security Considerations

- **Encryption**: Enable SSE-KMS on the S3 bucket. The state file contains sensitive values including the Netskope API token and gateway activation tokens.
- **Access control**: Restrict bucket access to the Terraform operator IAM principal. Do not grant broad read access.
- **Versioning**: Enable S3 bucket versioning to allow state recovery from accidental corruption or deletion.
- **Locking**: The DynamoDB table prevents concurrent `terraform apply` runs from corrupting state.
- **Audit logging**: Enable S3 access logging or CloudTrail data events to track who accessed the state file.

## Alternative Backends

Other backends that work with this module:

| Backend | Use Case |
|---|---|
| [Terraform Cloud / HCP](https://developer.hashicorp.com/terraform/cloud-docs) | Managed state, runs, and collaboration |
| [S3 + DynamoDB](https://developer.hashicorp.com/terraform/language/settings/backends/s3) | Self-managed AWS-native (recommended) |
| [Consul](https://developer.hashicorp.com/terraform/language/settings/backends/consul) | Existing Consul infrastructure |
| [GCS](https://developer.hashicorp.com/terraform/language/settings/backends/gcs) | Google Cloud-centric teams |

Choose based on your organization's infrastructure and collaboration requirements.
