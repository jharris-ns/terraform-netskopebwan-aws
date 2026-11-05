# Security Group Migration: Inline Rules to Standalone Resources

## Background

The AWS Terraform provider has deprecated inline `ingress {}` and `egress {}` blocks within `aws_security_group` resources, as well as the older `aws_security_group_rule` resource type. The recommended pattern is to use the newer standalone resources:

- `aws_vpc_security_group_ingress_rule`
- `aws_vpc_security_group_egress_rule`

This document covers the migration of all three security groups in `vpc.tf` and the associated `aws_security_group_rule.clients` resource.

## Affected Resources

### Security Groups with Inline Rules

| Resource | Location | Inline Rules |
|----------|----------|-------------|
| `aws_security_group.public` | `vpc.tf:184-218` | SSH (TCP 22, 0.0.0.0/0), IPSec (UDP 4500, 0.0.0.0/0), egress all |
| `aws_security_group.private` | `vpc.tf:230-257` | All traffic ingress (0.0.0.0/0), egress all |
| `aws_security_group.ssm_endpoint` | `vpc.tf:342-369` | HTTPS (TCP 443, VPC CIDR), egress all |

### Deprecated `aws_security_group_rule`

| Resource | Location | Description |
|----------|----------|-------------|
| `aws_security_group_rule.clients` | `vpc.tf:220-228` | Dynamic client ports (`for_each` over `var.clients.ports`), TCP 2000+port |

## Current Pattern (Deprecated)

```hcl
resource "aws_security_group" "private" {
  name        = join("-", ["Private-SG", var.netskope_tenant.deployment_name])
  description = join("-", ["Private-SG", var.netskope_tenant.deployment_name])
  vpc_id      = local.vpc_id

  ingress {
    description = "All"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

## Target Pattern

Security group resources contain only identity attributes (name, description, VPC, tags). All rules are defined as separate resources:

```hcl
resource "aws_security_group" "private" {
  name        = join("-", ["Private-SG", var.netskope_tenant.deployment_name])
  description = join("-", ["Private-SG", var.netskope_tenant.deployment_name])
  vpc_id      = local.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "private_all" {
  security_group_id = aws_security_group.private.id
  description       = "All"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "private_all" {
  security_group_id = aws_security_group.private.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
```

### Key Argument Differences

| Inline / Old `aws_security_group_rule` | New Standalone Resource |
|----------------------------------------|------------------------|
| `protocol = "-1"` | `ip_protocol = "-1"` |
| `cidr_blocks = ["0.0.0.0/0"]` | `cidr_ipv4 = "0.0.0.0/0"` |
| `from_port = 0` / `to_port = 0` (with `-1`) | Omit `from_port`/`to_port` entirely for `-1` |
| `type = "ingress"` | Use `aws_vpc_security_group_ingress_rule` |
| `type = "egress"` | Use `aws_vpc_security_group_egress_rule` |

## New Standalone Rules

### `aws_security_group.public`

```hcl
resource "aws_vpc_security_group_ingress_rule" "public_ssh" {
  security_group_id = aws_security_group.public.id
  description       = "SSH"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "public_ipsec" {
  security_group_id = aws_security_group.public.id
  description       = "IPSec"
  from_port         = 4500
  to_port           = 4500
  ip_protocol       = "udp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "public_all" {
  security_group_id = aws_security_group.public.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
```

### `aws_security_group.private`

```hcl
resource "aws_vpc_security_group_ingress_rule" "private_all" {
  security_group_id = aws_security_group.private.id
  description       = "All"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "private_all" {
  security_group_id = aws_security_group.private.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
```

### `aws_security_group.ssm_endpoint`

```hcl
resource "aws_vpc_security_group_ingress_rule" "ssm_endpoint_https" {
  security_group_id = aws_security_group.ssm_endpoint.id
  description       = "HTTPS from VPC"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.aws_network_config.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "ssm_endpoint_all" {
  security_group_id = aws_security_group.ssm_endpoint.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
```

### `aws_security_group_rule.clients` (Dynamic Ports)

Replace the deprecated `aws_security_group_rule` with:

```hcl
resource "aws_vpc_security_group_ingress_rule" "clients" {
  for_each          = var.clients.create_clients ? toset(var.clients.ports) : toset([])
  security_group_id = aws_security_group.public.id
  from_port         = sum([2000, tonumber(each.key)])
  to_port           = sum([2000, tonumber(each.key)])
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}
```

Note: `terraform state mv` cannot move between different resource types. Either accept a brief destroy/create cycle, or use `terraform state rm` + `terraform import` per rule to avoid a gap.

## Migration Strategy

### Recommended: Two-Phase Apply (Zero Downtime)

When Terraform removes inline rules from an `aws_security_group`, it revokes them via the AWS API before creating the new standalone resources. This creates a brief window where rules don't exist. The two-phase approach eliminates this gap.

**Phase 1 — Add standalone rules alongside existing inline rules:**

1. Add all new `aws_vpc_security_group_ingress_rule` and `aws_vpc_security_group_egress_rule` resources
2. Keep the existing inline `ingress {}`/`egress {}` blocks unchanged
3. Run `terraform apply` — AWS deduplicates identical rules, so both coexist harmlessly

**Phase 2 — Remove inline blocks:**

1. Remove all inline `ingress {}` and `egress {}` blocks from the three SGs
2. Run `terraform apply` — Terraform updates the SGs in-place, but the standalone rules already exist so there is zero traffic disruption

### Alternative: Single Apply (Sub-Second Gap)

For non-production environments, a single apply is acceptable. The gap between rule removal and rule creation is typically under 1 second.

## Validation

After migration, `terraform plan` should show:

- **0 security groups destroyed** — SG IDs remain the same; no impact on attached ENIs or VPC endpoints
- **3 SGs updated in-place** — inline rules removed from state
- **8+ standalone rules created** — all ingress/egress rules as separate resources

Verify that downstream references are unaffected:

- `aws_network_interface.gw_interfaces` in `interfaces.tf` — references `aws_security_group.public.id` and `aws_security_group.private.id`
- `aws_vpc_endpoint.ssm`, `.ssmmessages`, `.ec2messages` — reference `aws_security_group.ssm_endpoint.id`

These references point to the SG resource itself (not its rules), so they require no changes.
