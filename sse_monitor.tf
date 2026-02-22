#------------------------------------------------------------------------------
#  SSE Monitor - SSM-based deployment of IPsec tunnel health monitoring script
#  Monitors IPsec tunnel health and automatically advertises/retracts the BGP
#  default route to prevent traffic blackholing when tunnels go down.
#------------------------------------------------------------------------------

# --- SSM Document for SSE Monitor deployment ---

resource "aws_ssm_document" "sse_monitor" {
  name            = "${replace(var.netskope_gateway_config.gateway_policy, "-", "_")}_netskope_sse_monitor"
  document_type   = "Command"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "2.2"
    description   = "Deploy SSE monitor script to Netskope BWAN gateway"
    parameters = {
      scriptPayload = {
        type        = "String"
        description = "Base64-encoded tar.gz of monitor files"
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "deploySseMonitor"
        inputs = {
          runCommand = [
            "#!/bin/bash",
            "set -e",
            "echo '{{ scriptPayload }}' | base64 -d | tar xz -C /",
            "chmod 755 /root/sse_monitor/sse_monitor.sh",
            "systemctl daemon-reload",
            "systemctl enable --now sse_monitor",
            "echo 'SSE monitor deployed successfully.'"
          ]
        }
      }
    ]
  })

  tags = {
    Name = "${var.netskope_gateway_config.gateway_policy}-netskope-sse-monitor"
  }
}

# --- SSE Monitor: Build payload locally, send via SSM ---

resource "null_resource" "sse_monitor" {
  for_each   = local.gre_configs
  depends_on = [aws_ssm_document.sse_monitor, null_resource.gre_config]

  triggers = {
    instance_id = each.value.instance_id
    bgp_asn     = var.netskope_tenant.tenant_bgp_asn
    bgp_peer1   = each.value.bgp_peers.peer1
    bgp_peer2   = each.value.bgp_peers.peer2
  }

  provisioner "local-exec" {
    command = <<-EOT
      REGION="${var.aws_network_config.region}"
      INSTANCE_ID="${each.value.instance_id}"
      BGP_ASN="${var.netskope_tenant.tenant_bgp_asn}"
      BGP_PEER1="${each.value.bgp_peers.peer1}"
      BGP_PEER2="${each.value.bgp_peers.peer2}"

      # Create temp directory and build tar payload
      TMPDIR=$(mktemp -d)
      mkdir -p "$TMPDIR/root/sse_monitor"
      mkdir -p "$TMPDIR/etc/systemd/system"
      mkdir -p "$TMPDIR/etc/logrotate.d"

      # Copy script files
      cp "${path.module}/scripts/sse_monitor.sh" "$TMPDIR/root/sse_monitor/sse_monitor.sh"
      cp "${path.module}/scripts/sse_monitor.service" "$TMPDIR/etc/systemd/system/sse_monitor.service"
      cp "${path.module}/scripts/sse_monitor.logrotate" "$TMPDIR/etc/logrotate.d/sse_monitor"

      # Generate FRR config files with per-gateway BGP peers
      cat > "$TMPDIR/root/sse_monitor/frrcmds-advertise-default.json" <<ADVEOF
{
  "frrCmdSets": [
    {
      "frrCmds": [
        "conf t",
        "router bgp $BGP_ASN",
        "neighbor $BGP_PEER1 default-originate",
        "neighbor $BGP_PEER2 default-originate"
      ]
    }
  ]
}
ADVEOF

      cat > "$TMPDIR/root/sse_monitor/frrcmds-retract-default.json" <<RETEOF
{
  "frrCmdSets": [
    {
      "frrCmds": [
        "conf t",
        "router bgp $BGP_ASN",
        "no neighbor $BGP_PEER1 default-originate",
        "no neighbor $BGP_PEER2 default-originate"
      ]
    }
  ]
}
RETEOF

      # Create base64-encoded tar
      PAYLOAD=$(cd "$TMPDIR" && tar czf - root etc | base64 | tr -d '\n')
      rm -rf "$TMPDIR"

      # Send SSM command via shared helper
      ${path.module}/scripts/ssm_send_command.sh \
        "$REGION" \
        "$INSTANCE_ID" \
        "${aws_ssm_document.sse_monitor.name}" \
        "{\"scriptPayload\":[\"$PAYLOAD\"]}" \
        "Deploy SSE monitor on gateway ${each.key}"
    EOT
  }
}
