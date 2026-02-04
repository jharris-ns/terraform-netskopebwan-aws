# IAM Permissions

## Resources Created by the Module

The module creates a single IAM role and instance profile for gateway EC2 instances:

| Resource | Name Pattern | Purpose |
|---|---|---|
| IAM Role | `{gateway_policy}-netskope-gw-ssm-role` | EC2 assume role for SSM |
| IAM Policy Attachment | `AmazonSSMManagedInstanceCore` | AWS managed policy for SSM Agent |
| Instance Profile | `{gateway_policy}-netskope-gw-ssm-profile` | Attached to gateway EC2 instances |

The role allows the SSM Agent on gateway instances to communicate with the SSM service for GRE tunnel configuration. No additional AWS API permissions are granted to the gateways.

## Terraform Operator Permissions

The IAM principal running `terraform apply` needs permissions to create and manage all resources in the module. Below is a least-privilege policy.

### Required IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VPCAndNetworking",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpc",
        "ec2:DeleteVpc",
        "ec2:DescribeVpcs",
        "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:DescribeSubnets",
        "ec2:CreateInternetGateway",
        "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway",
        "ec2:DetachInternetGateway",
        "ec2:DescribeInternetGateways",
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:DescribeRouteTables",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:DescribeSecurityGroups",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TransitGateway",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTransitGateway",
        "ec2:DeleteTransitGateway",
        "ec2:DescribeTransitGateways",
        "ec2:ModifyTransitGateway",
        "ec2:CreateTransitGatewayVpcAttachment",
        "ec2:DeleteTransitGatewayVpcAttachment",
        "ec2:DescribeTransitGatewayVpcAttachments",
        "ec2:CreateTransitGatewayConnect",
        "ec2:DeleteTransitGatewayConnect",
        "ec2:DescribeTransitGatewayConnects",
        "ec2:CreateTransitGatewayConnectPeer",
        "ec2:DeleteTransitGatewayConnectPeer",
        "ec2:DescribeTransitGatewayConnectPeers"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2Instances",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeImages",
        "ec2:CreateNetworkInterface",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeNetworkInterfaces",
        "ec2:AttachNetworkInterface",
        "ec2:DetachNetworkInterface",
        "ec2:AllocateAddress",
        "ec2:ReleaseAddress",
        "ec2:AssociateAddress",
        "ec2:DisassociateAddress",
        "ec2:DescribeAddresses"
      ],
      "Resource": "*"
    },
    {
      "Sid": "VPCEndpoints",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVpcEndpoint",
        "ec2:DeleteVpcEndpoints",
        "ec2:DescribeVpcEndpoints",
        "ec2:ModifyVpcEndpoint"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMForInstanceProfile",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile",
        "iam:PassRole"
      ],
      "Resource": [
        "arn:aws:iam::*:role/*-netskope-gw-ssm-role",
        "arn:aws:iam::*:instance-profile/*-netskope-gw-ssm-profile"
      ]
    },
    {
      "Sid": "SSMForGREConfig",
      "Effect": "Allow",
      "Action": [
        "ssm:CreateDocument",
        "ssm:DeleteDocument",
        "ssm:DescribeDocument",
        "ssm:GetDocument",
        "ssm:UpdateDocument",
        "ssm:SendCommand",
        "ssm:GetCommandInvocation",
        "ssm:DescribeInstanceInformation",
        "ssm:ListCommandInvocations"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2Tags",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTags",
        "ec2:DeleteTags",
        "ec2:DescribeTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AvailabilityZones",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    }
  ]
}
```

**Note**: The `Resource: "*"` entries can be further scoped using conditions (e.g., `aws:RequestedRegion`, resource tags) for tighter control in production environments.

## CI/CD Pipeline Considerations

When running this module from a CI/CD pipeline:

1. **Credentials**: Use an IAM role with the policy above. Avoid long-lived access keys; prefer OIDC federation (e.g., GitHub Actions OIDC → AWS IAM role).

2. **Netskope API token**: Store the `tenant_token` as a secret (e.g., GitHub Actions secret, AWS Secrets Manager, HashiCorp Vault) and inject it via environment variable or `-var` flag. Do not commit it to version control.

3. **SSM execution**: The `local-exec` provisioner in the `gre_config` module runs AWS CLI commands from the Terraform runner. The pipeline environment must have:
   - AWS CLI installed
   - Credentials available (same principal running Terraform)
   - Network access to the AWS SSM API endpoints

4. **State file access**: The Terraform runner needs read/write access to the state backend. See [State Management](STATE_MANAGEMENT.md).
