#------------------------------------------------------------------------------
#  EC2 Instances and AMI for Netskope BWAN Gateways
#------------------------------------------------------------------------------

# --- AMI ---
# Static per-region AMI map for BWAN-SASE-R6.3.371.
# To override for a specific region, set var.aws_instance.ami_id in terraform.tfvars.

locals {
  bwan_ami_map = {
    "ap-south-2"    = "ami-050e080ecd0808fc4"
    "ap-south-1"    = "ami-0178efee130539006"
    "eu-south-1"    = "ami-0865ee874989c30a5"
    "eu-south-2"    = "ami-0770eb6945564a11f"
    "il-central-1"  = "ami-0a71b0af5c2d0ac22"
    "ca-central-1"  = "ami-03c7a419017b759ee"
    "ap-east-2"     = "ami-0ac8a9f0aa6e7af58"
    "mx-central-1"  = "ami-094d3d7ee910c3af1"
    "eu-central-1"  = "ami-04dacf49c899c05d7"
    "eu-central-2"  = "ami-014db14a3c32f883d"
    "us-west-1"     = "ami-0ee37fc870202dda7"
    "us-west-2"     = "ami-018a1999ed446a90b"
    "af-south-1"    = "ami-09c456bc0d48f9334"
    "eu-west-3"     = "ami-007117a7906560057"
    "eu-north-1"    = "ami-0884f114ae39fe0ad"
    "eu-west-2"     = "ami-0261d2775340036a1"
    "eu-west-1"     = "ami-0dbb3c338634d967c"
    "ap-northeast-3" = "ami-0323a6e51585158b5"
    "ap-northeast-2" = "ami-000d0333ca9cf7dbc"
    "ap-northeast-1" = "ami-02211075d0fd346a2"
    "sa-east-1"     = "ami-0abf930e4adda0376"
    "ap-east-1"     = "ami-0d9e31d74758c737a"
    "ca-west-1"     = "ami-069fe813ee9110837"
    "ap-southeast-1" = "ami-0405cbc8b52a576ca"
    "ap-southeast-2" = "ami-00ee275d3e58fdf47"
    "ap-southeast-3" = "ami-0673188cef21c94e1"
    "ap-southeast-4" = "ami-05a09bf308d53c294"
    "ap-southeast-5" = "ami-0a163fcc759f46620"
    "us-east-1"     = "ami-07bb168bd669677aa"
    "us-east-2"     = "ami-061f4d68d96bba406"
    "ap-southeast-6" = "ami-090171696734c0b4b"
    "ap-southeast-7" = "ami-00cf7b8b877c0b78e"
    "me-west-1"     = "ami-089b1f9668106f272"
  }

  netskope_gw_image_id = coalesce(
    var.aws_instance.ami_id,
    lookup(local.bwan_ami_map, var.aws_network_config.region, null)
  )
}

# --- Gateway EC2 Instances ---

resource "aws_instance" "gateways" {
  for_each             = local.gateways
  ami                  = local.netskope_gw_image_id
  instance_type        = var.aws_instance.instance_type
  availability_zone    = local.gateways[each.key].availability_zone
  iam_instance_profile = aws_iam_instance_profile.gateway_ssm_profile.name
  key_name             = var.aws_instance.keypair

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/scripts/user-data.sh", {
    netskope_tenant_url = local.tenant_url
    ssm_password_path   = aws_ssm_parameter.gateway_password.name
    ssm_token_path      = aws_ssm_parameter.gateway_activation_key[each.key].name
    aws_region          = var.aws_network_config.region
  })

  dynamic "network_interface" {
    for_each = {
      for idx, intf_key in sort(keys(local.gw_enabled_interfaces[each.key])) :
      idx => {
        id = aws_network_interface.gw_interfaces["${each.key}-${intf_key}"].id
      }
    }
    content {
      network_interface_id = network_interface.value.id
      device_index         = network_interface.key
    }
  }

  tags = {
    Name = join("-", [each.key, var.netskope_tenant.deployment_name])
  }
}
