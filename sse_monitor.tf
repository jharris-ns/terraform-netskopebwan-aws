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

      # Poll for SSM readiness (up to 5 minutes, 10s intervals)
      MAX_ATTEMPTS=30
      ATTEMPT=0
      STATUS="None"
      while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        STATUS=$(aws ssm describe-instance-information \
          --region $REGION \
          --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
          --query "InstanceInformationList[0].PingStatus" \
          --output text 2>/dev/null || echo "None")
        [ "$STATUS" = "Online" ] && break
        ATTEMPT=$((ATTEMPT + 1))
        sleep 10
      done
      [ "$STATUS" != "Online" ] && echo "SSM agent not ready on instance $INSTANCE_ID (gateway ${each.key})" && exit 1

      # Send SSM command with base64 payload
      COMMAND_ID=$(aws ssm send-command \
        --region $REGION \
        --instance-ids $INSTANCE_ID \
        --document-name ${aws_ssm_document.sse_monitor.name} \
        --parameters "{\"scriptPayload\":[\"$PAYLOAD\"]}" \
        --comment "Deploy SSE monitor on gateway ${each.key}" \
        --query "Command.CommandId" \
        --output text)

      # Wait for command completion
      while true; do
        CMD_STATUS=$(aws ssm get-command-invocation \
          --region $REGION \
          --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
          --query Status --output text 2>/dev/null || echo "InProgress")
        case "$CMD_STATUS" in
          Success) echo "SSE monitor for gateway ${each.key} deployed successfully"; break ;;
          Failed|Cancelled|TimedOut) echo "SSE monitor for gateway ${each.key} failed with status: $CMD_STATUS"; exit 1 ;;
          *) sleep 5 ;;
        esac
      done
    EOT
  }
}
