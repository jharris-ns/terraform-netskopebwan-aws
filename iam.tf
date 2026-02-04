#------------------------------------------------------------------------------
#  IAM Role + Instance Profile for SSM access on gateway instances
#------------------------------------------------------------------------------

resource "aws_iam_role" "gateway_ssm_role" {
  name = "${var.netskope_gateway_config.gateway_policy}-netskope-gw-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.netskope_gateway_config.gateway_policy}-netskope-gw-ssm-role"
  }
}

resource "aws_iam_role_policy_attachment" "gateway_ssm_managed_policy" {
  role       = aws_iam_role.gateway_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "gateway_ssm_profile" {
  name = "${var.netskope_gateway_config.gateway_policy}-netskope-gw-ssm-profile"
  role = aws_iam_role.gateway_ssm_role.name

  tags = {
    Name = "${var.netskope_gateway_config.gateway_policy}-netskope-gw-ssm-profile"
  }
}
